#!/usr/bin/env bash
set -eo pipefail

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

OS_ID="unknown"
OS_FAMILY=""
PKG_MGR=""
INIT_SYS="systemd"
SVC_NAME="danted"
CONF_FILE="/etc/danted.conf"
SOCKD_BIN="/usr/sbin/danted"

# ========================================
#  系统检测
# ========================================

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # 临时关闭 -e 保护 source
    set +e
    OS_ID=$(grep -oP '(?<=^ID=).+' /etc/os-release 2>/dev/null | tr -d '"' | tr '[:upper:]' '[:lower:]')
    set -e
    OS_ID="${OS_ID:-unknown}"
  elif [[ -f /etc/redhat-release ]]; then
    OS_ID="centos"
  fi

  case "${OS_ID}" in
    debian|ubuntu|linuxmint|pop|kali|deepin|raspbian)
      OS_FAMILY="debian"; PKG_MGR="apt"
      SVC_NAME="danted"; CONF_FILE="/etc/danted.conf"; SOCKD_BIN="/usr/sbin/danted"
      ;;
    centos|rhel|almalinux|rocky|ol|amzn|scientific|eurolinux)
      OS_FAMILY="rhel"
      if command -v dnf &>/dev/null; then PKG_MGR="dnf"; else PKG_MGR="yum"; fi
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
      echo -e "${RED}不支持的系统: ${OS_ID}${RESET}"
      echo -e "${YELLOW}尝试按 Debian 系处理...${RESET}"
      if command -v apt-get &>/dev/null; then
        OS_FAMILY="debian"; PKG_MGR="apt"
        SVC_NAME="danted"; CONF_FILE="/etc/danted.conf"; SOCKD_BIN="/usr/sbin/danted"
      elif command -v yum &>/dev/null || command -v dnf &>/dev/null; then
        OS_FAMILY="rhel"
        if command -v dnf &>/dev/null; then PKG_MGR="dnf"; else PKG_MGR="yum"; fi
        SVC_NAME="sockd"; CONF_FILE="/etc/sockd.conf"; SOCKD_BIN="/usr/sbin/sockd"
      elif command -v apk &>/dev/null; then
        OS_FAMILY="alpine"; PKG_MGR="apk"
        SVC_NAME="sockd"; CONF_FILE="/etc/sockd.conf"; SOCKD_BIN="/usr/sbin/sockd"
      elif command -v pacman &>/dev/null; then
        OS_FAMILY="arch"; PKG_MGR="pacman"
        SVC_NAME="sockd"; CONF_FILE="/etc/sockd.conf"; SOCKD_BIN="/usr/bin/sockd"
      else
        echo -e "${RED}无法识别包管理器，退出${RESET}"; exit 1
      fi
      ;;
  esac

  # 检测 init 系统
  if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
    INIT_SYS="systemd"
  elif command -v rc-service &>/dev/null; then
    INIT_SYS="openrc"
  else
    INIT_SYS="systemd"
  fi

  echo -e "  ${DIM}检测到: ${OS_ID} (${OS_FAMILY}) / ${INIT_SYS}${RESET}" >&2
}

# ========================================
#  服务管理抽象层
# ========================================

svc_start()   { if [[ "${INIT_SYS}" == "openrc" ]]; then rc-service "${SVC_NAME}" start; else systemctl start "${SVC_NAME}"; fi; }
svc_stop()    { if [[ "${INIT_SYS}" == "openrc" ]]; then rc-service "${SVC_NAME}" stop 2>/dev/null || true; else systemctl stop "${SVC_NAME}" 2>/dev/null || true; fi; }
svc_restart() { if [[ "${INIT_SYS}" == "openrc" ]]; then rc-service "${SVC_NAME}" restart; else systemctl daemon-reload; systemctl restart "${SVC_NAME}"; fi; }
svc_enable()  { if [[ "${INIT_SYS}" == "openrc" ]]; then rc-update add "${SVC_NAME}" default 2>/dev/null || true; else systemctl enable "${SVC_NAME}"; fi; }
svc_disable() { if [[ "${INIT_SYS}" == "openrc" ]]; then rc-update del "${SVC_NAME}" default 2>/dev/null || true; else systemctl disable "${SVC_NAME}" 2>/dev/null || true; fi; }

svc_is_active() {
  if [[ "${INIT_SYS}" == "openrc" ]]; then
    rc-service "${SVC_NAME}" status &>/dev/null
  else
    systemctl is-active --quiet "${SVC_NAME}" 2>/dev/null
  fi
}

svc_is_enabled() {
  if [[ "${INIT_SYS}" == "openrc" ]]; then
    rc-update show default 2>/dev/null | grep -q "${SVC_NAME}"
  else
    systemctl is-enabled --quiet "${SVC_NAME}" 2>/dev/null
  fi
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
    || hostname -I 2>/dev/null | awk '{print $1}' \
    || echo "IP获取失败"
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
#  systemd / openrc 服务文件 (编译安装用)
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

create_openrc_service() {
  cat > "/etc/init.d/${SVC_NAME}" <<'ORCEOF'
#!/sbin/openrc-run
description="Dante SOCKS5 Proxy Server"
command="/usr/sbin/sockd"
command_args="-D -f /etc/sockd.conf"
pidfile="/var/run/sockd.pid"
depend() { need net; after firewall; }
ORCEOF
  chmod +x "/etc/init.d/${SVC_NAME}"
}

# ========================================
#  编译安装 dante (fallback)
# ========================================

install_dante_from_source() {
  echo -e "  ${YELLOW}包管理器无 dante，将从源码编译...${RESET}"

  echo "  安装编译依赖..."
  case "${OS_FAMILY}" in
    debian)  apt-get install -y -qq gcc make libpam0g-dev curl tar ;;
    rhel)    ${PKG_MGR} install -y gcc make pam-devel curl tar ;;
    fedora)  dnf install -y gcc make pam-devel curl tar ;;
    suse)    zypper install -y -n gcc make pam-devel curl tar ;;
    alpine)  apk add --no-cache build-base linux-pam-dev curl tar ;;
    arch)    pacman -Sy --noconfirm base-devel pam curl ;;
  esac

  local tmpdir="/tmp/dante-build-$$"
  mkdir -p "${tmpdir}" && cd "${tmpdir}"

  echo "  下载 dante-${DANTE_VER} 源码..."
  if ! curl -sL "${DANTE_SRC}" -o dante.tar.gz; then
    echo -e "  ${RED}下载失败${RESET}"; cd /; rm -rf "${tmpdir}"; return 1
  fi

  tar xzf dante.tar.gz
  cd "dante-${DANTE_VER}"

  echo "  编译中 (可能需要几分钟)..."
  ./configure --prefix=/usr --sysconfdir=/etc >/dev/null 2>&1
  make -j"$(nproc)" >/dev/null 2>&1
  make install >/dev/null 2>&1

  cd /; rm -rf "${tmpdir}"

  if [[ ! -x "${SOCKD_BIN}" ]]; then
    if [[ -x /usr/local/sbin/sockd ]]; then
      SOCKD_BIN="/usr/local/sbin/sockd"
    elif [[ -x /usr/sbin/sockd ]]; then
      SOCKD_BIN="/usr/sbin/sockd"
    else
      echo -e "  ${RED}编译安装失败${RESET}"; return 1
    fi
  fi

  case "${INIT_SYS}" in
    systemd) create_systemd_service ;;
    openrc)  create_openrc_service ;;
  esac

  echo -e "  ${GREEN}源码编译安装完成${RESET}"
}

# ========================================
#  各发行版安装
# ========================================

install_dante() {
  case "${OS_FAMILY}" in
    debian)
      # 修复源
      local codename=""
      codename=$(grep -oP '(?<=^VERSION_CODENAME=).+' /etc/os-release 2>/dev/null | tr -d '"') || true
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
      apt-get install -y -qq dante-server || install_dante_from_source
      ;;
    rhel)
      ${PKG_MGR} install -y epel-release 2>/dev/null || true
      ${PKG_MGR} install -y dante-server 2>/dev/null || install_dante_from_source
      ;;
    fedora)
      dnf install -y dante-server 2>/dev/null || dnf install -y dante 2>/dev/null || install_dante_from_source
      ;;
    alpine)
      apk update
      apk add --no-cache shadow 2>/dev/null || true
      apk add --no-cache dante 2>/dev/null || apk add --no-cache dante-server 2>/dev/null || install_dante_from_source
      ;;
    arch)
      pacman -Sy --noconfirm dante 2>/dev/null || install_dante_from_source
      ;;
    suse)
      zypper install -y -n dante-server 2>/dev/null || zypper install -y -n dante 2>/dev/null || install_dante_from_source
      ;;
  esac
}

remove_dante() {
  case "${OS_FAMILY}" in
    debian)  apt-get remove --purge -y -qq dante-server 2>/dev/null || true; apt-get autoremove -y -qq 2>/dev/null || true ;;
    rhel|fedora) ${PKG_MGR} remove -y dante-server dante 2>/dev/null || true ;;
    alpine)  apk del dante dante-server 2>/dev/null || true ;;
    arch)    pacman -Rns --noconfirm dante 2>/dev/null || true ;;
    suse)    zypper remove -y dante-server dante 2>/dev/null || true ;;
  esac
  rm -f /usr/sbin/sockd /usr/local/sbin/sockd 2>/dev/null || true
  rm -f "/etc/systemd/system/${SVC_NAME}.service" "/etc/init.d/${SVC_NAME}" 2>/dev/null || true
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

  local dp du dpass inp
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
    echo -e "  ${RED}dante 安装失败${RESET}"
    press_enter; return
  fi

  echo -e "  [2/5] 创建用户..."
  if ! id "${user}" &>/dev/null; then
    useradd -M -s /usr/sbin/nologin "${user}" 2>/dev/null \
      || adduser -D -s /usr/sbin/nologin "${user}" 2>/dev/null || true
  fi
  echo "${user}:${pass}" | chpasswd

  echo -e "  [3/5] 写入配置..."
  [[ -f "${CONF_FILE}" ]] && cp "${CONF_FILE}" "${CONF_FILE}.bak.$(date +%s)" 2>/dev/null || true
  write_dante_conf "${port}" "${iface}"

  echo -e "  [4/5] 防火墙..."
  fw_allow "${port}"

  echo -e "  [5/5] 启动服务..."
