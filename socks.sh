#!/usr/bin/env bash
set -euo pipefail

# =============================================
#  Debian 12 SOCKS5 一键安装 & 管理脚本
#  快捷命令: socks
# =============================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

CRED_FILE="/root/.socks5_info"
SCRIPT_PATH="/usr/local/bin/socks"

# ========================================
#  工具函数
# ========================================

banner() {
  clear
  echo ""
  echo -e "  ${BOLD}SOCKS5 管理面板${RESET}"
  echo -e "  ${DIM}─────────────────────────${RESET}"
  echo ""
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}请使用 root 运行${RESET}"
    exit 1
  fi
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
rand_user() { echo "sx_$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 8)"; }
rand_pass() {
  local u l d s f all
  u=$(tr -dc 'A-Z'        < /dev/urandom | head -c 3)
  l=$(tr -dc 'a-z'        < /dev/urandom | head -c 3)
  d=$(tr -dc '0-9'        < /dev/urandom | head -c 3)
  s=$(tr -dc '@#%^&*_+=-' < /dev/urandom | head -c 3)
  f=$(tr -dc 'A-Za-z0-9@#%^&*_+=-' < /dev/urandom | head -c 12)
  all="${u}${l}${d}${s}${f}"
  echo "${all}" | fold -w1 | shuf | tr -d '\n' | head -c 24
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
  if [[ -f "${CRED_FILE}" ]]; then
    source "${CRED_FILE}"
    return 0
  fi
  return 1
}

is_installed() {
  systemctl list-unit-files danted.service &>/dev/null && [[ -f "${CRED_FILE}" ]]
}

write_danted_conf() {
  local port="$1" iface="$2"
  cat > /etc/danted.conf <<EOF
logoutput: syslog

internal: 0.0.0.0 port = ${port}
external: ${iface}

socksmethod: username
user.privileged: root
user.unprivileged: nobody
user.libwrap: nobody

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}
client block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
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

show_proxy_info() {
  if ! load_cred; then
    echo -e "  ${RED}未找到安装信息${RESET}"
    return
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

press_enter() {
  echo ""
  read -rp "$(echo -e "  ${DIM}按 Enter 返回...${RESET}")" _
}

install_shortcut() {
  local self
  self=$(readlink -f "$0")
  [[ "${self}" == "${SCRIPT_PATH}" ]] && return
  cp -f "${self}" "${SCRIPT_PATH}"
  chmod +x "${SCRIPT_PATH}"
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

  read -rp "$(echo -e "  密码   [随机24位]: ")" inp
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

  export DEBIAN_FRONTEND=noninteractive

  echo ""
  echo -e "  [1/6] 更新包索引..."
  apt-get update -y -qq

  echo -e "  [2/6] 安装 dante-server..."
  apt-get install -y -qq dante-server

  echo -e "  [3/6] 创建用户..."
  if ! id "${user}" &>/dev/null; then
    useradd -M -s /usr/sbin/nologin "${user}"
  fi
  echo "${user}:${pass}" | chpasswd

  echo -e "  [4/6] 写入配置..."
  [[ -f /etc/danted.conf ]] && cp /etc/danted.conf "/etc/danted.conf.bak.$(date +%s)"
  write_danted_conf "${port}" "${iface}"

  echo -e "  [5/6] 防火墙..."
  if command -v ufw &>/dev/null; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    ufw --force enable >/dev/null 2>&1 || true
  elif command -v iptables &>/dev/null; then
    iptables -I INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || true
  fi

  echo -e "  [6/6] 启动服务..."
  systemctl daemon-reload
  systemctl enable danted
  systemctl restart danted
  sleep 1

  save_cred "${port}" "${user}" "${pass}"
  install_shortcut

  echo ""
  echo -e "  ${GREEN}✅ 安装完成${RESET}"
  echo ""
  show_proxy_info
  press_enter
}

# ========================================
#  查看状态
# ========================================

do_status() {
  banner

  if systemctl is-active --quiet danted 2>/dev/null; then
    echo -e "  服务:      ${GREEN}● 运行中${RESET}"
  else
    echo -e "  服务:      ${RED}✗ 未运行${RESET}"
  fi

  if systemctl is-enabled --quiet danted 2>/dev/null; then
    echo -e "  开机自启:  ${GREEN}✓ 已启用${RESET}"
  else
    echo -e "  开机自启:  ${RED}✗ 未启用${RESET}"
  fi

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

  local mem
  mem=$(ps -C danted -o rss= 2>/dev/null | awk '{s+=$1} END{printf "%.1f MB", s/1024}' || echo "N/A")
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
  echo -e "  密码: → ${GREEN}${new_pass}${RESET}"
  read -rp "$(echo -e "  确认修改? [Y/n]: ")" c
  [[ "${c:-Y}" =~ ^[Nn]$ ]] && { echo "  已取消"; press_enter; return; }

  if [[ "${new_user}" != "${old_user}" ]]; then
    userdel "${old_user}" 2>/dev/null || true
    if ! id "${new_user}" &>/dev/null; then
      useradd -M -s /usr/sbin/nologin "${new_user}"
    fi
  fi
  echo "${new_user}:${new_pass}" | chpasswd

  if [[ "${new_port}" != "${old_port}" ]]; then
    if command -v ufw &>/dev/null; then
      ufw delete allow "${old_port}/tcp" >/dev/null 2>&1 || true
      ufw allow "${new_port}/tcp" >/dev/null 2>&1 || true
    elif command -v iptables &>/dev/null; then
      iptables -D INPUT -p tcp --dport "${old_port}" -j ACCEPT 2>/dev/null || true
      iptables -I INPUT -p tcp --dport "${new_port}" -j ACCEPT 2>/dev/null || true
    fi
  fi

  write_danted_conf "${new_port}" "${iface}"
  systemctl restart danted
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
    old_user="${SOCKS_USER}"
    old_port="${SOCKS_PORT}"
  fi

  echo ""
  echo "  [1/5] 停止服务..."
  systemctl stop danted 2>/dev/null || true
  systemctl disable danted 2>/dev/null || true

  echo "  [2/5] 卸载 dante-server..."
  apt-get remove --purge -y -qq dante-server 2>/dev/null || true
  apt-get autoremove -y -qq 2>/dev/null || true

  echo "  [3/5] 清理配置..."
  rm -f /etc/danted.conf /etc/danted.conf.bak.* "${CRED_FILE}"

  echo "  [4/5] 删除用户..."
  [[ -n "${old_user}" ]] && userdel "${old_user}" 2>/dev/null || true

  echo "  [5/5] 清理防火墙..."
  if [[ -n "${old_port}" ]] && command -v ufw &>/dev/null; then
    ufw delete allow "${old_port}/tcp" >/dev/null 2>&1 || true
  fi
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

    if systemctl is-active --quiet danted 2>/dev/null; then
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
main_menu
