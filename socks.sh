#!/usr/bin/env bash
set -eo pipefail

# ========================================
#  颜色
# ========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ========================================
#  全局变量
# ========================================

MICROSOCKS_REPO="https://github.com/rofl0r/microsocks/archive/refs/heads/master.tar.gz"
MICROSOCKS_BIN="/usr/local/bin/microsocks"

SVC_NAME="microsocks"
SVC_FILE_SYSTEMD="/etc/systemd/system/microsocks.service"
SVC_FILE_OPENRC="/etc/init.d/microsocks"

CRED_FILE="/root/.socks5_info"
SCRIPT_PATH="/usr/local/bin/socks"

OS_ID="unknown"
OS_FAMILY=""
PKG_MGR=""
INIT_SYS="unknown"

SOCKS_PORT=""
SOCKS_USER=""
SOCKS_PASS=""

# ========================================
#  基础函数
# ========================================

msg()  { echo -e "${GREEN}[OK]${RESET} $*"; }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; }
err()  { echo -e "${RED}[ERR]${RESET} $*" >&2; }

pause() {
  echo ""
  read -rp "  按回车继续..." _ || true
}

banner() {
  command -v clear >/dev/null 2>&1 && clear 2>/dev/null || true
  echo -e "${BOLD}${CYAN}  SOCKS5 管理面板${RESET} ${DIM}(microsocks | ${OS_ID})${RESET}"
  echo "  ----------------------------------------"
  echo ""
}

check_root() {
  if [[ ${EUID:-1} -ne 0 ]]; then
    err "请使用 root 运行"
    exit 1
  fi
  return 0
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

detect_os() {
  OS_ID="unknown"

  if [[ -r /etc/os-release ]]; then
    . /etc/os-release 2>/dev/null || true
    OS_ID="${ID:-unknown}"
    OS_ID="${OS_ID,,}"
  elif [[ -f /etc/redhat-release ]]; then
    OS_ID="centos"
  fi

  case "${OS_ID}" in
    debian|ubuntu|linuxmint|pop|kali|deepin|raspbian)
      OS_FAMILY="debian"; PKG_MGR="apt" ;;
    centos|rhel|almalinux|rocky|ol|amzn|scientific)
      OS_FAMILY="rhel"; PKG_MGR="yum"
      command_exists dnf && PKG_MGR="dnf" ;;
    fedora)
      OS_FAMILY="fedora"; PKG_MGR="dnf" ;;
    alpine)
      OS_FAMILY="alpine"; PKG_MGR="apk" ;;
    arch|manjaro|endeavouros|garuda)
      OS_FAMILY="arch"; PKG_MGR="pacman" ;;
    opensuse*|sles|suse)
      OS_FAMILY="suse"; PKG_MGR="zypper" ;;
    *)
      if command_exists apt-get; then     OS_FAMILY="debian";  PKG_MGR="apt"
      elif command_exists dnf; then       OS_FAMILY="rhel";    PKG_MGR="dnf"
      elif command_exists yum; then       OS_FAMILY="rhel";    PKG_MGR="yum"
      elif command_exists apk; then       OS_FAMILY="alpine";  PKG_MGR="apk"
      elif command_exists pacman; then    OS_FAMILY="arch";    PKG_MGR="pacman"
      elif command_exists zypper; then    OS_FAMILY="suse";    PKG_MGR="zypper"
      else err "无法识别系统"; exit 1; fi
      ;;
  esac

  if command_exists systemctl && [[ -d /run/systemd/system ]]; then
    INIT_SYS="systemd"
  elif command_exists rc-service; then
    INIT_SYS="openrc"
  else
    INIT_SYS="unknown"
  fi

  return 0
}

# ========================================
#  凭据 读/写
# ========================================

save_cred() {
  cat > "${CRED_FILE}" <<EOF
SOCKS_PORT='${SOCKS_PORT}'
SOCKS_USER='${SOCKS_USER}'
SOCKS_PASS='${SOCKS_PASS}'
EOF
  chmod 600 "${CRED_FILE}"
  return 0
}

load_cred() {
  if [[ -f "${CRED_FILE}" ]]; then
    . "${CRED_FILE}"
    return 0
  fi
  return 1
}

# ========================================
#  网络工具
# ========================================

get_local_ip() {
  local ip=""
  ip="$(ip route get 8.8.8.8 2>/dev/null \
    | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [[ -z "${ip}" ]] && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "${ip}"
}

get_public_ip() {
  local ip=""
  ip="$(curl -s --max-time 5 ifconfig.me 2>/dev/null || true)"
  [[ -z "${ip}" ]] && ip="$(curl -s --max-time 5 ip.sb 2>/dev/null || true)"
  [[ -z "${ip}" ]] && ip="$(curl -s --max-time 5 api.ipify.org 2>/dev/null || true)"
  echo "${ip}"
}

open_firewall_port() {
  local port="$1"
  if command_exists ufw; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
  fi
  if command_exists firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  return 0
}

close_firewall_port() {
  local port="$1"
  if command_exists ufw; then
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
  fi
  if command_exists firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
  return 0
}

# ========================================
#  随机生成
# ========================================

gen_port() {
  shuf -i 10000-59999 -n 1 2>/dev/null || echo $(( RANDOM % 49999 + 10000 ))
}

gen_user() {
  local s
  s="$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 6 || true)"
  [[ -n "${s}" ]] || s="$RANDOM"
  echo "user${s}"
}

gen_pass() {
  local p
  p="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16 || true)"
  [[ -n "${p}" ]] || p="Pass$(date +%s)$RANDOM"
  echo "${p}"
}

# ========================================
#  服务管理
# ========================================

write_systemd_unit() {
  local port="$1" user="$2" pass="$3"

  cat > "${SVC_FILE_SYSTEMD}" <<EOF
[Unit]
Description=MicroSocks SOCKS5 Proxy
After=network.target

[Service]
Type=simple
ExecStart=${MICROSOCKS_BIN} -p ${port} -u ${user} -P ${pass}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  return 0
}

write_openrc_init() {
  local port="$1" user="$2" pass="$3"

  cat > "${SVC_FILE_OPENRC}" <<'HEAD'
#!/sbin/openrc-run

description="MicroSocks SOCKS5 Proxy"
command="/usr/local/bin/microsocks"
HEAD

  cat >> "${SVC_FILE_OPENRC}" <<EOF
command_args="-p ${port} -u ${user} -P ${pass}"
command_background=true
pidfile="/run/microsocks.pid"

depend() {
  need net
}
EOF

  chmod +x "${SVC_FILE_OPENRC}"
  return 0
}

write_service() {
  local port="$1" user="$2" pass="$3"

  if [[ "${INIT_SYS}" == "systemd" ]]; then
    write_systemd_unit "${port}" "${user}" "${pass}"
  elif [[ "${INIT_SYS}" == "openrc" ]]; then
    write_openrc_init "${port}" "${user}" "${pass}"
  fi
  return 0
}

svc_is_active() {
  if [[ "${INIT_SYS}" == "systemd" ]]; then
    systemctl is-active --quiet "${SVC_NAME}" 2>/dev/null
  elif [[ "${INIT_SYS}" == "openrc" ]]; then
    rc-service "${SVC_NAME}" status >/dev/null 2>&1
  else
    pgrep -x microsocks >/dev/null 2>&1
  fi
}

svc_enable_start() {
  if [[ "${INIT_SYS}" == "systemd" ]]; then
    systemctl enable "${SVC_NAME}" >/dev/null 2>&1 || true
    systemctl restart "${SVC_NAME}"
  elif [[ "${INIT_SYS}" == "openrc" ]]; then
    rc-update add "${SVC_NAME}" default >/dev/null 2>&1 || true
    rc-service "${SVC_NAME}" restart 2>/dev/null || rc-service "${SVC_NAME}" start
  else
    pkill -x microsocks >/dev/null 2>&1 || true
    sleep 0.3
    nohup "${MICROSOCKS_BIN}" -p "${SOCKS_PORT}" -u "${SOCKS_USER}" -P "${SOCKS_PASS}" \
      >/dev/null 2>&1 &
    msg "已后台启动 (PID $!)"
  fi
  return 0
}

svc_stop_disable() {
  if [[ "${INIT_SYS}" == "systemd" ]]; then
    systemctl stop "${SVC_NAME}" >/dev/null 2>&1 || true
    systemctl disable "${SVC_NAME}" >/dev/null 2>&1 || true
  elif [[ "${INIT_SYS}" == "openrc" ]]; then
    rc-service "${SVC_NAME}" stop >/dev/null 2>&1 || true
    rc-update del "${SVC_NAME}" default >/dev/null 2>&1 || true
  fi
  pkill -x microsocks >/dev/null 2>&1 || true
  return 0
}

# ========================================
#  编译安装 microsocks
# ========================================

install_build_deps() {
  msg "安装编译依赖..."
  case "${PKG_MGR}" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y gcc make curl >/dev/null 2>&1
      ;;
    yum)
      yum install -y gcc make curl >/dev/null 2>&1
      ;;
    dnf)
      dnf install -y gcc make curl >/dev/null 2>&1
      ;;
    apk)
      apk update >/dev/null 2>&1
      apk add build-base curl >/dev/null 2>&1
      ;;
    pacman)
      pacman -Sy --noconfirm gcc make curl >/dev/null 2>&1
      ;;
    zypper)
      zypper --non-interactive install gcc make curl >/dev/null 2>&1
      ;;
  esac
  return 0
}

build_microsocks() {
  local tmpdir="/tmp/microsocks-build"

  rm -rf "${tmpdir}"
  mkdir -p "${tmpdir}"

  msg "下载 microsocks 源码..."
  if ! curl -sL "${MICROSOCKS_REPO}" -o "${tmpdir}/microsocks.tar.gz"; then
    err "下载失败"
    return 1
  fi

  msg "解压..."
  tar xzf "${tmpdir}/microsocks.tar.gz" -C "${tmpdir}" || { err "解压失败"; return 1; }

  local srcdir
  srcdir="$(find "${tmpdir}" -maxdepth 1 -type d -name 'microsocks*' | head -1)"
  [[ -d "${srcdir}" ]] || { err "找不到源码目录"; return 1; }

  msg "编译..."
  cd "${srcdir}"
  make -j"$(nproc 2>/dev/null || echo 1)" || { err "编译失败"; return 1; }

  if [[ ! -f "${srcdir}/microsocks" ]]; then
    err "编译产物不存在"
    return 1
  fi

  cp -f "${srcdir}/microsocks" "${MICROSOCKS_BIN}"
  chmod +x "${MICROSOCKS_BIN}"

  rm -rf "${tmpdir}"
  msg "microsocks 已安装到 ${MICROSOCKS_BIN}"
  return 0
}

install_microsocks() {
  if [[ -x "${MICROSOCKS_BIN}" ]]; then
    msg "microsocks 已存在，跳过编译"
    return 0
  fi

  install_build_deps
  build_microsocks || return 1
  return 0
}

# ========================================
#  校验
# ========================================

validate_port() {
  local port="$1"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 )) || return 1
  return 0
}

validate_username() {
  local user="$1"
  [[ -n "${user}" ]] || return 1
  [[ "${user}" =~ ^[a-zA-Z0-9._-]+$ ]] || return 1
  return 0
}

# ========================================
#  展示代理信息
# ========================================

show_proxy_info() {
  local pub_ip local_ip

  pub_ip="$(get_public_ip)"
  local_ip="$(get_local_ip)"

  echo ""
  echo -e "  ${BOLD}URL:${RESET}"
  echo ""

  if [[ -n "${pub_ip}" ]]; then
    echo -e "  ${GREEN}socks5://${SOCKS_USER}:${SOCKS_PASS}@${pub_ip}:${SOCKS_PORT}${RESET}"
  fi

  if [[ -n "${local_ip}" && "${local_ip}" != "${pub_ip}" ]]; then
    echo -e "  ${DIM}socks5://${SOCKS_USER}:${SOCKS_PASS}@${local_ip}:${SOCKS_PORT}${RESET}"
  fi

  echo ""
}

# ========================================
#  业务逻辑
# ========================================

do_install() {
  local port user pass use_random

  banner
  echo -e "  ${BOLD}安装 SOCKS5${RESET}"
  echo ""

  msg "系统: ${OS_ID} | 包管理器: ${PKG_MGR} | init: ${INIT_SYS}"
  echo ""

  install_microsocks || { err "安装 microsocks 失败"; pause; return 0; }

  echo ""
  echo -e "  ${BOLD}配置代理参数${RESET}"
  echo ""
  echo -e "  y) 全部随机生成 (端口/用户名/密码)"
  echo -e "  n) 手动输入"
  echo ""
  read -rp "  是否随机生成配置? [Y/n]: " use_random
  use_random="${use_random:-y}"
  echo ""

  if [[ "${use_random,,}" == "n" || "${use_random,,}" == "no" ]]; then
    while true; do
      read -rp "  端口: " port
      validate_port "${port}" && break
      err "端口无效，请输入 1-65535"
    done
    while true; do
      read -rp "  用户名: " user
      validate_username "${user}" && break
      err "用户名无效，仅允许字母、数字、点、下划线、横线"
    done
    while true; do
      read -rp "  密码: " pass
      [[ -n "${pass}" ]] && break
      err "密码不能为空"
    done
  else
    port="$(gen_port)"
    user="$(gen_user)"
    pass="$(gen_pass)"
  fi

  SOCKS_PORT="${port}"
  SOCKS_USER="${user}"
  SOCKS_PASS="${pass}"

  write_service "${port}" "${user}" "${pass}"
  svc_enable_start
  open_firewall_port "${port}"
  save_cred

  banner
  msg "安装完成"
  show_proxy_info
  pause
  return 0
}

do_status() {
  banner
  echo -e "  ${BOLD}服务状态${RESET}"
  echo ""

  if svc_is_active 2>/dev/null; then
    echo -e "  状态: ${GREEN}● 运行中${RESET}"
  else
    echo -e "  状态: ${RED}✗ 未运行${RESET}"
  fi

  if load_cred 2>/dev/null; then
    show_proxy_info
  fi

  if [[ "${INIT_SYS}" == "systemd" ]]; then
    echo ""
    systemctl --no-pager --full status "${SVC_NAME}" 2>/dev/null | head -15 || true
  fi

  pause
  return 0
}

do_view() {
  banner
  echo -e "  ${BOLD}代理信息${RESET}"

  if load_cred 2>/dev/null; then
    show_proxy_info
  else
    echo ""
    warn "未找到已保存的代理信息，请先安装"
    echo ""
  fi

  pause
  return 0
}

do_edit() {
  local port user pass old_port use_random

  if ! load_cred 2>/dev/null; then
    warn "未找到已有配置，请先安装"
    pause
    return 0
  fi

  old_port="${SOCKS_PORT}"

  banner
  echo -e "  ${BOLD}编辑代理${RESET}"
  echo ""
  echo -e "  当前:"
  show_proxy_info
  echo -e "  y) 全部重新随机生成"
  echo -e "  n) 手动修改"
  echo ""
  read -rp "  是否随机生成新配置? [Y/n]: " use_random
  use_random="${use_random:-y}"
  echo ""

  if [[ "${use_random,,}" == "n" || "${use_random,,}" == "no" ]]; then
    while true; do
      read -rp "  端口 (当前 ${SOCKS_PORT}): " port
      port="${port:-${SOCKS_PORT}}"
      validate_port "${port}" && break
      err "端口无效"
    done
    while true; do
      read -rp "  用户名 (当前 ${SOCKS_USER}): " user
      user="${user:-${SOCKS_USER}}"
      validate_username "${user}" && break
      err "用户名无效"
    done
    read -rp "  密码 (回车保持不变): " pass
    pass="${pass:-${SOCKS_PASS}}"
  else
    port="$(gen_port)"
    user="$(gen_user)"
    pass="$(gen_pass)"
  fi

  SOCKS_PORT="${port}"
  SOCKS_USER="${user}"
  SOCKS_PASS="${pass}"

  write_service "${port}" "${user}" "${pass}"
  svc_enable_start
  save_cred

  if [[ "${old_port}" != "${port}" ]]; then
    close_firewall_port "${old_port}"
    open_firewall_port "${port}"
  fi

  banner
  msg "修改完成"
  show_proxy_info
  pause
  return 0
}

do_uninstall() {
  local ans old_port

  banner
  echo -e "  ${BOLD}卸载 SOCKS5${RESET}"
  echo ""
  read -rp "  确认卸载？[y/N]: " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || return 0

  old_port=""
  load_cred 2>/dev/null && old_port="${SOCKS_PORT:-}" || true

  svc_stop_disable

  [[ -n "${old_port}" ]] && close_firewall_port "${old_port}"

  rm -f "${MICROSOCKS_BIN}"
  rm -f "${SVC_FILE_SYSTEMD}"
  rm -f "${SVC_FILE_OPENRC}"
  rm -f "${CRED_FILE}"
  rm -f "${SCRIPT_PATH}"

  if [[ "${INIT_SYS}" == "systemd" ]]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  banner
  msg "卸载完成"
  pause
  return 0
}

install_self_cmd() {
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    local src
    src="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
    if [[ "${src}" != "${SCRIPT_PATH}" ]]; then
      cp -f "${src}" "${SCRIPT_PATH}" 2>/dev/null || true
      chmod +x "${SCRIPT_PATH}" 2>/dev/null || true
    fi
  fi
  return 0
}

# ========================================
#  主菜单
# ========================================

main_menu() {
  while true; do
    banner

    if svc_is_active 2>/dev/null; then
      local info=""
      load_cred 2>/dev/null && info="  端口=${GREEN}${SOCKS_PORT}${RESET}" || true
      echo -e "  状态: ${GREEN}● 运行中${RESET}${info}"
    else
      echo -e "  状态: ${RED}✗ 未运行${RESET}"
    fi
    echo ""

    echo -e "  1) 安装"
    echo -e "  2) 查看状态"
    echo -e "  3) 查看代理"
    echo -e "  4) 编辑代理"
    echo -e "  5) 卸载"
    echo -e "  0) 退出"
    echo ""
    read -rp "  请选择 [0-5]: " choice || choice=""

    case "${choice:-}" in
      1) do_install   ;;
      2) do_status    ;;
      3) do_view      ;;
      4) do_edit      ;;
      5) do_uninstall ;;
      0) echo ""; exit 0 ;;
      *) ;;
    esac
  done
}

# ========================================
#  入口
# ========================================

check_root
detect_os
install_self_cmd
main_menu
