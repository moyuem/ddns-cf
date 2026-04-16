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

CRED_FILE="/root/.socks5_info"
SCRIPT_PATH="/usr/local/bin/socks"

OS_ID="unknown"
OS_FAMILY=""
PKG_MGR=""
INIT_SYS="unknown"

SVC_NAME="danted"
CONF_FILE="/etc/danted.conf"
SOCKD_BIN="/usr/sbin/danted"
PKG_NAME="dante-server"

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
  read -rp "按回车继续..." _ || true
}

banner() {
  command -v clear >/dev/null 2>&1 && clear 2>/dev/null || true
  echo -e "${BOLD}${CYAN}SOCKS5 管理面板${RESET} ${DIM}(${OS_ID})${RESET}"
  echo "----------------------------------------"
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
      OS_FAMILY="debian"
      PKG_MGR="apt"
      SVC_NAME="danted"
      CONF_FILE="/etc/danted.conf"
      SOCKD_BIN="/usr/sbin/danted"
      PKG_NAME="dante-server"
      ;;
    centos|rhel|almalinux|rocky|ol|amzn|scientific|eurolinux)
      OS_FAMILY="rhel"
      PKG_MGR="yum"
      command_exists dnf && PKG_MGR="dnf"
      SVC_NAME="sockd"
      CONF_FILE="/etc/sockd.conf"
      SOCKD_BIN="/usr/sbin/sockd"
      PKG_NAME="dante-server"
      ;;
    fedora)
      OS_FAMILY="fedora"
      PKG_MGR="dnf"
      SVC_NAME="sockd"
      CONF_FILE="/etc/sockd.conf"
      SOCKD_BIN="/usr/sbin/sockd"
      PKG_NAME="dante-server"
      ;;
    alpine)
      OS_FAMILY="alpine"
      PKG_MGR="apk"
      SVC_NAME="sockd"
      CONF_FILE="/etc/sockd.conf"
      SOCKD_BIN="/usr/sbin/sockd"
      PKG_NAME="dante-server"
      ;;
    arch|manjaro|endeavouros|garuda)
      OS_FAMILY="arch"
      PKG_MGR="pacman"
      SVC_NAME="sockd"
      CONF_FILE="/etc/sockd.conf"
      SOCKD_BIN="/usr/bin/sockd"
      PKG_NAME="dante"
      ;;
    opensuse*|sles|suse)
      OS_FAMILY="suse"
      PKG_MGR="zypper"
      SVC_NAME="sockd"
      CONF_FILE="/etc/sockd.conf"
      SOCKD_BIN="/usr/sbin/sockd"
      PKG_NAME="dante-server"
      ;;
    *)
      if command_exists apt-get; then
        OS_FAMILY="debian"
        PKG_MGR="apt"
        SVC_NAME="danted"
        CONF_FILE="/etc/danted.conf"
        SOCKD_BIN="/usr/sbin/danted"
        PKG_NAME="dante-server"
      elif command_exists dnf; then
        OS_FAMILY="rhel"
        PKG_MGR="dnf"
        SVC_NAME="sockd"
        CONF_FILE="/etc/sockd.conf"
        SOCKD_BIN="/usr/sbin/sockd"
        PKG_NAME="dante-server"
      elif command_exists yum; then
        OS_FAMILY="rhel"
        PKG_MGR="yum"
        SVC_NAME="sockd"
        CONF_FILE="/etc/sockd.conf"
        SOCKD_BIN="/usr/sbin/sockd"
        PKG_NAME="dante-server"
      elif command_exists apk; then
        OS_FAMILY="alpine"
        PKG_MGR="apk"
        SVC_NAME="sockd"
        CONF_FILE="/etc/sockd.conf"
        SOCKD_BIN="/usr/sbin/sockd"
        PKG_NAME="dante-server"
      elif command_exists pacman; then
        OS_FAMILY="arch"
        PKG_MGR="pacman"
        SVC_NAME="sockd"
        CONF_FILE="/etc/sockd.conf"
        SOCKD_BIN="/usr/bin/sockd"
        PKG_NAME="dante"
      elif command_exists zypper; then
        OS_FAMILY="suse"
        PKG_MGR="zypper"
        SVC_NAME="sockd"
        CONF_FILE="/etc/sockd.conf"
        SOCKD_BIN="/usr/sbin/sockd"
        PKG_NAME="dante-server"
      else
        err "无法识别系统"
        exit 1
      fi
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
    # shellcheck disable=SC1090
    . "${CRED_FILE}"
    return 0
  fi
  return 1
}

get_default_if() {
  local iface=""
  iface="$(ip route get 8.8.8.8 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  if [[ -z "${iface}" ]]; then
    iface="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}')"
  fi
  echo "${iface}"
}

get_local_ip() {
  local ipaddr=""
  ipaddr="$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  if [[ -z "${ipaddr}" ]]; then
    ipaddr="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  echo "${ipaddr}"
}

svc_is_active() {
  if [[ "${INIT_SYS}" == "systemd" ]]; then
    systemctl is-active --quiet "${SVC_NAME}"
  elif [[ "${INIT_SYS}" == "openrc" ]]; then
    rc-service "${SVC_NAME}" status >/dev/null 2>&1
  else
    return 1
  fi
}

svc_enable() {
  if [[ "${INIT_SYS}" == "systemd" ]]; then
    systemctl enable "${SVC_NAME}" >/dev/null 2>&1 || true
  elif [[ "${INIT_SYS}" == "openrc" ]]; then
    rc-update add "${SVC_NAME}" default >/dev/null 2>&1 || true
  fi
  return 0
}

svc_start() {
  if [[ "${INIT_SYS}" == "systemd" ]]; then
    systemctl restart "${SVC_NAME}"
  elif [[ "${INIT_SYS}" == "openrc" ]]; then
    rc-service "${SVC_NAME}" restart || rc-service "${SVC_NAME}" start
  else
    err "不支持的 init 系统"
    return 1
  fi
}

svc_stop() {
  if [[ "${INIT_SYS}" == "systemd" ]]; then
    systemctl stop "${SVC_NAME}" >/dev/null 2>&1 || true
    systemctl disable "${SVC_NAME}" >/dev/null 2>&1 || true
  elif [[ "${INIT_SYS}" == "openrc" ]]; then
    rc-service "${SVC_NAME}" stop >/dev/null 2>&1 || true
    rc-update del "${SVC_NAME}" default >/dev/null 2>&1 || true
  fi
  return 0
}

open_firewall_port() {
  local port="$1"

  if command_exists ufw; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    ufw allow "${port}/udp" >/dev/null 2>&1 || true
  fi

  if command_exists firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${port}/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi

  return 0
}

close_firewall_port() {
  local port="$1"

  if command_exists ufw; then
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
    ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
  fi

  if command_exists firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --remove-port="${port}/udp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi

  return 0
}

# ========================================
#  安装相关
# ========================================

install_packages() {
  case "${PKG_MGR}" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y "${PKG_NAME}" iproute2 curl passwd
      ;;
    yum)
      yum install -y epel-release >/dev/null 2>&1 || true
      yum install -y "${PKG_NAME}" iproute curl passwd || yum install -y dante iproute curl passwd
      ;;
    dnf)
      dnf install -y epel-release >/dev/null 2>&1 || true
      dnf install -y "${PKG_NAME}" iproute curl shadow-utils || dnf install -y dante iproute curl shadow-utils
      ;;
    apk)
      apk update
      apk add "${PKG_NAME}" iproute2 curl shadow
      ;;
    pacman)
      pacman -Sy --noconfirm "${PKG_NAME}" iproute2 curl
      ;;
    zypper)
      zypper --non-interactive refresh
      zypper --non-interactive install "${PKG_NAME}" iproute2 curl shadow
      ;;
    *)
      err "不支持的包管理器: ${PKG_MGR}"
      return 1
      ;;
  esac
  return 0
}

ensure_socks_user() {
  local username="$1"
  local password="$2"

  if id "${username}" >/dev/null 2>&1; then
    echo "${username}:${password}" | chpasswd
  else
    useradd -M -s /usr/sbin/nologin "${username}" 2>/dev/null || \
    useradd -M -s /sbin/nologin "${username}" 2>/dev/null || \
    useradd -M -s /bin/false "${username}"
    echo "${username}:${password}" | chpasswd
  fi

  return 0
}

write_config() {
  local port="$1"
  local ext_if="$2"

  mkdir -p "$(dirname "${CONF_FILE}")"

  cat > "${CONF_FILE}" <<EOF
logoutput: syslog

internal: 0.0.0.0 port = ${port}
external: ${ext_if}

user.privileged: root
user.unprivileged: nobody
user.libwrap: nobody

socksmethod: username

client pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  log: error connect disconnect
}

socks pass {
  from: 0.0.0.0/0 to: 0.0.0.0/0
  command: connect bind udpassociate
  log: error connect disconnect
  socksmethod: username
}
EOF

  chmod 600 "${CONF_FILE}"
  return 0
}

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

install_dante() {
  if command_exists "${SOCKD_BIN}"; then
    return 0
  fi

  msg "开始安装 Dante..."
  install_packages

  if ! command_exists "${SOCKD_BIN}"; then
    if [[ -x /usr/sbin/danted ]]; then
      SOCKD_BIN="/usr/sbin/danted"
    elif [[ -x /usr/sbin/sockd ]]; then
      SOCKD_BIN="/usr/sbin/sockd"
    elif [[ -x /usr/bin/sockd ]]; then
      SOCKD_BIN="/usr/bin/sockd"
    else
      err "安装完成，但未找到 sockd/danted 可执行文件"
      return 1
    fi
  fi

  return 0
}

show_proxy_info() {
  local ipaddr=""
  ipaddr="$(get_local_ip)"

  echo ""
  echo -e "  地址: ${GREEN}${ipaddr:-unknown}${RESET}"
  echo -e "  端口: ${GREEN}${SOCKS_PORT:-unknown}${RESET}"
  echo -e "  用户: ${GREEN}${SOCKS_USER:-unknown}${RESET}"
  echo -e "  密码: ${GREEN}${SOCKS_PASS:-unknown}${RESET}"
  echo ""
  echo -e "  格式: ${CYAN}${ipaddr:-IP}:${SOCKS_PORT:-PORT}:${SOCKS_USER:-USER}:${SOCKS_PASS:-PASS}${RESET}"
  echo ""
}

# ========================================
#  业务逻辑
# ========================================

do_install() {
  local port user pass ext_if

  banner
  echo -e "${BOLD}安装 SOCKS5${RESET}"
  echo ""

  read -rp "请输入端口 [1080]: " port
  port="${port:-1080}"
  if ! validate_port "${port}"; then
    err "端口无效"
    pause
    return 0
  fi

  read -rp "请输入用户名 [socks]: " user
  user="${user:-socks}"
  if ! validate_username "${user}"; then
    err "用户名无效，仅允许字母、数字、点、下划线、横线"
    pause
    return 0
  fi

  read -rp "请输入密码 [随机生成]: " pass
  if [[ -z "${pass}" ]]; then
    pass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12 || true)"
    [[ -n "${pass}" ]] || pass="Socks$(date +%s)"
  fi

  ext_if="$(get_default_if)"
  if [[ -z "${ext_if}" ]]; then
    err "无法检测默认网卡"
    pause
    return 0
  fi

  msg "系统: ${OS_ID}, 包管理器: ${PKG_MGR}, init: ${INIT_SYS}"
  msg "出口网卡: ${ext_if}"

  install_dante
  ensure_socks_user "${user}" "${pass}"
  write_config "${port}" "${ext_if}"
  svc_enable
  svc_start
  open_firewall_port "${port}"

  SOCKS_PORT="${port}"
  SOCKS_USER="${user}"
  SOCKS_PASS="${pass}"
  save_cred

  banner
  msg "安装完成"
  show_proxy_info
  pause
  return 0
}

do_status() {
  banner
  echo -e "${BOLD}服务状态${RESET}"
  echo ""

  echo -e "  系统: ${CYAN}${OS_ID}${RESET}"
  echo -e "  家族: ${CYAN}${OS_FAMILY}${RESET}"
  echo -e "  包管理器: ${CYAN}${PKG_MGR}${RESET}"
  echo -e "  init: ${CYAN}${INIT_SYS}${RESET}"
  echo -e "  服务名: ${CYAN}${SVC_NAME}${RESET}"
  echo -e "  配置文件: ${CYAN}${CONF_FILE}${RESET}"
  echo -e "  可执行文件: ${CYAN}${SOCKD_BIN}${RESET}"
  echo ""

  if svc_is_active; then
    echo -e "  状态: ${GREEN}● 运行中${RESET}"
  else
    echo -e "  状态: ${RED}✗ 未运行${RESET}"
  fi

  if load_cred; then
    echo -e "  端口: ${GREEN}${SOCKS_PORT}${RESET}"
    echo -e "  用户: ${GREEN}${SOCKS_USER}${RESET}"
  fi

  echo ""
  if [[ "${INIT_SYS}" == "systemd" ]]; then
    systemctl --no-pager --full status "${SVC_NAME}" 2>/dev/null | sed -n '1,12p' || true
  fi
  pause
  return 0
}

do_view() {
  banner
  echo -e "${BOLD}代理信息${RESET}"

  if load_cred; then
    show_proxy_info
  else
    echo ""
    warn "未找到已保存的代理信息"
    echo ""
  fi

  pause
  return 0
}

do_edit() {
  local port user pass ext_if old_port

  if ! load_cred; then
    warn "未找到已有配置，请先安装"
    pause
    return 0
  fi

  old_port="${SOCKS_PORT}"
  ext_if="$(get_default_if)"

  banner
  echo -e "${BOLD}编辑代理${RESET}"
  echo ""

  read -rp "请输入端口 [${SOCKS_PORT}]: " port
  port="${port:-$SOCKS_PORT}"
  if ! validate_port "${port}"; then
    err "端口无效"
    pause
    return 0
  fi

  read -rp "请输入用户名 [${SOCKS_USER}]: " user
  user="${user:-$SOCKS_USER}"
  if ! validate_username "${user}"; then
    err "用户名无效"
    pause
    return 0
  fi

  read -rp "请输入密码 [保持原值]: " pass
  pass="${pass:-$SOCKS_PASS}"

  ensure_socks_user "${user}" "${pass}"
  write_config "${port}" "${ext_if}"
  svc_enable
  svc_start

  if [[ "${old_port}" != "${port}" ]]; then
    close_firewall_port "${old_port}"
    open_firewall_port "${port}"
  fi

  SOCKS_PORT="${port}"
  SOCKS_USER="${user}"
  SOCKS_PASS="${pass}"
  save_cred

  banner
  msg "修改完成"
  show_proxy_info
  pause
  return 0
}

remove_package() {
  case "${PKG_MGR}" in
    apt)
      apt-get remove -y "${PKG_NAME}" >/dev/null 2>&1 || true
      apt-get purge -y "${PKG_NAME}" >/dev/null 2>&1 || true
      apt-get autoremove -y >/dev/null 2>&1 || true
      ;;
    yum)
      yum remove -y "${PKG_NAME}" >/dev/null 2>&1 || yum remove -y dante >/dev/null 2>&1 || true
      ;;
    dnf)
      dnf remove -y "${PKG_NAME}" >/dev/null 2>&1 || dnf remove -y dante >/dev/null 2>&1 || true
      ;;
    apk)
      apk del "${PKG_NAME}" >/dev/null 2>&1 || true
      ;;
    pacman)
      pacman -Rns --noconfirm "${PKG_NAME}" >/dev/null 2>&1 || true
      ;;
    zypper)
      zypper --non-interactive remove "${PKG_NAME}" >/dev/null 2>&1 || true
      ;;
  esac
  return 0
}

do_uninstall() {
  local ans old_port old_user

  banner
  echo -e "${BOLD}卸载 SOCKS5${RESET}"
  echo ""
  read -rp "确认卸载？[y/N]: " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || return 0

  old_port=""
  old_user=""

  if load_cred; then
    old_port="${SOCKS_PORT:-}"
    old_user="${SOCKS_USER:-}"
  fi

  svc_stop

  [[ -n "${old_port}" ]] && close_firewall_port "${old_port}"

  rm -f "${CONF_FILE}"
  rm -f "${CRED_FILE}"

  if [[ -n "${old_user}" ]] && id "${old_user}" >/dev/null 2>&1; then
    userdel "${old_user}" >/dev/null 2>&1 || true
  fi

  remove_package

  banner
  msg "卸载完成"
  pause
  return 0
}

install_self_cmd() {
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    cp -f "${BASH_SOURCE[0]}" "${SCRIPT_PATH}" 2>/dev/null || true
    chmod +x "${SCRIPT_PATH}" 2>/dev/null || true
  fi
  return 0
}

main_menu() {
  while true; do
    banner

    if svc_is_active 2>/dev/null; then
      local info=""
      load_cred 2>/dev/null && info="  端口: ${GREEN}${SOCKS_PORT}${RESET}" || true
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
