# OTS Server 端搭建指南

> 给 ClaudeCodeCompanion 阉割版用户用。本文档覆盖 macOS / Linux / Windows 三个 OS 的 server (push.py) 部署步骤。
>
> **使用前请先读 [DISCLAIMER.md](DISCLAIMER.md)。**

---

## 一句话总览

要让 OpiaCompanion / ClaudeCodeCompanion iPhone app 跑起来，你需要：

1. 一台常驻在线的电脑（任何 OS 都行）
2. 在那台电脑装 Claude Code (cc) 并登录
3. 在那台电脑跑 OTS server (push.py)
4. 让公网能 reach 到那台电脑的 server 端口
5. iPhone 端 onboarding wizard 填 server 地址 + 共享密钥 + 测试连接

---

## 前置准备

| 项 | 说明 |
|---|---|
| 电脑 | macOS / Linux / Windows 任一。常驻在线最佳，如断网或休眠 iPhone 端会拉不到消息 |
| Python 3.11 及以上 | server 运行环境 |
| Claude Code | Anthropic 官方 CLI，需要 Pro 或 Max 订阅 |
| 域名（推荐） | 公网入口，可选纯 IP + 端口 |
| 公网通路 | 路由器端口转发 / 反向代理 / Cloudflare Tunnel / Tailscale / ZeroTier 任一 |

---

## macOS 部署

### 1. 装 Python

```bash
brew install python@3.11
```

如未装 Homebrew 先 `https://brew.sh` 装。

### 2. 装 Claude Code

```bash
brew install --cask claude  # 或者按 https://claude.ai/code 官方步骤
```

启动一次跑 `claude` 走 OAuth 登录到你的 Pro / Max 账号。

### 3. clone OTS

```bash
git clone https://github.com/<TBD>/ots-framework.git
cd ots-framework/apns-server
```

> 仓库 URL 待 ClaudeCodeCompanion 阉割版上线后用户拍，临时可用本地副本。

### 4. 装依赖

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 5. 配置

复制 `config.example.toml` 为 `config.toml`，编辑：

```toml
[server]
host = "127.0.0.1"      # 内网监听
port = 8795
strict_auth = true       # 强制 token 鉴权
shared_secret = "<32位随机字符串>"   # 跟 iPhone wizard 填的一样
```

生成强随机密钥：

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
```

### 6. 启动

```bash
python3 push.py --config config.toml
```

看到 `listening on :8795` 即成功。

测试：
```bash
curl http://localhost:8795/health
# 应返回 {"ok": true, "service": "opia-push"}
```

### 7. 开机自启 (可选)

写 launchd plist：

```bash
cat > ~/Library/LaunchAgents/com.starryfield.ots-server.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.starryfield.ots-server</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/python3</string>
        <string>$(pwd)/push.py</string>
        <string>--config</string>
        <string>$(pwd)/config.toml</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$(pwd)</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.starryfield.ots-server.plist
```

### 8. 公网通路

推荐 Tailscale 或 Cloudflare Tunnel（路由器层、客户端零配置）：

**Tailscale:**
```bash
brew install --cask tailscale
# 路由器装 Tailscale 客户端，把这台 mac 加进同一 Tailnet
# iPhone Tailscale app 同账号登录
# server 地址用 Tailscale magic dns 名: http://your-mac.tailnet.ts.net:8795
```

**Cloudflare Tunnel:**
```bash
brew install cloudflared
cloudflared tunnel login
cloudflared tunnel create ots
cloudflared tunnel route dns ots ots.your-domain.com
cloudflared tunnel run --url http://localhost:8795 ots
# server 地址用 https://ots.your-domain.com
```

---

## Linux 部署 (Ubuntu / Debian / Arch)

### 1. 装 Python

```bash
# Ubuntu / Debian
sudo apt update && sudo apt install python3.11 python3.11-venv python3-pip git curl -y

# Arch
sudo pacman -S python python-pip git curl
```

### 2. 装 Claude Code

```bash
curl -fsSL https://claude.ai/install.sh | bash  # 按官方文档为准
claude  # 走 OAuth
```

### 3-6. clone / 装依赖 / 配置 / 启动

跟 macOS 步骤一样。

### 7. 开机自启

写 systemd unit：

```bash
sudo tee /etc/systemd/system/ots-server.service <<EOF
[Unit]
Description=OTS push server
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$(pwd)
ExecStart=$(pwd)/.venv/bin/python3 $(pwd)/push.py --config $(pwd)/config.toml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl enable ots-server
sudo systemctl start ots-server
sudo systemctl status ots-server
```

### 8. 公网通路

跟 macOS 一样，Tailscale 或 Cloudflare Tunnel 推荐。也可路由器层端口转发到 8795 + 用 caddy 加 HTTPS。

---

## Windows 部署 (走 WSL2)

OTS 用 tmux 跟 launchd / systemd 这些 *nix 工具，原生 Windows 不太适合。最稳路径走 WSL2 + Ubuntu。

### 1. 装 WSL2 + Ubuntu

PowerShell 管理员模式：
```powershell
wsl --install -d Ubuntu
```

重启电脑，等 Ubuntu 安装完成，设 WSL 用户名密码。

### 2. WSL 里走 Linux 步骤

进 Ubuntu 终端，按上面 Linux 部署 1-7 步全跑一遍。

### 3. WSL → Windows 端口转发

WSL2 默认 IP 隔离，Windows 主机访问不到 WSL 里的 8795 端口。需要端口转发：

PowerShell 管理员模式：
```powershell
$wslIp = (wsl hostname -I).Trim().Split(' ')[0]
netsh interface portproxy add v4tov4 listenport=8795 connectaddress=$wslIp connectport=8795
netsh advfirewall firewall add rule name="OTS-8795" dir=in action=allow protocol=TCP localport=8795
```

之后 Windows 主机的 8795 端口就转到 WSL 里的 push.py。

### 4. 公网通路

跟 macOS / Linux 一样，Tailscale 或 Cloudflare Tunnel。但客户端装在 Windows 主机，不要装 WSL 里。

---

## 验证 server 真通

任何 OS 部署完，最后跑这两条：

```bash
# 本地通
curl http://localhost:8795/health

# 公网通 (替换成你公网入口)
curl https://your-public-domain.com/health
# 或者
curl http://your-tailscale-ip:8795/health
```

两条都返回 `{"ok": true, ...}` 算 server 端搭好。

---

## iPhone 端配置

server 端搭好后：

1. 装 ClaudeCodeCompanion (TestFlight)
2. 第一次打开 app 自动弹 onboarding wizard
3. Step 2 填 server 地址（上面 verify 时用的公网入口）
4. Step 3 填 shared_secret（config.toml 里那个）
5. Step 4 测试连接 → ✅ 进 chat tab

完成。

---

## 常见踩坑

### "公网 IP 跟内网 IP 没分清"

push.py 里 `host = "127.0.0.1"` 是**内网监听**，不是 iPhone 要填的地址。iPhone 填的是路由器 / Tunnel 配的**公网入口**。

### "Tailscale 装在 iPhone 上断流"

iPhone 切网络时 Tailscale 客户端容易断连，造成 polling 失败。最好把 Tailscale 装在路由器层（如 GL.iNet 路由器 / OpenWRT），iPhone 端零 VPN 配置。

### "config.toml 里 strict_auth=false"

仅用于本地调试。**生产必须 strict_auth=true 加强 shared_secret**。否则 server 端 `/tmux/send`、`/chat/regenerate` 这类端点暴露公网会被任何人滥用驱动你的 Claude Code session（账号风险）。

### "TestFlight 装上 app 连不上"

99% 是 server 地址或 secret 填错。重开 wizard：
- 设置 tab → 重置 onboarding → 重填

### "Claude Code 登不上"

Anthropic Pro / Max 必须用支持地区账号。中国大陆当前不在 [supported regions](https://www.anthropic.com/supported-countries)，账号风险见 [DISCLAIMER.md](DISCLAIMER.md) §4。

---

*作者：Opia*
*OTS server setup v0.1 · 2026-05-09*
