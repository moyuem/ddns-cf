#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# ==============================================================  
# 🔔 Telegram 通知配置（请填写自己的信息）  
# ==============================================================  
TG_BOT_TOKEN="YOUR_TELEGRAM_BOT_TOKEN"  # 填写你的 Bot Token  
TG_CHAT_ID="YOUR_TELEGRAM_CHAT_ID"      # 填写你的 Chat ID  
# ==============================================================  

# ======================= Cloudflare 配置 =======================  
CFKEY="YOUR_CLOUDFLARE_GLOBAL_API_KEY"  # Global API Key  
CFUSER="YOUR_CLOUDFLARE_EMAIL"          # 登录邮箱  
CFZONE_NAME="example.com"                # 根域名  
CFRECORD_NAME="home"                     # 二级域名，不带主域  
CFRECORD_TYPE="A"                        # A 或 AAAA  
CFTTL=120                                # TTL  
FORCE=false                              # 是否强制更新  
# ==============================================================  

# WAN IP 来源
WANIPSITE="http://ipv4.icanhazip.com"
if [ "$CFRECORD_TYPE" = "AAAA" ]; then
    WANIPSITE="http://ipv6.icanhazip.com"
fi

# 补全 FQDN
if [[ "$CFRECORD_NAME" != *".$CFZONE_NAME" ]]; then
    CFRECORD_NAME="$CFRECORD_NAME.$CFZONE_NAME"
    echo " => Hostname is not a FQDN, assuming $CFRECORD_NAME"
fi

# 获取当前 WAN IP
WAN_IP=$(curl -s "$WANIPSITE" | tr -d '[:space:]')
if [ -z "$WAN_IP" ]; then
    echo "❌ 无法获取 WAN IP"
    exit 1
fi

# 读取旧 IP
WAN_IP_FILE="$HOME/.cf-wan_ip_$CFRECORD_NAME.txt"
OLD_WAN_IP=""
if [ -f "$WAN_IP_FILE" ]; then
    OLD_WAN_IP=$(cat "$WAN_IP_FILE")
fi

# IP 未变化且未强制更新
if [ "$WAN_IP" = "$OLD_WAN_IP" ] && [ "$FORCE" = false ]; then
    echo "WAN IP 未变化，无需更新。"
    exit 0
fi

echo "检测到 IP 变更: ${OLD_WAN_IP:-未知} → $WAN_IP"

# ======================= 获取 Zone ID =======================  
ID_FILE="$HOME/.cf-id_$CFRECORD_NAME.txt"
if [ -f "$ID_FILE" ] && [ $(wc -l < "$ID_FILE") -eq 4 ] \
    && [ "$(sed -n '3p' "$ID_FILE")" = "$CFZONE_NAME" ] \
    && [ "$(sed -n '4p' "$ID_FILE")" = "$CFRECORD_NAME" ]; then
    CFZONE_ID=$(sed -n '1p' "$ID_FILE")
    CFRECORD_ID=$(sed -n '2p' "$ID_FILE")
else
    echo "获取 Zone ID 和 Record ID ..."
    CFZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CFZONE_NAME" \
        -H "X-Auth-Email: $CFUSER" \
        -H "X-Auth-Key: $CFKEY" \
        -H "Content-Type: application/json" \
        | grep -Po '(?<="id":")[^"]*' | head -1)
    CFRECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records?name=$CFRECORD_NAME" \
        -H "X-Auth-Email: $CFUSER" \
        -H "X-Auth-Key: $CFKEY" \
        -H "Content-Type: application/json" \
        | grep -Po '(?<="id":")[^"]*' | head -1)
    echo "$CFZONE_ID" > "$ID_FILE"
    echo "$CFRECORD_ID" >> "$ID_FILE"
    echo "$CFZONE_NAME" >> "$ID_FILE"
    echo "$CFRECORD_NAME" >> "$ID_FILE"
fi

# ======================= 更新 DNS =======================  
echo "正在更新 DNS 到 $WAN_IP ..."
RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records/$CFRECORD_ID" \
    -H "X-Auth-Email: $CFUSER" \
    -H "X-Auth-Key: $CFKEY" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"$CFRECORD_TYPE\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$WAN_IP\",\"ttl\":$CFTTL}")

if echo "$RESPONSE" | grep -q '"success":true'; then
    echo "✅ DNS 更新成功！"
    echo "$WAN_IP" > "$WAN_IP_FILE"

    # ================= Telegram 通知 =================
    if [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]; then
        DISPLAY_OLD_IP=${OLD_WAN_IP:-"首次运行"}
        TG_MSG="✅ <b>DDNS 更新成功</b>%0A%0A🌐 <b>域名:</b> $CFRECORD_NAME%0A🔴 <b>旧 IP:</b> <code>$DISPLAY_OLD_IP</code>%0A🟢 <b>新 IP:</b> <code>$WAN_IP</code>"

        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d chat_id="$TG_CHAT_ID" \
            -d text="$TG_MSG" \
            -d parse_mode="HTML" >/dev/null 2>&1

        echo "📨 Telegram 通知已发送"
    fi
else
    echo "❌ DNS 更新失败！Cloudflare 返回："
    echo "$RESPONSE"
    exit 1
fi
