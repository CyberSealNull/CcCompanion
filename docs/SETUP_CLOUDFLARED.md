# Cloudflare Tunnel (cloudflared) 方案

> 不需要 Tailscale / ZeroTier / 公网 IP / 端口映射，只需要一个域名和免费的 Cloudflare 账号。
> 5G / 4G / 任何网络都能连。适合没有 Tailscale 或想要一个公网备用通道的用户。

---

## 定位

| 方案 | 优点 | 缺点 | 适合场景 |
|------|------|------|----------|
| **Tailscale** (推荐主路) | 点对点直连、延迟低、稳定 | 需要两端装 Tailscale、首次 DERP 冷启动 2-5s | 主力通道 |
| **Cloudflare Tunnel** (本文) | 无需装客户端、任何网络即连、免费 | 经过 CDN 中转延迟略高、免费层偶发解析抖动 | Tailscale 备用 / 没有 Tailscale 的用户 / 外出应急 |

**建议**: 在 app 里同时配 Tailscale 内网地址 + cloudflared 公网地址两个 endpoint，app 会自动 ping 选活的那个。

---

## 前置条件

- 一个域名（任何注册商都行，免费域名也可以）
- 域名 DNS 托管到 Cloudflare（免费）
- macOS / Linux 电脑，已装好 push.py 并能本地跑通

---

## 步骤

### 1. 安装 cloudflared

```bash
# macOS
brew install cloudflared

# Linux (Debian/Ubuntu)
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list
sudo apt update && sudo apt install cloudflared
```

### 2. 登录 Cloudflare

```bash
cloudflared tunnel login
```

浏览器会弹出 Cloudflare 授权页面，选择你的域名，授权完成后会在 `~/.cloudflared/` 生成 `cert.pem`。

### 3. 创建命名隧道

```bash
cloudflared tunnel create ccc-tunnel
```

创建成功后会显示隧道 ID（一串 UUID），并在 `~/.cloudflared/` 生成 `<隧道ID>.json` 凭证文件。记下这个 ID。

### 4. 添加 DNS 路由

```bash
cloudflared tunnel route dns <隧道ID> ccc.你的域名.com
```

这会在 Cloudflare DNS 里自动添加一条 CNAME 记录，指向你的隧道。

### 5. 配置 config.yml

编辑 `~/.cloudflared/config.yml`：

```yaml
tunnel: <隧道ID>
credentials-file: /Users/你的用户名/.cloudflared/<隧道ID>.json

ingress:
  - hostname: ccc.你的域名.com
    service: http://localhost:8795
  - service: http_status:404
```

> 如果已有其他隧道路由（比如博客、阅读器），直接在 `ingress` 里加一条即可，多个 hostname 共用同一条隧道。

### 6. 启动隧道

```bash
cloudflared tunnel run
```

验证：

```bash
curl https://ccc.你的域名.com/health
```

应返回 `{"ok": true, ...}`。

### 7. 守护进程（推荐）

让隧道开机自启、挂了自动重启。

**macOS (launchd)**:

```bash
cloudflared service install
```

或手动创建 plist 文件 `~/Library/LaunchAgents/com.cloudflare.cloudflared.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cloudflare.cloudflared</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/cloudflared</string>
        <string>tunnel</string>
        <string>run</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/cloudflared.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/cloudflared.err.log</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.cloudflare.cloudflared.plist
```

**Linux (systemd)**:

```bash
cloudflared service install
sudo systemctl enable cloudflared
sudo systemctl start cloudflared
```

### 8. App 配置

在 CcCompanion app 的 onboarding wizard 或设置里：

- Server 地址填：`https://ccc.你的域名.com`
- 密钥填 `config.toml` 里的 `shared_secret`

---

## 踩坑记录

| 坑 | 现象 | 解法 |
|----|------|------|
| **VPN + 局域网地址冲突** | 用 `http://192.168.x.x` 局域网地址时 VPN 劫持流量导致连不上 | 换成 cloudflared 公网地址 `https://...` 后 VPN 不再冲突。这也是 cloudflared 方案的优势之一 |
| **ATS 要求 HTTPS** | app 报 "App Transport Security policy requires secure connection" | 必须用 `https://` 地址，不能用 `http://` 裸 IP。cloudflared 自动提供 HTTPS |
| **Quick tunnel 不稳定** | `cloudflared tunnel --url` 快速隧道偶尔创建失败 | 用命名隧道（named tunnel）代替快速隧道，稳定性高很多 |
| **半夜解析抖动** | 凌晨偶发 DNS 解析失败 | cloudflared 免费层已知问题。建议 app 同时配 Tailscale endpoint 做主路，cloudflared 做备用 |
| **忘连 WiFi** | 局域网地址连不上 | 如果用局域网 IP（192.168.x.x），iPhone 必须和 Mac 在同一 WiFi。用 cloudflared 公网地址则无此限制 |

---

## 安全提醒

- `shared_secret` 一定要设，否则公网裸奔任何人都能连你的 Claude Code
- `config.toml` 里 `strict_auth = true` 保持开启
- cloudflared 隧道本身是加密的（TLS），流量安全

---

## 实测数据

- 从 clone 仓库到双向通：约 1 小时（含排查 VPN 冲突和 ATS 问题）
- 5G 网络延迟：发送到收到回复约 1-2 秒
- 命名隧道连接数：自动保持 4 条到不同边缘节点，单条断开其他接管
