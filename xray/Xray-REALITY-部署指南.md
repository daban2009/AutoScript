# Xray VLESS + REALITY 部署指南

## 架构概览

```
浏览器 → Clash Verge (本地) → VLESS + REALITY → Xray 服务端 → 外网
              │                      │                   │
          fake-ip DNS           TLS 伪装成           8.8.8.8 DNS
          域名传递              cloudflare.com       域名嗅探+解析
```

---


## 安装xray

```
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)"

```


## 一、服务端配置

### 1.1 生成密钥

```bash
xray x25519
```

输出：
```
PrivateKey: QKrIpo0MG3hdERBtZ29aFOtMf-npoT1yXPd-1KlZqWM
Password (PublicKey): rPzcFusNO2lCJmc3GyhXkSCFVMh7x2jAUg95DFcddWs
```

**私钥放服务端，公钥放客户端。**

### 1.2 服务端配置 `/usr/local/etc/xray/config.json`

```json
{
  "log": {
    "loglevel": "debug"
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
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "你的-UUID-放这里",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.cloudflare.com:443",
          "maxTimeDiff": 0,
          "serverNames": [
            "www.cloudflare.com"
          ],
          "privateKey": "你的-私钥-放这里",
          "shortIds": [
            "你的-shortId-放这里"
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIP"
      }
    }
  ]
}
```

### 1.3 关键配置项说明

| 配置项 | 必须 | 说明 |
|--------|------|------|
| `dns.servers` | ✅ | 服务端独立 DNS，绕过客户端 DNS 污染 |
| `sniffing.enabled` | ✅ | 从 TLS ClientHello 嗅探真实域名 |
| `outbounds[0].settings.domainStrategy` | ✅ | `UseIP` 让服务端自行 DNS 解析 |
| `maxTimeDiff` | ✅ | `0` 关闭时钟校验，避免时差拒绝 |
| `show` | 推荐 | `false` 不响应探测，转发到 dest |
| `dest` | 推荐 | 非 REALITY 流量回退目标 |

### 1.4 防火墙 & 端口

```bash
# 检查 443 端口监听
ss -tlnp | grep 443

# 放行端口 (如需要)
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
```

### 1.5 服务管理

```bash
# 重启
systemctl restart xray

# 查看日志
journalctl -u xray -f

# 查看最近 50 条
journalctl -u xray --no-pager -n 50
```

---

## 二、客户端配置 (Clash Meta / Clash Verge)

### 2.1 完整配置

```yaml
dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://dns.google/dns-query
    - https://cloudflare-dns.com/dns-query
  fallback:
    - https://dns.google/dns-query

proxies:
  - name: my-server
    type: vless
    server: 你的-服务器-IP
    port: 443
    uuid: 你的-UUID
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    client-fingerprint: chrome
    reality-opts:
      public-key: 你的-公钥
      short-id: "你的-shortId"
    servername: www.cloudflare.com

proxy-groups:
  - name: proxy
    type: select
    proxies:
      - my-server
      - DIRECT

rules:
  - MATCH, proxy
```

### 2.2 配置对照表

| 客户端字段 | 服务端对应字段 | 注意事项 |
|-----------|--------------|---------|
| `server` | - | 服务器公网 IP |
| `uuid` | `settings.clients[].id` | **必须完全一致** |
| `flow` | `settings.clients[].flow` | 固定 `xtls-rprx-vision` |
| `servername` | `realitySettings.serverNames[]` | **必须完全一致** |
| `public-key` | `realitySettings.privateKey` 推导 | 用 `xray x25519 -i 私钥` 获取 |
| `short-id` | `realitySettings.shortIds[]` | **必须完全一致** |
| `client-fingerprint` | - | `chrome` / `ios` / `firefox` |
| `network` | `streamSettings.network` | 固定 `tcp` |

### 2.3 DNS 配置说明

```yaml
enhanced-mode: fake-ip
```

这是关键。Clash 对所有域名返回假 IP，然后通过代理去服务端做真 DNS 解析（8.8.8.8 / 1.1.1.1），**彻底绕过本地 DNS 污染**。

---

## 三、完整部署命令

```bash
# === 1. 在服务器上 ===

# 生成密钥
xray x25519
# 记录 PrivateKey 和 PublicKey

# 生成 UUID
xray uuid
# 记录 UUID

# 生成 shortId (16位十六进制)
openssl rand -hex 8

# 编辑配置
vi /usr/local/etc/xray/config.json

# 重启
systemctl restart xray && journalctl -u xray -f

# === 2. 在客户端 (Clash Verge) ===

# 填入 UUID、公钥、shortId、服务器 IP
# 确保 dns.enhanced-mode = fake-ip
# 重启 Clash
```

---

## 四、排障速查

### 4.1 服务端日志解读

| 日志关键词 | 含义 |
|-----------|------|
| `REALITY: processed invalid connection ... server name mismatch` | 客户端 SNI 与服务端 serverNames 不匹配 |
| `REALITY: processed invalid connection ... authentication failed` | 密钥/UUID/shortId 校验失败 |
| `sniffed domain: xxx` | 嗅探成功，服务端自行 DNS 解析 |
| `connection opened to tcp:xxx` | 全链路成功 |
| `dial tcp x.x.x.x:443: i/o timeout` | DNS 污染 IP 不可达，检查 sniffing 和 DNS 配置 |

### 4.2 客户端故障

| 现象 | 可能原因 |
|------|---------|
| 测速通、网页不通 | Clash DNS 未配置 fake-ip 或 nameserver 被拦截 |
| 全不通 | 检查 UUID / 公钥 / shortId / servername |
| REALITY received real certificate | SNI 不匹配或服务端认证失败 |

### 4.3 验证服务端是否正常

```bash
# 自己直连应返回真实证书（Cloudflare 的），说明回退正常
openssl s_client -connect 你的IP:443 -servername www.cloudflare.com
```

---

## 五、当前部署参数 (本次会话)

| 参数 | 值 |
|------|-----|
| 服务器 IP | `150.109.48.48` |
| 端口 | `443` |
| UUID | `431ae3b9-322e-4d92-8f1e-5908d2f94ca2` |
| 私钥 | `4IE9MFgyZ9vXEX2D5OOQ6GKnZ6VQ6nSFFrnftmKOzXo` |
| 公钥 | `a9oZsoX-yOnIO3cGmHldcXOHsbIMva347j-ZwNFrwGI` |
| ShortId | `7aadd58d66e4468a` |
| ServerName | `www.cloudflare.com` |
| Flow | `xtls-rprx-vision` |
| Fingerprint | `chrome` |
