#!/usr/bin/env bash
#
# SOCKS5 代理一键管理脚本
# 支持：安装 / 卸载 / 启停 / 更新 / 配置修改
# 后端：Xray-core
#

set -euo pipefail

# ======================== 全局变量 ========================
SCRIPT_URL="https://raw.githubusercontent.com/moyuem/ddns-cf/main/socks.sh"
SCRIPT_PATH="/usr/local/bin/socks"
INSTALL_DIR="/usr/local/etc/xray"
CONFIG_FILE="${INSTALL_DIR}/config.json"
XRAY_BIN="/usr/local/bin/xray"
SERVICE_NAME="xray-socks"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
LOG_DIR="/var/log/${SERVICE_NAME}"
DATA_FILE="${INSTALL_DIR}/.user_data"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ======================== 工具函数 ========================
msg()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

check_root() {
  if [[ ${EUID} -ne 0 ]]; then
    err "请使用 root 用户运行此脚本"
    exit 1
  fi
}

check_os() {
  if [[ ! -f /etc/os-release ]]; then
    err "不支持的操作系统"
    exit 1
  fi
  . /etc/os-release
  OS_ID="${ID,,}"
}

press_any_key() {
  echo ""
  read -rp "按回车键返回菜单..." _
}

# ======================== 网络工具 ========================
get_public_ip() {
  local ip=""
  # 强制 IPv4
  ip="$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || true)"
  [[ -z "${ip}" ]] && ip="$(curl -4 -s --max-time 5 ip.sb 2>/dev/null || true)"
  [[ -z "${ip}" ]] && ip="$(curl -4 -s --max-time 5 api.ipify.org 2>/dev/null || true)"
  [[ -z "${ip}" ]] && ip="$(curl -4 -s --max-time 5 ipv4.icanhazip.com 2>/dev/null || true)"
  echo "${ip}"
}

get_arch() {
  local arch
  arch="$(uname -m)"
  case "${arch}" in
    x86_64|amd64)     echo "64" ;;
    aarch64|arm64)     echo "arm64-v8a" ;;
    armv7l|armhf)      echo "arm32-v7a" ;;
    *)                 echo "" ;;
  esac
}

random_string() {
  local len="${1:-16}"
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${len}"
}

random_port() {
  local port
  while true; do
    port=$(( RANDOM % 40000 + 20000 ))
    if ! ss -tlnp | grep -q ":${port} "; then
      echo "${port}"
      return
    fi
  done
}

# ======================== 快捷命令安装 ========================
install_self_cmd() {
  local src=""
  if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    src="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
  fi
  # 已经是从快捷命令运行
  [[ "${src}" == "${SCRIPT_PATH}" ]] && return 0

  # 本地文件可用 → 直接复制
  if [[ -n "${src}" && -f "${src}" ]]; then
    cp -f "${src}" "${SCRIPT_PATH}" 2>/dev/null || true
    chmod +x "${SCRIPT_PATH}" 2>/dev/null || true
    return 0
  fi

  # 通过 bash <(curl ...) 运行，从远程下载
  if curl -sL --max-time 15 "${SCRIPT_URL}" -o "${SCRIPT_PATH}" 2>/dev/null; then
    chmod +x "${SCRIPT_PATH}"
    msg "已安装快捷命令: socks"
  else
    warn "快捷命令安装失败，可手动运行脚本"
  fi
  return 0
}

# ======================== 依赖安装 ========================
install_deps() {
  msg "安装基础依赖..."
  case "${OS_ID}" in
    ubuntu|debian)
      apt-get update -qq
      apt-get install -y -qq curl wget unzip jq >/dev/null 2>&1
      ;;
    centos|rhel|rocky|alma|fedora)
      yum install -y -q curl wget unzip jq >/dev/null 2>&1
      ;;
    *)
      warn "未知发行版，请确保已安装 curl wget unzip jq"
      ;;
  esac
}

# ======================== Xray 安装 ========================
install_xray() {
  if [[ -f "${XRAY_BIN}" ]]; then
    msg "Xray 已存在，跳过下载"
    return 0
  fi

  local arch
  arch="$(get_arch)"
  if [[ -z "${arch}" ]]; then
    err "不支持的系统架构: $(uname -m)"
    return 1
  fi

  msg "获取 Xray 最新版本..."
  local latest_ver
  latest_ver=$(curl -sL --max-time 10 \
    "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
    | jq -r '.tag_name' 2>/dev/null || true)

  if [[ -z "${latest_ver}" || "${latest_ver}" == "null" ]]; then
    err "获取 Xray 版本失败"
    return 1
  fi

  msg "下载 Xray ${latest_ver} (${arch})..."
  local dl_url="https://github.com/XTLS/Xray-core/releases/download/${latest_ver}/Xray-linux-${arch}.zip"
  local tmp_zip="/tmp/xray_$$.zip"
  local tmp_dir="/tmp/xray_$$"

  if ! curl -sL --max-time 120 "${dl_url}" -o "${tmp_zip}"; then
    err "下载 Xray 失败"
    return 1
  fi

  mkdir -p "${tmp_dir}"
  unzip -qo "${tmp_zip}" -d "${tmp_dir}"
  cp -f "${tmp_dir}/xray" "${XRAY_BIN}"
  chmod +x "${XRAY_BIN}"

  rm -rf "${tmp_zip}" "${tmp_dir}"
  msg "Xray ${latest_ver} 安装完成"
}

# ======================== 配置生成 ========================
generate_config() {
  local port="$1" user="$2" pass="$3"

  mkdir -p "${INSTALL_DIR}" "${LOG_DIR}"

  cat > "${CONFIG_FILE}" <<EOF
{
  "log": {
    "access": "${LOG_DIR}/access.log",
    "error": "${LOG_DIR}/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "socks-in",
      "port": ${port},
      "listen": "0.0.0.0",
      "protocol": "socks",
      "settings": {
        "auth": "password",
        "accounts": [
          {
            "user": "${user}",
            "pass": "${pass}"
          }
        ],
        "udp": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF

  # 保存用户数据（供后续读取）
  cat > "${DATA_FILE}" <<EOF
PORT=${port}
USER=${user}
PASS=${pass}
EOF

  msg "配置文件已生成: ${CONFIG_FILE}"
}

# ======================== systemd 服务 ========================
create_service() {
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=Xray SOCKS5 Proxy Service
Documentation=https://xtls.github.io
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -config ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}" >/dev/null 2>&1
  msg "systemd 服务已创建"
}

# ======================== 防火墙 ========================
open_firewall() {
  local port="$1"

  # ufw
  if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
    ufw allow "${port}/tcp" >/dev/null 2>&1
    ufw allow "${port}/udp" >/dev/null 2>&1
    msg "ufw 已放行端口 ${port}"
  fi

  # firewalld
  if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1
    firewall-cmd --permanent --add-port="${port}/udp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    msg "firewalld 已放行端口 ${port}"
  fi

  # iptables（兜底）
  if command -v iptables &>/dev/null; then
    iptables  -C INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null \
      || iptables  -I INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null
    iptables  -C INPUT -p udp --dport "${port}" -j ACCEPT 2>/dev/null \
      || iptables  -I INPUT -p udp --dport "${port}" -j ACCEPT 2>/dev/null
  fi
  if command -v ip6tables &>/dev/null; then
    ip6tables -C INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null \
      || ip6tables -I INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null
    ip6tables -C INPUT -p udp --dport "${port}" -j ACCEPT 2>/dev/null \
      || ip6tables -I INPUT -p udp --dport "${port}" -j ACCEPT 2>/dev/null
  fi
}

close_firewall() {
  local port="$1"
  [[ -z "${port}" ]] && return 0

  if command -v ufw &>/dev/null; then
    ufw delete allow "${port}/tcp" 2>/dev/null || true
    ufw delete allow "${port}/udp" 2>/dev/null || true
  fi

  if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --remove-port="${port}/tcp" 2>/dev/null || true
    firewall-cmd --permanent --remove-port="${port}/udp" 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
  fi

  iptables  -D INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || true
  iptables  -D INPUT -p udp --dport "${port}" -j ACCEPT 2>/dev/null || true
  ip6tables -D INPUT -p tcp --dport "${port}" -j ACCEPT 2>/dev/null || true
  ip6tables -D INPUT -p udp --dport "${port}" -j ACCEPT 2>/dev/null || true
}

# ======================== 读取现有配置 ========================
load_user_data() {
  if [[ -f "${DATA_FILE}" ]]; then
    source "${DATA_FILE}"
    CURRENT_PORT="${PORT:-}"
    CURRENT_USER="${USER:-}"
    CURRENT_PASS="${PASS:-}"
    return 0
  fi
  CURRENT_PORT=""
  CURRENT_USER=""
  CURRENT_PASS=""
  return 1
}

# ======================== 核心功能 ========================

# ---- 安装 ----
install_proxy() {
  echo ""
  msg "========== 安装 SOCKS5 代理 =========="

  # 如果已安装，询问是否重装
  if [[ -f "${XRAY_BIN}" && -f "${CONFIG_FILE}" ]]; then
    warn "检测到已安装，继续将覆盖现有配置"
    read -rp "是否继续？[y/N]: " yn
    [[ "${yn,,}" != "y" ]] && return 0
  fi

  install_deps
  install_xray

  echo ""
  read -rp "设置端口 (留空随机): " input_port
  local port="${input_port:-$(random_port)}"

  read -rp "设置用户名 (留空随机): " input_user
  local user="${input_user:-user$(random_string 5)}"

  read -rp "设置密码 (留空随机): " input_pass
  local pass="${input_pass:-$(random_string 16)}"

  generate_config "${port}" "${user}" "${pass}"
  create_service
  open_firewall "${port}"

  systemctl restart "${SERVICE_NAME}"
  sleep 1

  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    msg "✅ SOCKS5 代理安装并启动成功！"
    echo ""
    show_connection_info "${port}" "${user}" "${pass}"
  else
    err "服务启动失败，请查看日志: journalctl -u ${SERVICE_NAME}"
  fi

  press_any_key
}

# ---- 启动 ----
start_service() {
  if ! systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
    warn "服务未安装，请先安装"
    press_any_key
    return
  fi
  systemctl start "${SERVICE_NAME}"
  sleep 1
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    msg "✅ 服务已启动"
  else
    err "启动失败"
  fi
  press_any_key
}

# ---- 停止 ----
stop_service() {
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  msg "✅ 服务已停止"
  press_any_key
}

# ---- 重启 ----
restart_service() {
  systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
  sleep 1
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    msg "✅ 服务已重启"
  else
    err "重启失败"
  fi
  press_any_key
}

# ---- 状态 ----
show_status() {
  echo ""
  if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    echo -e "  服务状态: ${GREEN}● 运行中${NC}"
  else
    echo -e "  服务状态: ${RED}● 已停止${NC}"
  fi
  echo ""
  systemctl status "${SERVICE_NAME}" --no-pager 2>/dev/null || warn "服务未安装"
  press_any_key
}

# ---- 连接信息 ----
show_connection_info() {
  local port="${1:-}" user="${2:-}" pass="${3:-}"

  if [[ -z "${port}" ]]; then
    if load_user_data; then
      port="${CURRENT_PORT}"
      user="${CURRENT_USER}"
      pass="${CURRENT_PASS}"
    else
      warn "未找到配置信息，请先安装"
      return
    fi
  fi

  local ip
  ip="$(get_public_ip)"
  [[ -z "${ip}" ]] && ip="<服务器IP>"

  echo -e "${CYAN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║          SOCKS5 代理连接信息                 ║"
  echo "  ╠══════════════════════════════════════════════╣"
  echo -e "  ║  地址:   ${ip}"
  echo -e "  ║  端口:   ${port}"
  echo -e "  ║  用户名: ${user}"
  echo -e "  ║  密码:   ${pass}"
  echo "  ╠══════════════════════════════════════════════╣"
  echo -e "  ║  URL:  socks5://${user}:${pass}@${ip}:${port}"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${NC}"
}

show_info() {
  echo ""
  show_connection_info
  press_any_key
}

# ---- 修改配置 ----
modify_config() {
  echo ""
  if ! load_user_data; then
    warn "未找到现有配置，请先安装"
    press_any_key
    return
  fi

  echo "  当前配置:"
  echo "    端口:   ${CURRENT_PORT}"
  echo "    用户名: ${CURRENT_USER}"
  echo "    密码:   ${CURRENT_PASS}"
  echo ""

  read -rp "新端口 (留空不变): " new_port
  read -rp "新用户名 (留空不变): " new_user
  read -rp "新密码 (留空不变): " new_pass

  local port="${new_port:-${CURRENT_PORT}}"
  local user="${new_user:-${CURRENT_USER}}"
  local pass="${new_pass:-${CURRENT_PASS}}"

  # 端口变更时处理防火墙
  if [[ "${port}" != "${CURRENT_PORT}" ]]; then
    close_firewall "${CURRENT_PORT}"
    open_firewall "${port}"
  fi

  generate_config "${port}" "${user}" "${pass}"
  systemctl restart "${SERVICE_NAME}" 2>/dev/null

  sleep 1
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    msg "✅ 配置已更新并重启成功"
    echo ""
    show_connection_info "${port}" "${user}" "${pass}"
  else
    err "重启失败，请检查日志"
  fi

  press_any_key
}

# ---- 更新脚本 ----
update_script() {
  echo ""
  msg "正在检查更新..."
  local tmp="/tmp/socks_update_$$.sh"

  if curl -sL --max-time 15 "${SCRIPT_URL}?t=$(date +%s)" -o "${tmp}" 2>/dev/null; then
    if [[ -s "${tmp}" ]] && grep -q "SCRIPT_URL" "${tmp}"; then
      cp -f "${tmp}" "${SCRIPT_PATH}" && chmod +x "${SCRIPT_PATH}"
      rm -f "${tmp}"
      msg "✅ 更新成功，即将重新加载..."
      sleep 1
      exec "${SCRIPT_PATH}"
    else
      rm -f "${tmp}"
      err "下载的文件校验失败，更新已取消"
    fi
  else
    err "下载失败，请检查网络连接"
  fi

  press_any_key
}

# ---- 完整卸载 ----
full_uninstall() {
  echo ""
  echo -e "${RED}${BOLD}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║            ⚠️  完整卸载警告                   ║"
  echo "  ╠══════════════════════════════════════════════╣"
  echo "  ║  将执行以下操作:                             ║"
  echo "  ║    1. 停止并删除代理服务                     ║"
  echo "  ║    2. 删除 Xray 程序文件                     ║"
  echo "  ║    3. 删除所有配置和日志                     ║"
  echo "  ║    4. 清理防火墙规则                         ║"
  echo "  ║    5. 删除快捷命令 socks                     ║"
  echo "  ║    6. 恢复系统到安装前状态                   ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${NC}"

  read -rp "确认完整卸载？输入 YES 继续: " confirm
  if [[ "${confirm}" != "YES" ]]; then
    msg "已取消卸载"
    press_any_key
    return
  fi

  msg "开始卸载..."

  # 1. 读取端口用于清理防火墙
  local saved_port=""
  if load_user_data; then
    saved_port="${CURRENT_PORT}"
  fi

  # 2. 停止并禁用服务
  if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    systemctl stop "${SERVICE_NAME}" 2>/dev/null
    msg "  ✔ 已停止服务: ${SERVICE_NAME}"
  fi
  if systemctl is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
    systemctl disable "${SERVICE_NAME}" 2>/dev/null
    msg "  ✔ 已禁用服务: ${SERVICE_NAME}"
  fi
  if [[ -f "${SERVICE_FILE}" ]]; then
    rm -f "${SERVICE_FILE}"
    msg "  ✔ 已删除服务文件: ${SERVICE_FILE}"
  fi
  systemctl daemon-reload 2>/dev/null

  # 3. 删除 Xray 二进制
  if [[ -f "${XRAY_BIN}" ]]; then
    rm -f "${XRAY_BIN}"
    msg "  ✔ 已删除程序: ${XRAY_BIN}"
  fi

  # 4. 删除配置和日志目录
  local dirs=("${INSTALL_DIR}" "${LOG_DIR}")
  for d in "${dirs[@]}"; do
    if [[ -d "${d}" ]]; then
      rm -rf "${d}"
      msg "  ✔ 已删除目录: ${d}"
    fi
  done

  # 5. 清理防火墙
  if [[ -n "${saved_port}" ]]; then
    close_firewall "${saved_port}"
    msg "  ✔ 已清理防火墙规则: 端口 ${saved_port}"
  fi

  # 6. 删除快捷命令（脚本自身）
  # 先判断当前是否从 SCRIPT_PATH 运行，是的话最后删
  local self_path=""
  self_path="$(realpath "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"

  if [[ -f "${SCRIPT_PATH}" ]]; then
    rm -f "${SCRIPT_PATH}"
    msg "  ✔ 已删除快捷命令: ${SCRIPT_PATH}"
  fi

  # 如果用户用本地脚本跑的，也提示
  if [[ -n "${self_path}" && -f "${self_path}" && "${self_path}" != "${SCRIPT_PATH}" ]]; then
    echo ""
    warn "当前脚本文件: ${self_path}"
    read -rp "  是否也删除此文件？[y/N]: " del_self
    if [[ "${del_self,,}" == "y" ]]; then
      rm -f "${self_path}"
      msg "  ✔ 已删除: ${self_path}"
    fi
  fi

  echo ""
  echo -e "${GREEN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║     ✅ 卸载完成，系统已恢复到安装前状态     ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${NC}"

  exit 0
}

# ======================== 菜单 ========================
show_menu() {
  clear

  # 服务状态
  local status_text
  if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    status_text="${GREEN}● 运行中${NC}"
  elif [[ -f "${SERVICE_FILE}" ]]; then
    status_text="${RED}● 已停止${NC}"
  else
    status_text="${YELLOW}● 未安装${NC}"
  fi

  echo -e "${CYAN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║         SOCKS5 代理管理面板                  ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "  当前状态: ${status_text}"
  echo ""
  echo -e "  ${BOLD}── 代理管理 ──────────────────────────${NC}"
  echo "  1) 安装 SOCKS5 代理"
  echo "  2) 启动服务"
  echo "  3) 停止服务"
  echo "  4) 重启服务"
  echo ""
  echo -e "  ${BOLD}── 信息查看 ──────────────────────────${NC}"
  echo "  5) 查看服务状态"
  echo "  6) 查看连接信息"
  echo ""
  echo -e "  ${BOLD}── 配置维护 ──────────────────────────${NC}"
  echo "  7) 修改配置 (端口/用户名/密码)"
  echo "  8) 更新脚本"
  echo "  9) 完整卸载"
  echo ""
  echo "  0) 退出"
  echo ""
  read -rp "  请选择 [0-9]: " choice

  case "${choice}" in
    1) install_proxy   ;;
    2) start_service   ;;
    3) stop_service    ;;
    4) restart_service ;;
    5) show_status     ;;
    6) show_info       ;;
    7) modify_config   ;;
    8) update_script   ;;
    9) full_uninstall  ;;
    0) echo ""; msg "再见！"; exit 0 ;;
    *) warn "无效选项，请重新选择"; sleep 1 ;;
  esac
}

# ======================== 主入口 ========================
main() {
  check_root
  check_os
  install_self_cmd

  while true; do
    show_menu
  done
}

main "$@"
