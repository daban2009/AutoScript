#!/usr/bin/env bash
set -e

#####################################
# Xray + VLESS-REALITY 一键安装脚本
# 用法: bash <(curl -fsSL https://raw.githubusercontent.com/<你的仓库>/main/install.sh)
#####################################

# ---- 可配置项（通过环境变量覆盖）----
SERVER_NAME="${SERVER_NAME:-www.cloudflare.com}"
DEST="${DEST:-www.cloudflare.com:443}"
PORT="${PORT:-443}"

#####################################
# 1. 安装 Xray
#####################################
if command -v xray >/dev/null 2>&1; then
    echo ">>> Xray 已安装，跳过安装步骤"
else
    echo ">>> 正在安装 Xray ..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)"
fi

# 确保安装成功后 xray 可用
if ! command -v xray >/dev/null 2>&1; then
    echo "错误: Xray 安装失败，xray 命令不可用"
    exit 1
fi

#####################################
# 2. 获取服务器 IP（多个备用源，逐个尝试）
#####################################
echo ">>> 获取服务器公网 IP ..."
SERVER_IP=""
for src in \
    "https://api.ipify.org" \
    "https://ifconfig.me" \
    "https://icanhazip.com" \
    "https://ip.sb" \
    "https://checkip.amazonaws.com"; do
    SERVER_IP=$(curl -4 -fsSL --connect-timeout 5 "$src" 2>/dev/null) && break || true
done

if [ -z "$SERVER_IP" ]; then
    echo "错误: 无法获取公网 IP，所有接口均不通，请检查网络"
    exit 1
fi
echo "    服务器 IP: $SERVER_IP"

#####################################
# 3. 生成 Reality 密钥
#####################################
echo ">>> 生成 Reality 密钥 ..."
KEY_OUTPUT=$(xray x25519)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | awk -F': ' '/PrivateKey/{print $2}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | awk -F': ' '/PublicKey/{print $2}')
echo "    私钥: $PRIVATE_KEY"
echo "    公钥: $PUBLIC_KEY"

#####################################
# 4. 生成 UUID
#####################################
UUID=$(xray uuid)
echo ">>> UUID: $UUID"

#####################################
# 5. 生成 shortId
#####################################
SHORT_ID=$(openssl rand -hex 8)
echo ">>> ShortID: $SHORT_ID"

#####################################
# 6. 写入 Xray 配置
#####################################
echo ">>> 写入 Xray 配置到 /usr/local/etc/xray/config.json ..."
cat >/usr/local/etc/xray/config.json <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      "8.8.8.8",
      "1.1.1.1",
      "localhost"
    ]
  },
  "inbounds": [
    {
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}",
          "xver": 0,
          "serverNames": [
            "${SERVER_NAME}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

#####################################
# 7. 重启 Xray
#####################################
echo ">>> 重启 Xray 服务 ..."
systemctl restart xray
sleep 2
systemctl --no-pager status xray

#####################################
# 8. 生成 Clash Meta 客户端配置
#####################################
CLASH_FILE="$(pwd)/clash-meta.yaml"
cat >"$CLASH_FILE" <<EOF
dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://dns.google/dns-query
    - https://cloudflare-dns.com/dns-query

proxies:
  - name: Reality
    type: vless
    server: ${SERVER_IP}
    port: ${PORT}
    uuid: ${UUID}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    client-fingerprint: chrome
    servername: ${SERVER_NAME}
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: "${SHORT_ID}"

proxy-groups:
  - name: Proxy
    type: select
    proxies:
      - Reality
      - DIRECT

rules:
  - MATCH,Proxy
EOF

#####################################
# 9. 生成 VLESS 分享链接
#####################################
URL="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SERVER_NAME}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#Reality"

#####################################
# 10. 输出汇总
#####################################
echo
echo "==============================="
echo " 安装完成"
echo "==============================="
echo
echo "服务器 IP : $SERVER_IP"
echo "端口      : $PORT"
echo "UUID      : $UUID"
echo "私钥      : $PRIVATE_KEY"
echo "公钥      : $PUBLIC_KEY"
echo "ShortID   : $SHORT_ID"
echo "ServerName: $SERVER_NAME"
echo
echo "Clash 配置 : $CLASH_FILE"
echo
echo "VLESS 链接 :"
echo
echo "$URL"
echo
echo "查看日志: journalctl -u xray -f"
