#!/usr/bin/env bash
set -euo pipefail

# =============================================
#  SOCKS5 一键安装 & 管理脚本
#  支持: Debian/Ubuntu/CentOS/RHEL/AlmaLinux
#        Rocky/Fedora/Alpine/Arch/openSUSE
#  快捷命令: socks
# =============================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

CRED_FILE="/root/.socks5_info"
SCRIPT_PATH="/usr/local/bin/socks"
DANTE_VER="1.4.3"
DANTE_SRC="https://www.inet.no/dante/files/dante-${DANTE_VER}.tar.gz"

OS_ID="" OS_FAMILY="" PKG_MGR="" INIT_SYS=""
SVC_NAME="" CONF_FILE="" SOCKD_BIN=""

# ========================================
#  系统检测
# ========================================

detect_os() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID,,}"
  elif [[ -f /etc/redhat-release ]]; then
    OS_ID="centos"
  else
    OS_ID="unknown"
  fi

  case "${OS_ID}" in
    debian|ubuntu|linuxmint|pop|kali|deepin|raspbian)
      OS_FAMILY="debian"; PKG_MGR="apt"
      SVC_NAME="danted"; CONF_FILE="/etc/danted.conf"; SOCKD_BIN="/usr/sbin/danted"
      ;;
    centos|rhel|almalinux|rocky|ol|amzn|scientific|eurolinux)
      OS_FAMILY="rhel"
      PKG_MGR=$(command -v dnf &>/dev/null && echo "dnf" || echo "yum")
      SVC_NAME="sockd"; CONF_FILE="/etc/sockd.conf"; SOCKD_BIN="/usr/sbin/sockd"
      ;;
    fedora)
      OS_FAMILY="fedora"; PKG_MGR="dnf"
      SVC_NAME="sockd"; CONF_FILE="/etc/sockd.conf"; SOCKD_BIN="/usr/sbin/sockd"
      ;;
    alpine)
      OS_FAMILY="alpine"; PKG_MGR="apk"
      SVC_NAME="sockd"; CONF_FILE="/etc/sockd.conf"; SOCKD_BIN="/usr/sbin/sockd"
      ;;
    arch|manjaro|endeavouros|garuda)
      OS_FAMILY="arch"; PKG_MGR="pacman"
      SVC_NAME="sockd"; CONF_FILE="/etc/sockd.conf"; SOCKD_BIN="/usr/bin/sockd"
      ;;
    opensuse*|sles|suse)
      OS_FAMILY="suse"; PKG_MGR="zypper"
      SVC_NAME="sockd"; CONF_FILE="/etc/sockd.conf"; SOCKD_BIN="/usr/sbin/sockd"
      ;;
    *)
      echo -e "${RED}不支持的系统: ${OS_ID}${RESET}"; exit 1
      ;;
  esac

  if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
    INIT_SYS="systemd"
  elif command -v rc-service &>/dev/null; then
    INIT_SYS="openrc"
  else
    INIT_SYS="systemd"
  fi
}

# ========================================
#  服务管理抽象层
# ========================================

svc_start() {
  case "${INIT_SYS}" in
    systemd) systemctl start "${SVC_NAME}" ;;
    openrc)  rc-service "${SVC_NAME}" start ;;
  esac
}

svc_stop() {
  case "${INIT_SYS}" in
    systemd) systemctl stop "${SVC_NAME}" 2>/dev/null || true ;;
    openrc)  rc-service "${SVC_NAME}" stop 2>/dev/null || true ;;
  esac
}

svc_restart() {
  case "${INIT_SYS}" in
    systemd) systemctl daemon-reload; systemctl restart "${SVC_NAME}" ;;
    openrc)  rc-service "${SVC_NAME}" restart ;;
  esac
}

svc_enable() {
  case "${INIT_SYS}" in
    systemd) systemctl enable "${SVC_NAME}" ;;
    openrc)  rc-update add "${SVC_NAME}" default 2>/dev/null || true ;;
  esac
}

svc_disable() {
  case "${INIT_SYS}" in
    systemd) systemctl disable "${SVC_NAME}" 2>/dev/null || true ;;
    openrc)  rc-update del "${SVC_NAME}" default 2>/dev/null || true ;;
  esac
}

svc_is_active() {
  case "${INIT_SYS}" in
    systemd) systemctl is-active --quiet "${SVC_NAME}" 2>/dev/null ;;
    openrc)  rc-service "${SVC_NAME}" status &>/dev/null ;;
  esac
}

svc_is_enabled() {
  case "${INIT_SYS}" in
    systemd) systemctl is-enabled --quiet "${SVC_NAME}" 2>/dev/null ;;
    openrc)  rc-update show default 2>/dev/null | grep -q "${SVC_NAME}" ;;
  esac
}

# ========================================
#  防火墙抽象层
# ========================================

fw_allow() {
  local port="$1"
  if command -v ufw &>/dev/null; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
  elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port="${port}/tcp" &>/dev/null || true
    firewall-cmd --reload &>/dev/null || true
  elif command -v iptables &>/dev/null; then
    iptables -C INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || true
  fi
}

fw_deny() {
  local port="$1"
  if command -v ufw &>/dev/null; then
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
  elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --remove-port="${port}/tcp" &>/dev/null || true
    firewall-cmd --reload &>/dev/null || true
  elif command -v iptables &>/dev/null; then
    iptables -D INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || true
  fi
}

# ========================================
#  通用工具
# ========================================

banner() {
  clear
  echo ""
  echo -e "  ${BOLD}SOCKS5 管理面板${RESET}  ${DIM}(${OS_ID})${RESET}"
  echo -e "  ${DIM}─────────────────────────${RESET}"
  echo ""
}

check_root() {
  [[ $EUID -ne 0 ]] && { echo -e "${RED}请使用 root 运行${RESET}"; exit 1; }
}

get_public_ip() {
  curl -s --max-time 5 ifconfig.me 2>/dev/null \
    || curl -s --max-time 5 ip.sb 2>/dev/null \
    || curl -s --max-time 5 ipinfo.io/ip 2>/dev/null \
    || hostname -I | awk '{print $1}'
}

get_ext_iface() {
  ip route get 8.8.8.8 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1
}

rand_port() { shuf -i 10000-59999 -n 1; }
rand_user() { echo "sx_$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 8)"; }
rand_pass() {
  local u l d all
  u=$(tr -dc 'A-Z' </dev/urandom | head -c 4)
  l=$(tr -dc 'a-z' </dev/urandom | head -c 4)
  d=$(tr -dc '0-9' </dev/urandom | head -c 4)
  all="${u}${l}${d}"
  echo "${all}" | fold -w1 | shuf | tr -d '\n' | head -c 12
}

save_cred() {
  cat > "${CRED_FILE}" <<EOF
SOCKS_PORT=${1}
SOCKS_USER=${2}
SOCKS_PASS=${3}
INSTALL_DATE=$(date '+%Y-%m-%d %H:%M:%S')
EOF
  chmod 600 "${CRED_FILE}"
}

load_cred() {
  [[ -f "${CRED_FILE}" ]] && { source "${CRED_FILE}"; return 0; }
  return 1
}

is_installed() {
  [[ -f "${CONF_FILE}" ]] && [[ -f "${CRED_FILE}" ]]
}

press_enter() {
  echo ""
  read -rp "$(echo -e "  ${DIM}按 Enter 返回...${RESET}")" _
}

install_shortcut() {
  local self
  self=$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")
  [[ "${self}" == "${SCRIPT_PATH}" ]] && return
  cp -f "${self}" "${SCRIPT_PATH}" 2>/dev/null || true
  chmod +x "${SCRIPT_PATH}" 2>/dev/null || true
}

# ========================================
#  配置文件
# ========================================

write_dante_conf() {
  local port="$1" iface="$2"
  cat > "${CONF_FILE}" <<EOF
logoutput: syslog

internal: 0.0.0.0 port = ${port}
external: ${iface}

socksmethod: username
user.privileged: root
user.unprivileged: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    protocol: tcp udp
    socksmethod: username
    log: connect disconnect error
}

socks block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
EOF
}

# ========================================
#  创建 systemd 服务文件 (编译安装时)
# ========================================

create_systemd_service() {
  cat > "/etc/systemd/system/${SVC_NAME}.service" <<EOF
[Unit]
Description=Dante SOCKS5 Proxy Server
After=network.target

[Service]
Type=forking
ExecStart=${SOCKD_BIN} -D -f ${CONF_FILE}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

# ========================================
#  创建 OpenRC 服务文件 (Alpine 编译安装时)
# ========================================

create_openrc_service() {
  cat > "/etc/init.d/${SVC_NAME}" <<'EOF'
#!/sbin/openrc-run
description="Dante SOCKS5 Proxy Server"
command="/usr/sbin/sockd"
command_args="-D -f /etc/sockd.conf"
command_background="no"
pidfile="/var/run/sockd.pid"

depend() {
    need net
    after firewall
}
EOF
  chmod +x "/etc/init.d/${SVC_NAME}"
}

# ========================================
#  编译安装 dante (通用 fallback)
# ========================================

install_dante_from_source() {
  echo -e "  ${YELLOW}包管理器无 dante，将从源码编译...${RESET}"

  echo "  安装编译依赖..."
  case "${OS_FAMILY}" in
    rhel)
      ${PKG_MGR} groupinstall -y "Development Tools" 2>/dev/null \
        || ${PKG_MGR} install -y gcc make 2>/dev/null || true
      ${PKG_MGR} install -y pam-devel curl tar 2>/dev/null || true
      ;;
    fedora)
      dnf install -y gcc make pam-devel curl tar 2>/dev/null || true
      ;;
    suse)
      zypper install -y -n gcc make pam-devel curl tar 2>/dev/null || true
      ;;
    alpine)
      apk add --no-cache build-base linux-pam-dev curl tar 2>/dev/null || true
      ;;
  esac

  local tmpdir="/tmp/dante-build-$$"
  mkdir -p "${tmpdir}" && cd "${tmpdir}"

  echo "  下载 dante-${DANTE_VER} 源码..."
  if ! curl -sL "${DANTE_SRC}" -o dante.tar.gz; then
    echo -e "  ${RED}下载失败${RESET}"; return 1
  fi

  tar xzf dante.tar.gz
  cd "dante-${DANTE_VER}"

  echo "  编译中 (可能需要几分钟)..."
  ./configure --prefix=/usr --sysconfdir=/etc --quiet 2>/dev/null
  make -j"$(nproc)" --quiet 2>/dev/null
  make install --quiet 2>/dev/null

  cd /; rm -rf "${tmpdir}"

  # 确认安装成功
  if [[ ! -x "${SOCKD_BIN}" ]]; then
    # 可能装到了 /usr/local
    if [[ -x /usr/local/sbin/sockd ]]; then
      SOCKD_BIN="/usr/local/sbin/sockd"
    else
      echo -e "  ${RED}编译安装失败${RESET}"; return 1
    fi
  fi

  # 创建服务文件
  case "${INIT_SYS}" in
    systemd) create_systemd_service ;;
    openrc)  create_openrc_service ;;
  esac

  echo -e "  ${GREEN}源码编译安装完成${RESET}"
}

# ========================================
#  各发行版安装
# ========================================

install_dante_debian() {
  # 修复源
  local codename
  codename=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}" || echo "")

  if [[ -n "${codename}" ]] && ! grep -qE "^deb .* ${codename} main" /etc/apt/sources.list 2>/dev/null; then
    cp /etc/apt/sources.list "/etc/apt/sources.list.bak.$(date +%s)" 2>/dev/null || true
    cat > /etc/apt/sources.list <<SRCEOF
deb http://deb.debian.org/debian ${codename} main contrib non-free non-free-firmware
deb http://deb.debian.org/debian ${codename}-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security ${codename}-security main contrib non-free non-free-firmware
SRCEOF
    echo -e "  ${GREEN}软件源已修复${RESET}"
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y -qq
  apt-get install -y -qq dante-server || return 1
}

install_dante_rhel() {
  # RHEL/CentOS 标准源和 EPEL 一般没有 dante
  # 尝试安装 EPEL
  ${PKG_MGR} install -y epel-release 2>/dev/null || true

  if ${PKG_MGR} install -y dante-server 2>/dev/null; then
    # 如果 EPEL 有包，检查服务文件
    [[ ! -f "/etc/systemd/system/${SVC_NAME}.service" ]] \
      && [[ ! -f "/usr/lib/systemd/system/${SVC_NAME}.service" ]] \
      && create_systemd_service
    return 0
  fi

  install_dante_from_source
}

install_dante_fedora() {
  dnf install -y dante-server 2>/dev/null && return 0
  dnf install -y dante 2>/dev/null && return 0
  install_dante_from_source
}

install_dante_alpine() {
  apk update
  apk add --no-cache shadow  # 提供 chpasswd useradd

  if apk add --no-cache dante 2>/dev/null || apk add --no-cache dante-server 2>/dev/null; then
    return 0
  fi

  install_dante_from_source
}

install_dante_arch() {
  pacman -Sy --noconfirm dante 2>/dev/null && return 0
  install_dante_from_source
}

install_dante_suse() {
  zypper install -y -n dante-server 2>/dev/null && return 0
  zypper install -y -n dante 2>/dev/null && return 0
  install_dante_from_source
}

install_dante() {
  case "${OS_FAMILY}" in
    debian)  install_dante_debian ;;
    rhel)    install_dante_rhel ;;
    fedora)  install_dante_fedora ;;
    alpine)  install_dante_alpine ;;
    arch)    install_dante_arch ;;
    suse)    install_dante_suse ;;
  esac
}

# ========================================
#  卸载 dante
# ========================================

remove_dante() {
  case "${OS_FAMILY}" in
    debian)
      apt-get remove --purge -y -qq dante-server 2>/dev/null || true
      apt-get autoremove -y -qq 2>/dev/null || true
      ;;
    rhel|fedora)
      ${PKG_MGR} remove -y dante-server dante 2>/dev/null || true
      ;;
    alpine)
      apk del dante dante-server 2>/dev/null || true
      ;;
    arch)
      pacman -Rns --noconfirm dante 2>/dev/null || true
      ;;
    suse)
      zypper remove -y dante-server dante 2>/dev/null || true
      ;;
  esac

  # 清理编译安装的残留
  rm -f /usr/sbin/sockd /usr/local/sbin/sockd 2>/dev/null || true
  rm -f "/etc/systemd/system/${SVC_NAME}.service" 2>/dev/null || true
  rm -f "/etc/init.d/${SVC_NAME}" 2>/dev/null || true
  [[ "${INIT_SYS}" == "systemd" ]] && systemctl daemon-reload 2>/dev/null || true
}

# ========================================
#  显示代理信息
# ========================================

show_proxy_info() {
  if ! load_cred; then
    echo -e "  ${RED}未找到安装信息${RESET}"; return
  fi
  local ip
  ip=$(get_public_ip)
  local url="socks5://${SOCKS_USER}:${SOCKS_PASS}@${ip}:${SOCKS_PORT}"

  echo -e "  协议:    ${GREEN}SOCKS5${RESET}"
  echo -e "  地址:    ${GREEN}${ip}${RESET}"
  echo -e "  端口:    ${GREEN}${SOCKS_PORT}${RESET}"
  echo -e "  用户名:  ${GREEN}${SOCKS_USER}${RESET}"
  echo -e "  密码:    ${GREEN}${SOCKS_PASS}${RESET}"
  echo ""
  echo -e "  ${BOLD}URL:${RESET} ${YELLOW}${url}${RESET}"
  echo ""
  echo -e "  ${DIM}测试: curl -x socks5h://${SOCKS_USER}:${SOCKS_PASS}@${ip}:${SOCKS_PORT} https://ifconfig.me${RESET}"
  echo ""
}

# ========================================
#  安装
# ========================================

do_install() {
  banner
  if is_installed 2>/dev/null; then
    echo -e "  ${YELLOW}已安装，如需重装请先卸载${RESET}"
    press_enter; return
  fi

  echo -e "  ${DIM}留空回车 → 自动随机生成${RESET}"
  echo ""

  local dp du dpass
  dp=$(rand_port); du=$(rand_user); dpass=$(rand_pass)

  read -rp "$(echo -e "  端口   [${dp}]: ")" inp
  local port="${inp:-${dp}}"
  if ! [[ "${port}" =~ ^[0-9]+$ ]] || (( port<1 || port>65535 )); then
    echo -e "  ${RED}端口无效，使用 ${dp}${RESET}"; port="${dp}"
  fi

  read -rp "$(echo -e "  用户名 [${du}]: ")" inp
  local user="${inp:-${du}}"

  read -rp "$(echo -e "  密码   [随机12位]: ")" inp
  local pass="${inp:-${dpass}}"

  local iface
  iface=$(get_ext_iface)
  if [[ -z "${iface}" ]]; then
    read -rp "  无法检测网卡，请输入(如 eth0): " iface
    [[ -z "${iface}" ]] && { echo "  退出"; return; }
  fi

  echo ""
  echo -e "  端口=${GREEN}${port}${RESET}  用户=${GREEN}${user}${RESET}  网卡=${GREEN}${iface}${RESET}"
  read -rp "$(echo -e "  确认安装? [Y/n]: ")" c
  [[ "${c:-Y}" =~ ^[Nn]$ ]] && { echo "  已取消"; return; }

  echo ""
  echo -e "  [1/5] 安装 dante..."
  if ! install_dante; then
    echo -e "  ${RED}dante 安装失败，请检查系统环境${RESET}"
    press_enter; return
  fi

  echo -e "  [2/5] 创建用户..."
  if ! id "${user}" &>/dev/null; then
    useradd -M -s /usr/sbin/nologin "${user}" 2>/dev/null \
      || adduser -D -s /usr/sbin/nologin "${user}" 2>/dev/null  # Alpine busybox
  fi
  echo "${user}:${pass}" | chpasswd

  echo -e "  [3/5] 写入配置..."
  [[ -f "${CONF_FILE}" ]] && cp "${CONF_FILE}" "${CONF_FILE}.bak.$(date +%s)" 2>/dev/null || true
  write_dante_conf "${port}" "${iface}"

  echo -e "  [4/5] 防火墙..."
  fw_allow "${port}"

  echo -e "  [5/5] 启动服务..."
  svc_enable
  svc_restart
  sleep 1

  save_cred "${port}" "${user}" "${pass}"
  install_shortcut

  echo ""
  if svc_is_active; then
    echo -e "  ${GREEN}✅ 安装完成${RESET}"
  else
    echo -e "  ${YELLOW}⚠ 安装完成但服务未运行，请检查日志${RESET}"
  fi
  echo ""
  show_proxy_info
  press_enter
}

# ========================================
#  查看状态
# ========================================

do_status() {
  banner

  if svc_is_active; then
    echo -e "  服务:      ${GREEN}● 运行中${RESET}"
  else
    echo -e "  服务:      ${RED}✗ 未运行${RESET}"
  fi

  if svc_is_enabled; then
    echo -e "  开机自启:  ${GREEN}✓ 已启用${RESET}"
  else
    echo -e "  开机自启:  ${RED}✗ 未启用${RESET}"
  fi

  echo -e "  系统:      ${CYAN}${OS_ID} (${INIT_SYS})${RESET}"

  if load_cred; then
    local listen
    listen=$(ss -lntp 2>/dev/null | grep ":${SOCKS_PORT} " || true)
    if [[ -n "${listen}" ]]; then
      echo -e "  端口监听:  ${GREEN}✓ ${SOCKS_PORT}${RESET}"
    else
      echo -e "  端口监听:  ${RED}✗ ${SOCKS_PORT}${RESET}"
    fi

    local conns
    conns=$(ss -tnp 2>/dev/null | grep -c ":${SOCKS_PORT} " || echo "0")
    echo -e "  当前连接:  ${CYAN}${conns}${RESET}"
    echo -e "  安装时间:  ${DIM}${INSTALL_DATE:-未知}${RESET}"
  else
    echo -e "  ${YELLOW}未安装${RESET}"
  fi

  local proc_name
  proc_name=$(basename "${SOCKD_BIN}" 2>/dev/null || echo "sockd")
  local mem
  mem=$(ps -C "${proc_name}" -o rss= 2>/dev/null | awk '{s+=$1} END{if(s>0) printf "%.1f MB", s/1024; else print "N/A"}' || echo "N/A")
  echo -e "  内存占用:  ${CYAN}${mem}${RESET}"

  press_enter
}

# ========================================
#  查看代理
# ========================================

do_view() {
  banner
  show_proxy_info
  press_enter
}

# ========================================
#  编辑代理
# ========================================

do_edit() {
  banner
  if ! load_cred; then
    echo -e "  ${RED}未安装，请先安装${RESET}"; press_enter; return
  fi

  local iface
  iface=$(get_ext_iface)

  echo -e "  当前: 端口=${GREEN}${SOCKS_PORT}${RESET}  用户=${GREEN}${SOCKS_USER}${RESET}"
  echo -e "  ${DIM}留空回车 = 保持不变${RESET}"
  echo ""

  local old_port="${SOCKS_PORT}" old_user="${SOCKS_USER}" old_pass="${SOCKS_PASS}"

  read -rp "$(echo -e "  新端口   [${old_port}]: ")" new_port
  read -rp "$(echo -e "  新用户名 [${old_user}]: ")" new_user
  read -rp "$(echo -e "  新密码   [不变]: ")" new_pass

  new_port="${new_port:-${old_port}}"
  new_user="${new_user:-${old_user}}"
  new_pass="${new_pass:-${old_pass}}"

  if ! [[ "${new_port}" =~ ^[0-9]+$ ]] || (( new_port<1 || new_port>65535 )); then
    echo -e "  ${RED}端口无效，保持原值${RESET}"; new_port="${old_port}"
  fi

  if [[ "${new_port}" == "${old_port}" && "${new_user}" == "${old_user}" && "${new_pass}" == "${old_pass}" ]]; then
    echo -e "\n  ${YELLOW}无修改${RESET}"; press_enter; return
  fi

  echo ""
  echo -e "  端口: ${old_port} → ${GREEN}${new_port}${RESET}"
  echo -e "  用户: ${old_user} → ${GREEN}${new_user}${RESET}"
  read -rp "$(echo -e "  确认修改? [Y/n]: ")" c
  [[ "${c:-Y}" =~ ^[Nn]$ ]] && { echo "  已取消"; press_enter; return; }

  # 用户变更
  if [[ "${new_user}" != "${old_user}" ]]; then
    userdel "${old_user}" 2>/dev/null || true
    if ! id "${new_user}" &>/dev/null; then
      useradd -M -s /usr/sbin/nologin "${new_user}" 2>/dev/null \
        || adduser -D -s /usr/sbin/nologin "${new_user}" 2>/dev/null
    fi
  fi
  echo "${new_user}:${new_pass}" | chpasswd

  # 端口变更 → 防火墙
  if [[ "${new_port}" != "${old_port}" ]]; then
    fw_deny "${old_port}"
    fw_allow "${new_port}"
  fi

  write_dante_conf "${new_port}" "${iface}"
  svc_restart
  sleep 1

  save_cred "${new_port}" "${new_user}" "${new_pass}"

  echo ""
  echo -e "  ${GREEN}✅ 修改完成${RESET}"
  echo ""
  show_proxy_info
  press_enter
}

# ========================================
#  卸载
# ========================================

do_uninstall() {
  banner
  echo -e "  ${RED}⚠ 将彻底删除 SOCKS5 服务${RESET}"
  echo ""
  read -rp "  输入 YES 确认卸载: " c
  [[ "${c}" != "YES" ]] && { echo "  已取消"; press_enter; return; }

  local old_user="" old_port=""
  if load_cred; then
    old_user="${SOCKS_USER}"; old_port="${SOCKS_PORT}"
  fi

  echo ""
  echo "  [1/5] 停止服务..."
  svc_stop; svc_disable

  echo "  [2/5] 卸载 dante..."
  remove_dante

  echo "  [3/5] 清理配置..."
  rm -f "${CONF_FILE}" "${CONF_FILE}".bak.* "${CRED_FILE}"

  echo "  [4/5] 删除用户..."
  [[ -n "${old_user}" ]] && { userdel "${old_user}" 2>/dev/null || true; }

  echo "  [5/5] 清理防火墙..."
  [[ -n "${old_port}" ]] && fw_deny "${old_port}"
  rm -f "${SCRIPT_PATH}"

  echo ""
  echo -e "  ${GREEN}✅ 卸载完成${RESET}"
  echo ""
  exit 0
}

# ========================================
#  主菜单
# ========================================

main_menu() {
  while true; do
    banner

    if svc_is_active 2>/dev/null; then
      echo -e "  状态: ${GREEN}● 运行中${RESET}$(load_cred 2>/dev/null && echo -e "  端口: ${GREEN}${SOCKS_PORT}${RESET}" || true)"
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
    read -rp "  请选择 [0-5]: " choice

    case "${choice}" in
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
main_menu
