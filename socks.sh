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
XRAY_API_PORT="10085"
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

sha256_file() {
  local file="$1"

  if command -v sha256sum &>/dev/null; then
    sha256sum "${file}" | awk '{print tolower($1)}'
    return 0
  fi

  if command -v shasum &>/dev/null; then
    shasum -a 256 "${file}" | awk '{print tolower($1)}'
    return 0
  fi

  err "未找到 sha256sum 或 shasum，无法校验文件完整性"
  return 1
}

normalize_sha256() {
  local value="${1,,}"

  value="${value//$'\r'/}"
  value="${value//$'\n'/}"
  value="${value//[[:space:]]/}"
  value="${value#sha256:}"
  value="${value#sha256=}"
  value="${value#sha-256=}"
  value="${value#sha2-256=}"

  if [[ "${value}" =~ ^[0-9a-f]{64}$ ]]; then
    printf '%s\n' "${value}"
  fi
}

is_sha256() {
  [[ "${1,,}" =~ ^[0-9a-f]{64}$ ]]
}

extract_sha256_from_file() {
  local checksum_file="$1" target_name="$2"
  local target_lower="${target_name,,}"
  local line lower normalized candidates token

  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%$'\r'}"
    lower="${line,,}"

    normalized="$(normalize_sha256 "${lower}")"
    if [[ -n "${normalized}" ]]; then
      printf '%s\n' "${normalized}"
      return 0
    fi

    if [[ "${lower}" == *"${target_lower}"* || "${lower}" == sha* ]]; then
      candidates="$(printf '%s' "${lower}" | tr -c '0-9a-f' ' ')"
      for token in ${candidates}; do
        if is_sha256 "${token}"; then
          printf '%s\n' "${token}"
          return 0
        fi
      done
    fi
  done < "${checksum_file}"
}

validate_script_file() {
  local script_path="$1"

  [[ -s "${script_path}" ]] || {
    err "脚本文件为空: ${script_path}"
    return 1
  }

  grep -q '^#!/usr/bin/env bash$' "${script_path}" || {
    err "脚本缺少预期的 shebang"
    return 1
  }

  grep -q '^SCRIPT_URL=' "${script_path}" || {
    err "脚本缺少关键常量 SCRIPT_URL"
    return 1
  }

  grep -q '^main() {$' "${script_path}" || {
    err "脚本缺少主入口 main()"
    return 1
  }

  if ! bash -n "${script_path}"; then
    err "脚本语法检查失败"
    return 1
  fi

  return 0
}

validate_port() {
  local port="$1"

  if [[ ! "${port}" =~ ^[0-9]+$ ]]; then
    err "端口必须是数字"
    return 1
  fi

  if (( port < 1 || port > 65535 )); then
    err "端口必须在 1-65535 之间"
    return 1
  fi

  return 0
}

validate_credential() {
  local field_name="$1" value="$2"

  if [[ -z "${value}" ]]; then
    err "${field_name}不能为空"
    return 1
  fi

  if [[ "${value}" == *$'\n'* || "${value}" == *$'\r'* ]]; then
    err "${field_name}不能包含换行"
    return 1
  fi

  if [[ ! "${value}" =~ ^[A-Za-z0-9._~-]+$ ]]; then
    err "${field_name}仅支持字母、数字、点、下划线、波浪线和短横线"
    return 1
  fi

  return 0
}

restore_file_or_remove() {
  local backup_path="$1" target_path="$2"

  if [[ -n "${backup_path}" && -f "${backup_path}" ]]; then
    mv -f "${backup_path}" "${target_path}"
  else
    rm -f "${target_path}"
  fi
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
    x86_64|amd64)      echo "64" ;;
    aarch64|arm64)     echo "arm64-v8a" ;;
    armv7l|armhf)      echo "arm32-v7a" ;;
    *)                 echo "" ;;
  esac
}

random_string() {
  local len="${1:-16}" value=""

  while [[ ${#value} -lt ${len} ]]; do
    value+="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${len}" || true)"
  done

  printf '%s' "${value:0:len}"
}

port_in_use() {
  local port="$1"

  if command -v ss &>/dev/null; then
    ss -tlnu 2>/dev/null | grep -q ":${port} "
    return $?
  fi

  return 1
}

random_port() {
  local port
  while true; do
    port=$(( RANDOM % 40000 + 20000 ))
    if ! port_in_use "${port}"; then
      echo "${port}"
      return
    fi
  done
}

format_bytes() {
  local bytes="${1:-0}"

  awk -v bytes="${bytes}" '
    BEGIN {
      split("B KB MB GB TB PB", units, " ")
      value = bytes + 0
      idx = 1
      while (value >= 1024 && idx < 6) {
        value = value / 1024
        idx++
      }
      if (idx == 1) {
        printf "%.0f %s", value, units[idx]
      } else {
        printf "%.2f %s", value, units[idx]
      }
    }
  '
}

format_duration() {
  local seconds="${1:-0}"
  local days hours minutes

  if ! [[ "${seconds}" =~ ^[0-9]+$ ]]; then
    seconds=0
  fi

  days=$(( seconds / 86400 ))
  seconds=$(( seconds % 86400 ))
  hours=$(( seconds / 3600 ))
  seconds=$(( seconds % 3600 ))
  minutes=$(( seconds / 60 ))
  seconds=$(( seconds % 60 ))

  if (( days > 0 )); then
    printf '%d天 %02d小时 %02d分钟 %02d秒' "${days}" "${hours}" "${minutes}" "${seconds}"
  elif (( hours > 0 )); then
    printf '%d小时 %02d分钟 %02d秒' "${hours}" "${minutes}" "${seconds}"
  elif (( minutes > 0 )); then
    printf '%d分钟 %02d秒' "${minutes}" "${seconds}"
  else
    printf '%d秒' "${seconds}"
  fi
}

get_service_uptime_seconds() {
  local pid uptime

  pid="$(systemctl show "${SERVICE_NAME}" --property=MainPID --value 2>/dev/null || true)"
  if [[ "${pid}" =~ ^[0-9]+$ && "${pid}" -gt 0 ]]; then
    uptime="$(ps -o etimes= -p "${pid}" 2>/dev/null | awk '{print $1; exit}')"
    if [[ "${uptime}" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "${uptime}"
      return 0
    fi
  fi

  return 1
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
  local tmp_script="/tmp/socks_self_$$.sh"
  if curl -sL --max-time 15 "${SCRIPT_URL}" -o "${tmp_script}" 2>/dev/null; then
    if validate_script_file "${tmp_script}"; then
      cp -f "${tmp_script}" "${SCRIPT_PATH}"
      chmod +x "${SCRIPT_PATH}"
      msg "已安装快捷命令: socks"
    else
      warn "下载的快捷命令校验失败，已跳过安装"
    fi
    rm -f "${tmp_script}"
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
    centos|rhel|rocky|alma)
      yum install -y -q curl wget unzip jq >/dev/null 2>&1
      ;;
    fedora)
      dnf install -y -q curl wget unzip jq >/dev/null 2>&1
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
  local release_json latest_ver
  release_json="$(curl -sL --max-time 15 "https://api.github.com/repos/XTLS/Xray-core/releases/latest" || true)"
  latest_ver="$(jq -r '.tag_name // empty' <<< "${release_json}" 2>/dev/null || true)"

  if [[ -z "${latest_ver}" || "${latest_ver}" == "null" ]]; then
    err "获取 Xray 版本失败"
    return 1
  fi

  local zip_name="Xray-linux-${arch}.zip"
  local checksum_name="${zip_name}.dgst"
  local dl_url checksum_url api_digest

  dl_url="$(jq -r --arg name "${zip_name}" '.assets[]? | select(.name == $name) | .browser_download_url' <<< "${release_json}" 2>/dev/null | sed -n '1p')"
  checksum_url="$(jq -r --arg name "${checksum_name}" '.assets[]? | select(.name == $name) | .browser_download_url' <<< "${release_json}" 2>/dev/null | sed -n '1p')"
  api_digest="$(jq -r --arg name "${zip_name}" '.assets[]? | select(.name == $name) | .digest // empty' <<< "${release_json}" 2>/dev/null | sed -n '1p')"

  if [[ -z "${dl_url}" ]]; then
    err "未找到 Xray 安装包: ${zip_name}"
    return 1
  fi

  if [[ -z "${checksum_url}" && -z "$(normalize_sha256 "${api_digest}")" ]]; then
    err "未找到 Xray 校验文件: ${checksum_name}"
    return 1
  fi

  msg "下载 Xray ${latest_ver} (${arch})..."
  local tmp_zip="/tmp/xray_$$.zip"
  local tmp_checksum="/tmp/xray_$$.zip.dgst"
  local tmp_dir="/tmp/xray_$$"

  if ! curl -sL --max-time 120 "${dl_url}" -o "${tmp_zip}"; then
    err "下载 Xray 失败"
    rm -rf "${tmp_zip}" "${tmp_checksum}" "${tmp_dir}"
    return 1
  fi

  if [[ -z "$(normalize_sha256 "${api_digest}")" ]] && ! curl -sL --max-time 30 "${checksum_url}" -o "${tmp_checksum}"; then
    err "下载 Xray 校验文件失败"
    rm -rf "${tmp_zip}" "${tmp_checksum}" "${tmp_dir}"
    return 1
  fi

  local expected_sha actual_sha
  expected_sha="$(normalize_sha256 "${api_digest}")"
  [[ -z "${expected_sha}" ]] && expected_sha="$(extract_sha256_from_file "${tmp_checksum}" "${zip_name}")"
  if [[ -z "${expected_sha}" ]]; then
    [[ -s "${tmp_checksum}" ]] && sed -n '1,5p' "${tmp_checksum}" 2>/dev/null || true
    err "无法从校验文件中提取 ${zip_name} 的 SHA256"
    rm -rf "${tmp_zip}" "${tmp_checksum}" "${tmp_dir}"
    return 1
  fi

  actual_sha="$(sha256_file "${tmp_zip}")" || {
    rm -rf "${tmp_zip}" "${tmp_checksum}" "${tmp_dir}"
    return 1
  }

  if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    err "Xray 安装包校验失败"
    rm -rf "${tmp_zip}" "${tmp_checksum}" "${tmp_dir}"
    return 1
  fi

  mkdir -p "${tmp_dir}"
  unzip -qo "${tmp_zip}" -d "${tmp_dir}"
  cp -f "${tmp_dir}/xray" "${XRAY_BIN}"
  chmod +x "${XRAY_BIN}"

  rm -rf "${tmp_zip}" "${tmp_checksum}" "${tmp_dir}"
  msg "Xray ${latest_ver} 安装完成"
}

# ======================== 配置生成 ========================
write_user_data() {
  local port="$1" user="$2" pass="$3"
  local data_tmp="${DATA_FILE}.tmp.$$"

  if ! jq -n \
    --argjson port "${port}" \
    --arg user "${user}" \
    --arg pass "${pass}" \
    '{port:$port,user:$user,pass:$pass}' > "${data_tmp}"; then
    rm -f "${data_tmp}"
    err "写入用户数据失败"
    return 1
  fi

  mv -f "${data_tmp}" "${DATA_FILE}"
}

generate_config() {
  local port="$1" user="$2" pass="$3"
  local config_tmp="${CONFIG_FILE}.tmp.$$"

  mkdir -p "${INSTALL_DIR}" "${LOG_DIR}"

  if ! jq -n \
    --arg access "${LOG_DIR}/access.log" \
    --arg error_log "${LOG_DIR}/error.log" \
    --argjson port "${port}" \
    --argjson api_port "${XRAY_API_PORT}" \
    --arg user "${user}" \
    --arg pass "${pass}" \
    '{
      log: {
        access: $access,
        error: $error_log,
        loglevel: "warning"
      },
      api: {
        tag: "api",
        services: [
          "StatsService"
        ]
      },
      policy: {
        system: {
          statsInboundUplink: true,
          statsInboundDownlink: true
        }
      },
      stats: {},
      inbounds: [
        {
          tag: "socks-in",
          port: $port,
          listen: "0.0.0.0",
          protocol: "socks",
          settings: {
            auth: "password",
            accounts: [
              {
                user: $user,
                pass: $pass
              }
            ],
            udp: true
          }
        },
        {
          tag: "api",
          port: $api_port,
          listen: "127.0.0.1",
          protocol: "dokodemo-door",
          settings: {
            rewriteAddress: "127.0.0.1"
          }
        }
      ],
      outbounds: [
        {
          tag: "direct",
          protocol: "freedom",
          settings: {}
        },
        {
          tag: "api",
          protocol: "freedom",
          settings: {}
        }
      ],
      routing: {
        rules: [
          {
            type: "field",
            inboundTag: [
              "api"
            ],
            outboundTag: "api"
          }
        ]
      }
    }' > "${config_tmp}"; then
    rm -f "${config_tmp}"
    err "生成配置文件失败"
    return 1
  fi

  mv -f "${config_tmp}" "${CONFIG_FILE}"

  if ! write_user_data "${port}" "${user}" "${pass}"; then
    return 1
  fi

  msg "配置文件已生成: ${CONFIG_FILE}"
}

validate_xray_config() {
  if [[ ! -x "${XRAY_BIN}" ]]; then
    err "未找到 Xray 可执行文件: ${XRAY_BIN}"
    return 1
  fi

  local output=""
  if ! output="$("${XRAY_BIN}" run -test -config "${CONFIG_FILE}" 2>&1)"; then
    err "Xray 配置校验失败"
    [[ -n "${output}" ]] && echo "${output}"
    return 1
  fi

  return 0
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
    ufw --force delete allow "${port}/tcp" 2>/dev/null || true
    ufw --force delete allow "${port}/udp" 2>/dev/null || true
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
load_user_data_from_config() {
  [[ -f "${CONFIG_FILE}" ]] || return 1

  CURRENT_PORT="$(jq -r '
    .inbounds[]?
    | select(.protocol == "socks" and (.tag == "socks-in" or (.settings.accounts | type == "array")))
    | .port // empty
  ' "${CONFIG_FILE}" 2>/dev/null | sed -n '1p' || true)"
  CURRENT_USER="$(jq -r '
    .inbounds[]?
    | select(.protocol == "socks" and (.tag == "socks-in" or (.settings.accounts | type == "array")))
    | .settings.accounts[0].user // empty
  ' "${CONFIG_FILE}" 2>/dev/null | sed -n '1p' || true)"
  CURRENT_PASS="$(jq -r '
    .inbounds[]?
    | select(.protocol == "socks" and (.tag == "socks-in" or (.settings.accounts | type == "array")))
    | .settings.accounts[0].pass // empty
  ' "${CONFIG_FILE}" 2>/dev/null | sed -n '1p' || true)"

  if [[ -z "${CURRENT_PORT}" || -z "${CURRENT_USER}" || -z "${CURRENT_PASS}" ]]; then
    CURRENT_PORT=""
    CURRENT_USER=""
    CURRENT_PASS=""
    return 1
  fi

  if ! [[ "${CURRENT_PORT}" =~ ^[0-9]+$ ]]; then
    CURRENT_PORT=""
    CURRENT_USER=""
    CURRENT_PASS=""
    return 1
  fi

  if write_user_data "${CURRENT_PORT}" "${CURRENT_USER}" "${CURRENT_PASS}" 2>/dev/null; then
    msg "已从 ${CONFIG_FILE} 恢复用户数据记录"
  else
    warn "已从配置文件读取连接信息，但无法重建用户数据文件"
  fi

  return 0
}

load_user_data() {
  CURRENT_PORT=""
  CURRENT_USER=""
  CURRENT_PASS=""

  if [[ ! -f "${DATA_FILE}" ]]; then
    load_user_data_from_config
    return $?
  fi

  CURRENT_PORT="$(jq -r '.port // empty' "${DATA_FILE}" 2>/dev/null || true)"
  CURRENT_USER="$(jq -r '.user // empty' "${DATA_FILE}" 2>/dev/null || true)"
  CURRENT_PASS="$(jq -r '.pass // empty' "${DATA_FILE}" 2>/dev/null || true)"

  if [[ -z "${CURRENT_PORT}" || -z "${CURRENT_USER}" || -z "${CURRENT_PASS}" ]]; then
    warn "用户数据文件损坏或缺少必要字段: ${DATA_FILE}"
    CURRENT_PORT=""
    CURRENT_USER=""
    CURRENT_PASS=""
    load_user_data_from_config
    return $?
  fi

  return 0
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

  if ! validate_port "${port}" \
    || ! validate_credential "用户名" "${user}" \
    || ! validate_credential "密码" "${pass}"; then
    press_any_key
    return
  fi

  if ! generate_config "${port}" "${user}" "${pass}"; then
    press_any_key
    return
  fi

  if ! validate_xray_config; then
    press_any_key
    return
  fi

  create_service

  if ! systemctl restart "${SERVICE_NAME}"; then
    err "服务启动失败，请查看日志: journalctl -u ${SERVICE_NAME}"
    press_any_key
    return
  fi

  sleep 1

  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    open_firewall "${port}"
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

# ---- 流量统计 ----
config_has_traffic_stats() {
  [[ -f "${CONFIG_FILE}" ]] || return 1

  jq -e --argjson api_port "${XRAY_API_PORT}" '
    (.stats? | type == "object")
    and (.api?.tag == "api")
    and (any(.api?.services[]?; . == "StatsService"))
    and (any(.inbounds[]?; .tag == "api" and .listen == "127.0.0.1" and .port == $api_port))
    and (any(.routing?.rules[]?; .outboundTag == "api"))
    and (.policy?.system?.statsInboundUplink == true)
    and (.policy?.system?.statsInboundDownlink == true)
  ' "${CONFIG_FILE}" >/dev/null 2>&1
}

enable_traffic_stats_for_existing_config() {
  if config_has_traffic_stats; then
    return 0
  fi

  warn "当前配置未启用流量统计，需要更新配置并重启服务。"
  if ! load_user_data; then
    warn "无法读取现有端口、用户名和密码，请先重新安装或修改配置。"
    return 1
  fi

  read -rp "是否立即启用流量统计？[y/N]: " yn
  [[ "${yn,,}" == "y" ]] || return 1

  local config_backup=""
  local data_backup=""
  if [[ -f "${CONFIG_FILE}" ]]; then
    config_backup="${CONFIG_FILE}.bak.$$"
    cp -f "${CONFIG_FILE}" "${config_backup}"
  fi
  if [[ -f "${DATA_FILE}" ]]; then
    data_backup="${DATA_FILE}.bak.$$"
    cp -f "${DATA_FILE}" "${data_backup}"
  fi

  if ! generate_config "${CURRENT_PORT}" "${CURRENT_USER}" "${CURRENT_PASS}"; then
    restore_file_or_remove "${config_backup}" "${CONFIG_FILE}"
    restore_file_or_remove "${data_backup}" "${DATA_FILE}"
    return 1
  fi

  if ! validate_xray_config; then
    restore_file_or_remove "${config_backup}" "${CONFIG_FILE}"
    restore_file_or_remove "${data_backup}" "${DATA_FILE}"
    return 1
  fi

  if systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    if ! systemctl restart "${SERVICE_NAME}" 2>/dev/null; then
      restore_file_or_remove "${config_backup}" "${CONFIG_FILE}"
      restore_file_or_remove "${data_backup}" "${DATA_FILE}"
      systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
      err "启用流量统计失败，已恢复原配置。"
      return 1
    fi

    sleep 1
    if ! systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
      restore_file_or_remove "${config_backup}" "${CONFIG_FILE}"
      restore_file_or_remove "${data_backup}" "${DATA_FILE}"
      systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
      err "启用流量统计后服务未能正常运行，已恢复原配置。"
      return 1
    fi
  fi

  rm -f "${config_backup}" "${data_backup}"
  msg "流量统计已启用"
  return 0
}

query_traffic_stats() {
  "${XRAY_BIN}" api statsquery \
    --server="127.0.0.1:${XRAY_API_PORT}" 2>/dev/null
}

stat_value_from_output() {
  local output="$1" stat_name="$2"
  local value=""

  if command -v jq &>/dev/null; then
    value="$(jq -r --arg name "${stat_name}" '.stat[]? | select(.name == $name) | .value // empty' <<< "${output}" 2>/dev/null | sed -n '1p' || true)"
    if [[ "${value}" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "${value}"
      return 0
    fi
  fi

  awk -v target="${stat_name}" '
    function print_value(line, value) {
      value = line
      if (sub(/^.*"?value"?[[:space:]]*:[[:space:]]*"?/, "", value)) {
        sub(/[^0-9].*$/, "", value)
        if (value != "") {
          print value + 0
          exit
        }
      }
    }

    index($0, "name: \"" target "\"") || (index($0, target) && $0 ~ /"?name"?[[:space:]]*:/) {
      found = 1
      print_value($0)
      next
    }

    found {
      print_value($0)
    }
  ' <<< "${output}"
}

show_traffic_stats() {
  echo ""

  if [[ ! -x "${XRAY_BIN}" || ! -f "${CONFIG_FILE}" ]]; then
    warn "未找到 Xray 配置，请先安装 SOCKS5 代理。"
    press_any_key
    return
  fi

  if ! enable_traffic_stats_for_existing_config; then
    press_any_key
    return
  fi

  if ! systemctl is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    warn "服务未运行，启动服务后才能读取流量统计。"
    press_any_key
    return
  fi

  local output=""
  if ! output="$(query_traffic_stats)"; then
    err "读取流量统计失败，请确认 Xray Stats API 正常运行。"
    press_any_key
    return
  fi

  local uplink downlink total uptime_seconds uptime_text
  uplink="$(stat_value_from_output "${output}" "inbound>>>socks-in>>>traffic>>>uplink")"
  downlink="$(stat_value_from_output "${output}" "inbound>>>socks-in>>>traffic>>>downlink")"
  uplink="${uplink:-0}"
  downlink="${downlink:-0}"
  total=$(( uplink + downlink ))
  uptime_seconds="$(get_service_uptime_seconds || true)"
  if [[ -n "${uptime_seconds}" ]]; then
    uptime_text="$(format_duration "${uptime_seconds}")"
  else
    uptime_text="未知"
  fi

  echo -e "${CYAN}${BOLD}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║              SOCKS5 流量统计                 ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo "  统计范围: 当前服务运行期间"
  echo "  已运行时间: ${uptime_text}"
  echo ""
  echo "  上行流量: $(format_bytes "${uplink}") (${uplink} B)"
  echo "  下行流量: $(format_bytes "${downlink}") (${downlink} B)"
  echo "  总计流量: $(format_bytes "${total}") (${total} B)"

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

  if ! validate_port "${port}" \
    || ! validate_credential "用户名" "${user}" \
    || ! validate_credential "密码" "${pass}"; then
    press_any_key
    return
  fi

  local config_backup=""
  local data_backup=""
  if [[ -f "${CONFIG_FILE}" ]]; then
    config_backup="${CONFIG_FILE}.bak.$$"
    cp -f "${CONFIG_FILE}" "${config_backup}"
  fi
  if [[ -f "${DATA_FILE}" ]]; then
    data_backup="${DATA_FILE}.bak.$$"
    cp -f "${DATA_FILE}" "${data_backup}"
  fi

  if ! generate_config "${port}" "${user}" "${pass}"; then
    restore_file_or_remove "${config_backup}" "${CONFIG_FILE}"
    restore_file_or_remove "${data_backup}" "${DATA_FILE}"
    press_any_key
    return
  fi

  if ! validate_xray_config; then
    restore_file_or_remove "${config_backup}" "${CONFIG_FILE}"
    restore_file_or_remove "${data_backup}" "${DATA_FILE}"
    press_any_key
    return
  fi

  if ! systemctl restart "${SERVICE_NAME}" 2>/dev/null; then
    restore_file_or_remove "${config_backup}" "${CONFIG_FILE}"
    restore_file_or_remove "${data_backup}" "${DATA_FILE}"
    systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
    err "重启失败，已恢复旧配置"
    press_any_key
    return
  fi

  sleep 1
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    if [[ "${port}" != "${CURRENT_PORT}" ]]; then
      open_firewall "${port}"
      close_firewall "${CURRENT_PORT}"
    fi
    rm -f "${config_backup}" "${data_backup}"
    msg "✅ 配置已更新并重启成功"
    echo ""
    show_connection_info "${port}" "${user}" "${pass}"
  else
    restore_file_or_remove "${config_backup}" "${CONFIG_FILE}"
    restore_file_or_remove "${data_backup}" "${DATA_FILE}"
    systemctl restart "${SERVICE_NAME}" 2>/dev/null || true
    err "重启失败，已恢复旧配置"
  fi

  press_any_key
}

# ---- 更新脚本 ----
update_script() {
  echo ""
  msg "正在检查更新..."
  local tmp="/tmp/socks_update_$$.sh"

  if curl -sL --max-time 15 "${SCRIPT_URL}?t=$(date +%s)" -o "${tmp}" 2>/dev/null; then
    if validate_script_file "${tmp}"; then
      cp -f "${tmp}" "${SCRIPT_PATH}"
      chmod +x "${SCRIPT_PATH}"
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
  echo "  7) 查看流量统计"
  echo ""
  echo -e "  ${BOLD}── 配置维护 ──────────────────────────${NC}"
  echo "  8) 修改配置 (端口/用户名/密码)"
  echo "  9) 更新脚本"
  echo "  10) 完整卸载"
  echo ""
  echo "  0) 退出"
  echo ""
  read -rp "  请选择 [0-10]: " choice

  case "${choice}" in
    1) install_proxy   ;;
    2) start_service   ;;
    3) stop_service    ;;
    4) restart_service ;;
    5) show_status     ;;
    6) show_info       ;;
    7) show_traffic_stats ;;
    8) modify_config   ;;
    9) update_script   ;;
    10) full_uninstall ;;
    0) echo ""; msg "再见！"; exit 0 ;;
    *) warn "无效选项，已退出管理面板"; exit 1 ;;
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
