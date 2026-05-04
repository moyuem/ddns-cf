#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="${DDNS_CF_CONFIG:-$HOME/.ddns_cf.conf}"
LOG_FILE="${DDNS_CF_LOG:-$HOME/ddns_cf.log}"
ORIGINAL_ARGC=$#
FORCE=false
SETUP=false
RUN_ONLY=false
MENU=false
DID_SETUP=false

usage() {
    cat <<EOF
用法: $0 [选项]

选项:
  --setup    进入交互式配置，并自动安装或更新定时任务
  --run      只运行 DDNS 更新，不进入交互式配置
  --menu     打开菜单页
  --force    即使公网 IP 没有变化也强制更新 DNS
  -h,--help  显示帮助

首次运行会自动进入交互式配置，不需要使用 vim/nano 编辑配置文件。
配置完成后会尝试安装 ddns 快捷命令，以后输入 ddns 即可打开菜单页。
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --setup)
            SETUP=true
            ;;
        --run)
            RUN_ONLY=true
            ;;
        --menu)
            MENU=true
            ;;
        --force)
            FORCE=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "未知参数: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

if [ "$ORIGINAL_ARGC" -eq 0 ] && [ "$(basename "$0")" = "ddns" ]; then
    MENU=true
fi

script_path() {
    local source_path dir base
    source_path="${BASH_SOURCE[0]}"

    if command -v realpath >/dev/null 2>&1; then
        realpath "$source_path"
        return
    fi

    dir=$(cd "$(dirname "$source_path")" && pwd)
    base=$(basename "$source_path")
    printf '%s/%s\n' "$dir" "$base"
}

prompt_required() {
    local var_name prompt_text current_value input
    var_name="$1"
    prompt_text="$2"
    current_value="${3:-}"

    while true; do
        if [ -n "$current_value" ]; then
            read -r -p "$prompt_text [$current_value]: " input
            input="${input:-$current_value}"
        else
            read -r -p "$prompt_text: " input
        fi

        if [ -n "$input" ]; then
            printf -v "$var_name" '%s' "$input"
            return
        fi

        echo "该项不能为空。"
    done
}

prompt_secret() {
    local var_name prompt_text current_value input
    var_name="$1"
    prompt_text="$2"
    current_value="${3:-}"

    while true; do
        if [ -n "$current_value" ]; then
            read -r -s -p "$prompt_text [已保存，回车保持不变]: " input
            echo
            input="${input:-$current_value}"
        else
            read -r -s -p "$prompt_text: " input
            echo
        fi

        if [ -n "$input" ]; then
            printf -v "$var_name" '%s' "$input"
            return
        fi

        echo "该项不能为空。"
    done
}

prompt_yes_no() {
    local var_name prompt_text default_value input suffix
    var_name="$1"
    prompt_text="$2"
    default_value="$3"

    if [ "$default_value" = true ]; then
        suffix="Y/n"
    else
        suffix="y/N"
    fi

    while true; do
        read -r -p "$prompt_text [$suffix]: " input
        input="${input:-$default_value}"
        case "${input,,}" in
            y|yes|true|1)
                printf -v "$var_name" '%s' true
                return
                ;;
            n|no|false|0)
                printf -v "$var_name" '%s' false
                return
                ;;
            *)
                echo "请输入 y 或 n。"
                ;;
        esac
    done
}

prompt_record_type() {
    local current_value input
    current_value="${1:-A}"

    while true; do
        read -r -p "DNS 记录类型 A/AAAA [$current_value]: " input
        input="${input:-$current_value}"
        input="${input^^}"
        case "$input" in
            A|AAAA)
                CFRECORD_TYPE="$input"
                return
                ;;
            *)
                echo "请输入 A 或 AAAA。"
                ;;
        esac
    done
}

prompt_number() {
    local var_name prompt_text default_value min_value max_value input
    var_name="$1"
    prompt_text="$2"
    default_value="$3"
    min_value="$4"
    max_value="$5"

    while true; do
        read -r -p "$prompt_text [$default_value]: " input
        input="${input:-$default_value}"
        if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge "$min_value" ] && [ "$input" -le "$max_value" ]; then
            printf -v "$var_name" '%s' "$input"
            return
        fi
        echo "请输入 $min_value 到 $max_value 之间的整数。"
    done
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi
}

save_config() {
    umask 077
    {
        printf 'CFKEY=%q\n' "$CFKEY"
        printf 'CFUSER=%q\n' "$CFUSER"
        printf 'CFZONE_NAME=%q\n' "$CFZONE_NAME"
        printf 'CFRECORD_NAME=%q\n' "$CFRECORD_NAME"
        printf 'CFRECORD_TYPE=%q\n' "$CFRECORD_TYPE"
        printf 'CFTTL=%q\n' "$CFTTL"
        printf 'TG_ENABLED=%q\n' "$TG_ENABLED"
        printf 'TG_BOT_TOKEN=%q\n' "${TG_BOT_TOKEN:-}"
        printf 'TG_CHAT_ID=%q\n' "${TG_CHAT_ID:-}"
        printf 'SCHEDULE_ENABLED=%q\n' "$SCHEDULE_ENABLED"
        printf 'SCHEDULE_MINUTES=%q\n' "$SCHEDULE_MINUTES"
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo "配置已保存到 $CONFIG_FILE"
}

cron_command() {
    local script
    script=$(script_path)
    printf 'bash %q --run >> %q 2>&1' "$script" "$LOG_FILE"
}

install_cron() {
    if ! command -v crontab >/dev/null 2>&1; then
        echo "未找到 crontab 命令，无法自动安装定时任务。请先安装 cron/cronie。"
        return 1
    fi

    local minutes cron_expr command marker tmp current_cron
    minutes="$1"
    marker="# ddns_cf.sh auto schedule"
    command=$(cron_command)

    if [ "$minutes" -eq 1 ]; then
        cron_expr="* * * * *"
    else
        cron_expr="*/$minutes * * * *"
    fi

    tmp=$(mktemp)
    current_cron=$(crontab -l 2>/dev/null || true)
    printf '%s\n' "$current_cron" | awk -v marker="$marker" \
        'index($0, marker) == 0 && $0 !~ /^[[:space:]]*$/ { print }' > "$tmp"
    printf '%s %s %s\n' "$cron_expr" "$command" "$marker" >> "$tmp"
    crontab "$tmp"
    rm -f "$tmp"

    echo "定时任务已自动安装: 每 $minutes 分钟运行一次。"
    echo "日志文件: $LOG_FILE"
}

remove_cron() {
    if ! command -v crontab >/dev/null 2>&1; then
        return 0
    fi

    local marker tmp current_cron
    marker="# ddns_cf.sh auto schedule"
    tmp=$(mktemp)
    current_cron=$(crontab -l 2>/dev/null || true)
    printf '%s\n' "$current_cron" | awk -v marker="$marker" \
        'index($0, marker) == 0 && $0 !~ /^[[:space:]]*$/ { print }' > "$tmp"
    crontab "$tmp"
    rm -f "$tmp"
    echo "已移除本脚本自动安装的定时任务。"
}

install_ddns_command() {
    local script install_dir target owner_id replace_existing
    script=$(script_path)
    owner_id="${EUID:-$(id -u)}"

    if [ "$owner_id" -eq 0 ]; then
        install_dir="/usr/local/bin"
    else
        install_dir="$HOME/.local/bin"
    fi
    target="$install_dir/ddns"

    if [ -e "$target" ] && [ "$(readlink "$target" 2>/dev/null || true)" != "$script" ]; then
        prompt_yes_no replace_existing "$target 已存在，是否覆盖为本脚本的 ddns 菜单入口" false
        if [ "$replace_existing" != true ]; then
            echo "已跳过 ddns 快捷命令安装。"
            return 0
        fi
    fi

    mkdir -p "$install_dir"
    chmod +x "$script" 2>/dev/null || true

    if ln -sf "$script" "$target"; then
        echo "ddns 快捷命令已安装: $target"
        if [[ ":$PATH:" != *":$install_dir:"* ]]; then
            echo "提示: $install_dir 不在当前 PATH 中，重新登录后若仍无法输入 ddns，请把它加入 PATH。"
        fi
    else
        echo "ddns 快捷命令安装失败，请检查 $install_dir 是否可写。"
    fi
}

show_config_summary() {
    load_config

    echo ""
    echo "当前配置"
    echo "----------------------------------------"
    echo "配置文件: $CONFIG_FILE"
    echo "日志文件: $LOG_FILE"
    echo "Cloudflare 邮箱: ${CFUSER:-未配置}"
    echo "根域名: ${CFZONE_NAME:-未配置}"
    echo "记录名: ${CFRECORD_NAME:-未配置}"
    echo "记录类型: ${CFRECORD_TYPE:-未配置}"
    echo "TTL: ${CFTTL:-未配置}"
    echo "Telegram 通知: ${TG_ENABLED:-false}"
    if [ "${TG_ENABLED:-false}" = true ]; then
        echo "Telegram Bot Token: 已隐藏"
        echo "Telegram Chat ID: ${TG_CHAT_ID:-未配置}"
    fi
    echo "自动定时: ${SCHEDULE_ENABLED:-false}"
    if [ "${SCHEDULE_ENABLED:-false}" = true ]; then
        echo "定时间隔: ${SCHEDULE_MINUTES:-2} 分钟"
    fi
    echo "----------------------------------------"
}

show_cron_summary() {
    if ! command -v crontab >/dev/null 2>&1; then
        echo "未找到 crontab 命令。"
        return 0
    fi

    local marker current_cron matched
    marker="# ddns_cf.sh auto schedule"
    current_cron=$(crontab -l 2>/dev/null || true)
    matched=$(printf '%s\n' "$current_cron" | awk -v marker="$marker" 'index($0, marker) > 0 { print }')

    if [ -n "$matched" ]; then
        echo "当前自动定时任务:"
        printf '%s\n' "$matched"
    else
        echo "当前未安装本脚本的自动定时任务。"
    fi
}

show_recent_log() {
    if [ ! -f "$LOG_FILE" ]; then
        echo "日志文件不存在: $LOG_FILE"
        return 0
    fi

    echo "最近 50 行日志:"
    echo "----------------------------------------"
    tail -n 50 "$LOG_FILE"
    echo "----------------------------------------"
}

pause_menu() {
    local _
    echo ""
    read -r -p "按回车返回菜单..." _
}

show_menu() {
    if [ ! -t 0 ]; then
        echo "当前环境不是交互式终端，菜单无法显示。"
        exit 1
    fi

    while true; do
        if command -v clear >/dev/null 2>&1; then
            clear
        fi

        cat <<EOF
Cloudflare DDNS 菜单
========================================
1) 立即运行 DDNS 更新
2) 强制更新 DNS
3) 交互式配置 / 修改 Telegram / 修改定时
4) 查看当前配置
5) 查看定时任务
6) 移除定时任务
7) 查看最近日志
8) 发送当前 DDNS 信息到 Telegram
9) 安装或修复 ddns 快捷命令
0) 退出
========================================
EOF

        local choice
        read -r -p "请选择: " choice
        echo ""

        case "$choice" in
            1)
                require_config
                FORCE=false
                update_dns
                pause_menu
                ;;
            2)
                require_config
                FORCE=true
                update_dns
                FORCE=false
                pause_menu
                ;;
            3)
                interactive_setup
                pause_menu
                ;;
            4)
                show_config_summary
                pause_menu
                ;;
            5)
                show_cron_summary
                pause_menu
                ;;
            6)
                remove_cron
                pause_menu
                ;;
            7)
                show_recent_log
                pause_menu
                ;;
            8)
                send_current_ddns_info
                pause_menu
                ;;
            9)
                install_ddns_command
                pause_menu
                ;;
            0)
                exit 0
                ;;
            *)
                echo "无效选项，请重新选择。"
                pause_menu
                ;;
        esac
    done
}

interactive_setup() {
    load_config
    DID_SETUP=true

    echo "开始交互式配置 Cloudflare DDNS。"
    echo "直接回车会沿用方括号中的已保存值。"
    prompt_secret CFKEY "Cloudflare Global API Key" "${CFKEY:-}"
    prompt_required CFUSER "Cloudflare 账号邮箱" "${CFUSER:-}"
    prompt_required CFZONE_NAME "根域名，例如 example.com" "${CFZONE_NAME:-}"
    prompt_required CFRECORD_NAME "解析记录名，例如 home 或 home.example.com" "${CFRECORD_NAME:-}"
    prompt_record_type "${CFRECORD_TYPE:-A}"
    prompt_number CFTTL "TTL 秒数" "${CFTTL:-120}" 60 86400

    prompt_yes_no TG_ENABLED "是否开启 Telegram 通知" "${TG_ENABLED:-false}"
    if [ "$TG_ENABLED" = true ]; then
        prompt_secret TG_BOT_TOKEN "Telegram Bot Token" "${TG_BOT_TOKEN:-}"
        prompt_required TG_CHAT_ID "Telegram Chat ID" "${TG_CHAT_ID:-}"
    else
        TG_BOT_TOKEN=""
        TG_CHAT_ID=""
    fi

    prompt_yes_no SCHEDULE_ENABLED "是否自动设置定时重新运行本脚本" "${SCHEDULE_ENABLED:-true}"
    if [ "$SCHEDULE_ENABLED" = true ]; then
        prompt_number SCHEDULE_MINUTES "定时运行间隔，单位分钟" "${SCHEDULE_MINUTES:-2}" 1 59
    else
        SCHEDULE_MINUTES="2"
    fi

    save_config

    if [ "$SCHEDULE_ENABLED" = true ]; then
        if ! install_cron "$SCHEDULE_MINUTES"; then
            echo "定时任务未安装，本次 DDNS 更新仍会继续。"
        fi
    else
        remove_cron
    fi

    if [ "$TG_ENABLED" = true ]; then
        send_telegram_test
    fi

    install_ddns_command
}

require_config() {
    load_config
    local missing=false name

    for name in CFKEY CFUSER CFZONE_NAME CFRECORD_NAME CFRECORD_TYPE CFTTL; do
        if [ -z "${!name:-}" ]; then
            echo "缺少配置项: $name"
            missing=true
        fi
    done

    if [ "$missing" = true ]; then
        if [ "$RUN_ONLY" = true ] || [ ! -t 0 ]; then
            echo "请先运行: $0 --setup"
            exit 1
        fi
        interactive_setup
        load_config
    fi
}

telegram_ready() {
    [ "${TG_ENABLED:-false}" = true ] && [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]
}

html_escape() {
    local value
    value="${1:-}"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    printf '%s' "$value"
}

tg_timestamp() {
    date '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf 'unknown'
}

send_telegram_message() {
    local message
    message="$1"

    if ! telegram_ready; then
        echo "Telegram 通知未开启或配置不完整。"
        return 1
    fi

    curl -fsS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="$TG_CHAT_ID" \
        --data-urlencode "text=$message" \
        -d parse_mode="HTML" >/dev/null
}

send_telegram_test() {
    local message record record_type zone ttl when
    record=$(html_escape "${CFRECORD_NAME:-未配置}")
    record_type=$(html_escape "${CFRECORD_TYPE:-未配置}")
    zone=$(html_escape "${CFZONE_NAME:-未配置}")
    ttl=$(html_escape "${CFTTL:-未配置}")
    when=$(html_escape "$(tg_timestamp)")

    message=$(cat <<EOF
✅ <b>DDNS 通知测试成功</b>

🌐 <b>域名:</b> <code>$zone</code>
📌 <b>记录:</b> <code>$record</code>
🧩 <b>类型:</b> <code>$record_type</code>
⏱ <b>TTL:</b> <code>$ttl</code>
🕒 <b>发送时间:</b> <code>$when</code>
EOF
)

    if send_telegram_message "$message"; then
        echo "Telegram 测试消息已发送。"
    else
        echo "Telegram 测试消息发送失败，请检查 Bot Token 和 Chat ID。"
    fi
}

send_telegram() {
    if ! telegram_ready; then
        return 0
    fi

    local display_old_ip message record record_type ttl old_ip new_ip when
    display_old_ip=${OLD_WAN_IP:-"无"}
    record=$(html_escape "$CFRECORD_NAME")
    record_type=$(html_escape "$CFRECORD_TYPE")
    ttl=$(html_escape "$CFTTL")
    old_ip=$(html_escape "$display_old_ip")
    new_ip=$(html_escape "$WAN_IP")
    when=$(html_escape "$(tg_timestamp)")

    message=$(cat <<EOF
✅ <b>DDNS 更新成功</b>

🌐 <b>域名:</b> <code>$record</code>
🔴 <b>旧 IP:</b> <code>$old_ip</code>
🟢 <b>新 IP:</b> <code>$new_ip</code>
🧩 <b>类型:</b> <code>$record_type</code>
⏱ <b>TTL:</b> <code>${ttl}s</code>
🕒 <b>发送时间:</b> <code>$when</code>
EOF
)

    if send_telegram_message "$message"; then
        echo "Telegram 通知已发送。"
    else
        echo "Telegram 通知发送失败，DDNS 更新结果不受影响。"
    fi
}

normalize_record_name() {
    if [[ "$CFRECORD_NAME" != *".$CFZONE_NAME" ]]; then
        CFRECORD_NAME="$CFRECORD_NAME.$CFZONE_NAME"
        echo "解析记录已补全为 FQDN: $CFRECORD_NAME"
    fi
}

get_wan_ip() {
    local wan_ip_site
    wan_ip_site="https://ipv4.icanhazip.com"
    if [ "$CFRECORD_TYPE" = "AAAA" ]; then
        wan_ip_site="https://ipv6.icanhazip.com"
    fi

    curl -fsS "$wan_ip_site" | tr -d '[:space:]'
}

send_current_ddns_info() {
    require_config

    if ! telegram_ready; then
        echo "Telegram 通知未开启或配置不完整，请先在菜单中进入交互式配置。"
        return 0
    fi

    normalize_record_name

    local current_ip wan_ip_file cached_ip schedule_text message record record_type ttl current_ip_html cached_ip_html schedule_text_html when
    if ! current_ip=$(get_wan_ip); then
        echo "获取当前公网 IP 失败，未发送 Telegram 信息。"
        return 1
    fi

    wan_ip_file="$HOME/.cf-wan_ip_$CFRECORD_NAME.txt"
    cached_ip="无"
    if [ -f "$wan_ip_file" ]; then
        cached_ip=$(cat "$wan_ip_file")
    fi

    if [ "${SCHEDULE_ENABLED:-false}" = true ]; then
        schedule_text="开启，每 ${SCHEDULE_MINUTES:-2} 分钟"
    else
        schedule_text="关闭"
    fi

    record=$(html_escape "$CFRECORD_NAME")
    record_type=$(html_escape "$CFRECORD_TYPE")
    ttl=$(html_escape "$CFTTL")
    current_ip_html=$(html_escape "$current_ip")
    cached_ip_html=$(html_escape "$cached_ip")
    schedule_text_html=$(html_escape "$schedule_text")
    when=$(html_escape "$(tg_timestamp)")

    message=$(cat <<EOF
ℹ️ <b>DDNS 当前信息</b>

🌐 <b>域名:</b> <code>$record</code>
🔵 <b>当前 IP:</b> <code>$current_ip_html</code>
🟢 <b>上次 IP:</b> <code>$cached_ip_html</code>
🧩 <b>类型:</b> <code>$record_type</code>
⏱ <b>TTL:</b> <code>${ttl}s</code>
🔁 <b>自动定时:</b> <code>$schedule_text_html</code>
🕒 <b>发送时间:</b> <code>$when</code>
EOF
)

    if send_telegram_message "$message"; then
        echo "当前 DDNS 信息已发送到 Telegram。"
    else
        echo "当前 DDNS 信息发送失败，请检查 Telegram 配置。"
    fi
}

update_dns() {
    normalize_record_name

    WAN_IP=$(get_wan_ip)
    if [ -z "$WAN_IP" ]; then
        echo "获取公网 IP 失败。"
        exit 1
    fi

    WAN_IP_FILE="$HOME/.cf-wan_ip_$CFRECORD_NAME.txt"
    OLD_WAN_IP=""
    if [ -f "$WAN_IP_FILE" ]; then
        OLD_WAN_IP=$(cat "$WAN_IP_FILE")
    fi

    if [ "$WAN_IP" = "$OLD_WAN_IP" ] && [ "$FORCE" = false ]; then
        echo "公网 IP 未变化，无需更新: $WAN_IP"
        return 0
    fi

    echo "检测到公网 IP 变化: ${OLD_WAN_IP:-无} -> $WAN_IP"

    local id_file zone_response record_response response
    id_file="$HOME/.cf-id_$CFRECORD_NAME.txt"

    if [ -f "$id_file" ] && [ "$(wc -l < "$id_file")" -eq 4 ] \
        && [ "$(sed -n '3p' "$id_file")" = "$CFZONE_NAME" ] \
        && [ "$(sed -n '4p' "$id_file")" = "$CFRECORD_NAME" ]; then
        CFZONE_ID=$(sed -n '1p' "$id_file")
        CFRECORD_ID=$(sed -n '2p' "$id_file")
    else
        echo "正在获取 Cloudflare Zone ID 和 Record ID ..."
        zone_response=$(curl -fsS -X GET "https://api.cloudflare.com/client/v4/zones?name=$CFZONE_NAME" \
            -H "X-Auth-Email: $CFUSER" \
            -H "X-Auth-Key: $CFKEY" \
            -H "Content-Type: application/json")
        CFZONE_ID=$(printf '%s' "$zone_response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

        if [ -z "$CFZONE_ID" ]; then
            echo "获取 Zone ID 失败，请检查 Cloudflare 账号邮箱、API Key 和域名。"
            echo "$zone_response"
            exit 1
        fi

        record_response=$(curl -fsS -X GET "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records?type=$CFRECORD_TYPE&name=$CFRECORD_NAME" \
            -H "X-Auth-Email: $CFUSER" \
            -H "X-Auth-Key: $CFKEY" \
            -H "Content-Type: application/json")
        CFRECORD_ID=$(printf '%s' "$record_response" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)

        if [ -z "$CFRECORD_ID" ]; then
            echo "获取 Record ID 失败，请确认 DNS 记录已存在，且记录名和类型正确。"
            echo "$record_response"
            exit 1
        fi

        {
            echo "$CFZONE_ID"
            echo "$CFRECORD_ID"
            echo "$CFZONE_NAME"
            echo "$CFRECORD_NAME"
        } > "$id_file"
    fi

    echo "正在更新 DNS 到 $WAN_IP ..."
    response=$(curl -fsS -X PUT "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records/$CFRECORD_ID" \
        -H "X-Auth-Email: $CFUSER" \
        -H "X-Auth-Key: $CFKEY" \
        -H "Content-Type: application/json" \
        --data "{\"type\":\"$CFRECORD_TYPE\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$WAN_IP\",\"ttl\":$CFTTL}")

    if printf '%s' "$response" | grep -q '"success":true'; then
        echo "DNS 更新成功。"
        echo "$WAN_IP" > "$WAN_IP_FILE"
        send_telegram
    else
        echo "DNS 更新失败，Cloudflare 返回:"
        echo "$response"
        exit 1
    fi
}

maybe_offer_setup() {
    if [ "$DID_SETUP" = true ] || [ "$RUN_ONLY" = true ] || [ ! -t 0 ]; then
        return 0
    fi

    local RECONFIGURE
    prompt_yes_no RECONFIGURE "是否重新进入交互式配置或修改定时任务" false
    if [ "$RECONFIGURE" = true ]; then
        interactive_setup
    fi
}

if [ "$MENU" = true ]; then
    show_menu
    exit 0
fi

if [ "$SETUP" = true ] || [ ! -f "$CONFIG_FILE" ]; then
    if [ ! -t 0 ]; then
        echo "当前环境不是交互式终端，请在终端中运行: $0 --setup"
        exit 1
    fi
    interactive_setup
fi

require_config
update_dns
maybe_offer_setup
