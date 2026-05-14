# ccc on Windows (WSL2) 完整 setup guide

写给会用 PowerShell, 不熟 Linux 的用户. 跟着每一段从上到下复制粘贴, 跑完就有一个常驻 Windows 的 apns-server, iPhone 上的 ccc app 能远程连过来开 Claude Code session.

参考: macOS / Linux 部署见 `SETUP_SERVER.md`. 本文只写 Windows 走 WSL2 这条路径.

---

## 0. 你需要什么

- Windows 10 22H2+ 或 Windows 11. Win 10 老版本先在"设置 → Windows 更新"升到 22H2 再继续
- 内存 8 GB 及以上
- 至少 30 GB 空闲磁盘. Ubuntu 镜像, Node, Python, Claude Code, model cache 加起来吃这么多
- 一台 Mac 在手边. 因为 Apple Push 的 `.p8` 私钥要从 Mac mini 的 `secrets/` 目录 scp 过来. 若你只想本地连不走 APNs 推送, 可跳过这部分

后面所有"WSL 内"命令在 Ubuntu 终端跑, "PowerShell 管理员模式"命令在 Windows 主机的 PowerShell 跑. 不要混.

---

## 1. 装 WSL2 + Ubuntu 22.04

PowerShell 管理员模式:

```powershell
wsl --install -d Ubuntu-22.04
```

重启电脑. Ubuntu 第一次启动时会让你设用户名和密码, 这是 WSL 内 Linux 账号, 跟 Windows 账号无关.

verify 命令, PowerShell:

```powershell
wsl -l -v
```

期望 output 类似:

```
  NAME            STATE           VERSION
* Ubuntu-22.04    Running         2
```

`VERSION` 必须是 `2`. 如果是 `1` 跑:

```powershell
wsl --set-version Ubuntu-22.04 2
```

version 2 才支持 systemd 跟 nested vm, 后面 systemd unit 起不来都是 version 错.

---

## 2. WSL 开 systemd

WSL Ubuntu 终端:

```bash
sudo tee /etc/wsl.conf > /dev/null <<'EOF'
[boot]
systemd=true

[network]
generateResolvConf=true
EOF
```

退出 WSL 回 PowerShell 重启 WSL:

```powershell
wsl --shutdown
wsl
```

verify, WSL 内:

```bash
systemctl is-system-running
```

期望返回 `running` 或者 `degraded`. 如果返回 `offline` 或者命令找不到, 上一段 wsl.conf 没生效, 检查文件内容并重复 `wsl --shutdown`.

---

## 3. WSL 装依赖

WSL 内 Ubuntu 终端:

```bash
sudo apt update
sudo apt upgrade -y
sudo apt install -y build-essential tmux git curl python3.11 python3.11-venv python3.11-dev nodejs npm
```

verify:

```bash
python3.11 --version
node --version
npm --version
tmux -V
```

四条都返版本号才算过.

npm 全局路径修一下避免 `claude` 命令找不到. WSL 内:

```bash
mkdir -p ~/.npm-global
npm config set prefix ~/.npm-global
echo 'export PATH=~/.npm-global/bin:$PATH' >> ~/.bashrc
source ~/.bashrc
```

---

## 4. 装 Claude Code 跟首次 OAuth 登录

WSL 内:

```bash
npm install -g @anthropic-ai/claude-code
```

verify:

```bash
claude --version
```

第一次跑 `claude` 进 OAuth 流程:

```bash
claude
```

它会打印一条 URL 加一段 code, 形如:

```
https://claude.ai/oauth/authorize?...
Then paste this code: XXXX-XXXX
```

**关键**: WSL 没图形浏览器. **手动把 URL 复制到 Windows 浏览器打开** (Edge, Chrome 都行), 走 Anthropic 登录, 拿到回调里的 code, 粘回 WSL 终端的 prompt. claude 会写 `~/.config/anthropic/credentials` 这一份就长期生效.

verify:

```bash
claude --version
ls ~/.config/anthropic/
```

second 行能看到 `credentials` 文件就行.

---

## 5. apns-server 拉代码 + 配置

WSL 内:

```bash
mkdir -p ~/CcCompanion
cd ~/CcCompanion
git clone <你 git 仓库 URL> dynamic-island
cd dynamic-island/apns-server
```

`<你 git 仓库 URL>` 填你自己那份 dynamic-island 仓的地址. 如果只有 Mac mini 上有源码没推 git, 可以从 Mac 直接拷:

```bash
# 在 Mac 上, 把整个 dynamic-island scp 到 WSL
# 先在 WSL 跑 ifconfig | grep "inet " 拿 WSL 的 IP
# 然后 Mac 终端:
#   scp -r ~/CcCompanion <你 Win 用户名>@<WSL IP>:~/CcCompanion/
```

进项目目录, 建虚拟环境:

```bash
cd ~/CcCompanion/apns-server
python3.11 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

`requirements.txt` 当前只列三个直接依赖 `PyJWT>=2.8.0`, `cryptography>=42.0.0`, `httpx[http2]>=0.27.0`. push.py 还 import 了 `tomllib` (Python 3.11 stdlib 自带, 不用装).

verify:

```bash
python -c "import jwt, cryptography, httpx, tomllib; print('deps OK')"
```

复制配置模板:

```bash
cp config.example.toml config.toml
```

`config.toml` 改 4 个核心字段, 用 nano 或者 vim:

```toml
[apns]
p8_path = "~/CcCompanion/apns-server/secrets/AuthKey_XXXXXXXXXX.p8"
team_id = "XXXXXXXXXX"
key_id = "XXXXXXXXXX"
bundle_id = "com.starryfield.CcCompanion"
sandbox = false   # TestFlight / App Store build 走 false. Xcode debug build 走 true

[server]
host = "0.0.0.0"        # WSL 内必须 0.0.0.0, 不能 127.0.0.1, 否则 netsh portproxy 抓不到
port = 8795
shared_secret = "<生成一个>"
strict_auth = true
```

生成 `shared_secret` 用 Python:

```bash
python3 -c "import secrets; print(secrets.token_hex(16))"
```

也可以复用 Mac mini 那台的同一个 secret, 这样 ccc app 端切 endpoint 时不用换. 多个 server 多个 secret 也行, ccc app `CcServerConfig` 支持多 endpoint 加 fallback.

`.p8` 私钥从 Mac mini 拷过来:

```bash
mkdir -p ~/CcCompanion/apns-server/secrets
# 在 Mac 上跑, IP 替换:
#   scp ~/CcCompanion/apns-server/secrets/AuthKey_*.p8 <Win 用户>@<WSL IP>:~/CcCompanion/apns-server/secrets/
```

权限锁紧:

```bash
chmod 600 ~/CcCompanion/apns-server/config.toml
chmod 600 ~/CcCompanion/apns-server/secrets/*.p8
```

---

## 6. 启动 apns-server 跟 cc tmux session (systemd 版)

两条路二选一. 推荐用 systemd, 跨 WSL 重启不丢. 简单 tmux 一次性的也保留作 fallback.

### 6.1 systemd unit (推荐)

WSL 内, user-scope 不需要 sudo:

```bash
mkdir -p ~/.config/systemd/user
```

写 apns-server unit:

```bash
tee ~/.config/systemd/user/apns-server.service > /dev/null <<'EOF'
[Unit]
Description=Cc APNs server (ccc backend)
After=network-online.target

[Service]
Type=simple
WorkingDirectory=%h/Cc/dynamic-island/apns-server
ExecStart=%h/Cc/dynamic-island/apns-server/.venv/bin/python %h/Cc/dynamic-island/apns-server/push.py
Restart=on-failure
RestartSec=3
StandardOutput=append:%h/Cc/dynamic-island/apns-server/push.log
StandardError=append:%h/Cc/dynamic-island/apns-server/push.err.log

[Install]
WantedBy=default.target
EOF
```

写 cc tmux unit (常驻 Claude Code session, ccc app 通过 push.py 注入 keys 到这个 session):

```bash
tee ~/.config/systemd/user/cc-tmux.service > /dev/null <<'EOF'
[Unit]
Description=Persistent Claude Code tmux session (opia)
After=network-online.target

[Service]
Type=forking
ExecStart=/usr/bin/tmux new-session -d -s opia "claude --dangerously-skip-permissions"
ExecStop=/usr/bin/tmux kill-session -t opia
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
```

开 lingering 让 user systemd 在没登录 shell 时也跑:

```bash
sudo loginctl enable-linger $USER
```

reload + enable + start:

```bash
systemctl --user daemon-reload
systemctl --user enable apns-server.service cc-tmux.service
systemctl --user start apns-server.service cc-tmux.service
```

verify:

```bash
systemctl --user status apns-server.service
systemctl --user status cc-tmux.service
tmux list-sessions
curl -s http://127.0.0.1:8795/health
```

期望:
- 两个 service 都 `active (running)`
- `tmux list-sessions` 看到 `opia:`
- curl 返 `{"ok": true, ...}`

看 log:

```bash
tail -f ~/CcCompanion/apns-server/push.log
```

### 6.2 简单 tmux 一次性 (调试用, 不推荐生产)

如果你只想先测一下不弄 systemd:

```bash
tmux new-session -d -s apns "~/CcCompanion/apns-server/.venv/bin/python ~/CcCompanion/apns-server/push.py"
tmux new-session -d -s opia "claude --dangerously-skip-permissions"
tmux attach -t apns   # 看 server log
```

缺点: 关 WSL 终端这两个 session 也跟着停. 重启 WSL 也丢. 自启失败.

---

## 7. Tailscale 加 netsh portproxy

**Tailscale 装在 Windows 主机, 不装 WSL 里**. WSL 是嵌套 NAT, Tailscale 装 WSL 里走不通.

### 7.1 装 Tailscale Windows

下载 `https://tailscale.com/download/windows` 安装. 装好登录 (用同一个 Tailscale 账号让所有设备进同一 tailnet). Tailscale 给你的 Windows 主机一个固定 100.x.x.x 的 IP. 记下来.

PowerShell:

```powershell
tailscale ip -4
```

期望返 `100.x.x.x` 一行. 这就是后面 iPhone 端要填的 IP.

### 7.2 端口转发 Win → WSL

WSL2 默认 IP 隔离, Windows 主机访问不到 WSL 里的 8795. netsh portproxy 桥起来.

WSL IP 每次重启 WSL 都会变, 必须脚本动态查 + 重建. 写一份 PowerShell 脚本:

PowerShell 管理员模式, 注意保存位置. 这里用 `C:\Tools\ccc-portproxy.ps1`:

```powershell
New-Item -ItemType Directory -Path C:\Tools -Force | Out-Null

@'
$ErrorActionPreference = "Stop"
$wslIp = (wsl hostname -I).Trim().Split(" ")[0]
if (-not $wslIp) {
    Write-Error "Cannot resolve WSL IP. Is WSL running?"
    exit 1
}
netsh interface portproxy reset
netsh interface portproxy add v4tov4 listenport=8795 listenaddress=0.0.0.0 connectaddress=$wslIp connectport=8795
netsh advfirewall firewall show rule name="ccc-8795" > $null 2>&1
if ($LASTEXITCODE -ne 0) {
    netsh advfirewall firewall add rule name="ccc-8795" dir=in action=allow protocol=TCP localport=8795
}
Write-Host "portproxy 0.0.0.0:8795 -> $wslIp:8795"
'@ | Out-File -Encoding ASCII C:\Tools\ccc-portproxy.ps1
```

跑一次 verify:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Tools\ccc-portproxy.ps1
netsh interface portproxy show v4tov4
```

期望:

```
Listen on ipv4:             Connect to ipv4:
Address         Port        Address         Port
--------------- ----------  --------------- ----------
0.0.0.0         8795        172.x.x.x       8795
```

172.x.x.x 是当前 WSL 的内部 IP.

### 7.3 登录时自动重建 portproxy

每次 Windows 启动 WSL IP 会变, 让 Task Scheduler 登录时跑一遍这个脚本.

PowerShell 管理员模式 一键创建任务:

```powershell
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Tools\ccc-portproxy.ps1"
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd
Register-ScheduledTask -TaskName "CcCompanion-PortProxy" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
```

或者用 GUI 也行: 开始菜单搜"任务计划程序" → 创建任务 → 触发器选"登录时" → 操作选"启动程序" → 程序 `powershell.exe` 参数 `-WindowStyle Hidden -ExecutionPolicy Bypass -File C:\Tools\ccc-portproxy.ps1` → 在"常规"标签勾"以最高权限运行".

verify, PowerShell 管理员模式:

```powershell
Get-ScheduledTask -TaskName "CcCompanion-PortProxy" | Format-List TaskName, State, Triggers
```

State 是 `Ready` 就行. 下次 Windows 重启登录后再 `netsh interface portproxy show v4tov4` 看 portproxy 是否自动重建.

防火墙规则脚本里已经加了, 这里 verify 一下:

```powershell
netsh advfirewall firewall show rule name="ccc-8795"
```

看到一条 inbound TCP 8795 allow 就对.

---

## 8. iPhone 端配置

打开 ccc app onboarding wizard. 如果之前没装过 ccc, 走 App Store 装一下.

### 8.1 全新装

wizard 里填:

- Server URL: `http://<Win Tailscale IP>:8795`. 例如 `http://100.x.x.x:8795`
- Shared Secret: 第 5 步 `config.toml` 里 `shared_secret` 那一行的值

下一步 wizard 会自动打 `/health`, 看到 connection OK 就过.

### 8.2 已经在 Mac mini 配过 ccc 想加 Win 作为 fallback

不要覆盖原来的. 走 Settings → Server endpoints → 加新一条. 给 label 一个明显名字比如 `Win-WSL`, mac mini 那条保持 label `mac-mini`. EndpointResolver 后台 `/health` ping 60 秒一次, 自动切到当前能通的那个. 两台都开时优先级按列表顺序.

---

## 9. 验证链 (4 条都通才算搭好)

```bash
# 1. WSL 内
curl -s http://127.0.0.1:8795/health

# 2. Win 主机 PowerShell (经 portproxy 回到 WSL)
curl http://127.0.0.1:8795/health

# 3. Win 主机 PowerShell (从 Tailscale 角度自己访问自己)
curl http://<Win Tailscale IP>:8795/health

# 4. iPhone 上 ccc app 走 wizard 测连接, 或者已配好的话进 Settings → Server endpoints → 点 health 检查
```

四条都返 `{"ok": true, "uptime": <数字>, ...}` 算完整通.

第二步走 `curl` 不通最常见原因是 portproxy 没起或 WSL IP 变了, 跑一次 `C:\Tools\ccc-portproxy.ps1` 看 verify 命令的 output 修正.

第三步走 `curl` 不通通常是防火墙. PowerShell 管理员模式:

```powershell
netsh advfirewall firewall show rule name="ccc-8795"
```

没看到规则就重跑一次 portproxy 脚本 (脚本里包了 firewall add).

---

## 10. 常见踩坑

### WSL 时钟漂移

WSL2 系统休眠唤醒后时钟可能漂几分钟. APNs 用时间签 JWT, 漂太多 server 返 403. 修一次:

```bash
sudo hwclock -s
```

自动化, WSL 里加 cron 30 分钟跑一次:

```bash
( crontab -l 2>/dev/null; echo "*/30 * * * * /usr/sbin/hwclock -s" ) | crontab -
```

### Win 休眠杀 WSL

Win 进 hybrid sleep 或 hibernate 时 WSL 整个被 freeze, server 不响应. 解法:

- 控制面板 → 电源选项 → 选当前方案 → 更改高级电源设置 → 把"睡眠"跟"休眠"都设永不
- 或者笔记本插电时永不睡眠, 拔电后随意

### WSL IP 重启变

systemd unit 起在 WSL 里, WSL IP 一变, portproxy 失效, Win 主机访问不到. 上面第 7.3 节的 Task Scheduler 登录时自动重建已经解决, 但如果 Win 不重启只是 `wsl --shutdown` 然后再起, Task Scheduler 那条不会重跑. 手动跑一次:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Tools\ccc-portproxy.ps1
```

### claude OAuth WSL 没浏览器

第 4 步那一坑. WSL 跑 `claude` 第一次会打印 URL + code, 必须手动把 URL 在 Windows 浏览器打开, 拿回调 code, 粘回 WSL terminal prompt. 不要在 WSL 里装 firefox/chrome 那种, 麻烦且不必要.

### /etc/wsl.conf 配 [boot] systemd=true

第 2 步如果没做或者做完没 `wsl --shutdown` 重启 WSL, systemd 起不来, 6.1 里所有 `systemctl --user` 命令都报错. verify:

```bash
ps -p 1 -o comm=
```

返 `systemd` 才算开了. 返 `init` 是 systemd 没起.

### /mnt/c 跨 Windows 文件挂载点性能差

不要把 `apns-server` 放在 `/mnt/c/...` 下. 放在 WSL 原生 home `~/CcCompanion/` 下. 跨文件系统 I/O 性能差一个数量级, 而且 systemd unit 走 `/mnt/c` 路径时 working directory 解析也容易踩坑.

### secret 文件权限

`config.toml` 跟 `secrets/*.p8` 都必须 `chmod 600`. WSL 默认 umask 比较宽, 容易留 0644 让其他 user 读到. 第 5 步末尾的 chmod 命令必须跑.

### npm 全局装路径

第 3 步加的 `~/.npm-global` 到 PATH. 如果没做, 跑 `claude` 会 "command not found". verify:

```bash
which claude
```

应该是 `~/.npm-global/bin/claude`. 不是的话 source `~/.bashrc` 重试.

### apns-server import 错

如果 `python push.py` 报 import error, 99% 是没 `source .venv/bin/activate` 直接跑了系统 Python. systemd unit 已经写绝对路径 `%h/Cc/dynamic-island/apns-server/.venv/bin/python` 不踩这坑, 手动 tmux 起的话注意.

---

## 11. 不在本文范围

- mac mini 那边的部署 (见 `SETUP_SERVER.md` 的 macOS 段)
- ccc 或 apns-server 源码层修改 (本文只搭运行环境, 不动代码)
- ZeroTier 路径. 跟 Tailscale 思路一样, 装在 Windows 主机, 把 Win 0.0.0.0:8795 portproxy 进 WSL, 走 ZeroTier 内网 IP 访问. 不展开
- 完全不走 Tailscale 的公网暴露 (DDNS, Cloudflare Tunnel 等), 见 `SETUP_SERVER.md` 的"公网通路"一节
- 如何在 WSL 升级 OTS / ccc 客户端 (另一份文档管)

---

## 12. 一句话回顾

WSL2 装 Ubuntu 22.04 开 systemd → apt 装 build 工具 + Python + Node + tmux → npm 装 claude code 走一次 OAuth → git clone dynamic-island, venv 装三个 pip 依赖, copy config 改 host port secret → systemd 起 apns-server + cc-tmux 两个 user unit → Tailscale 装 Win 主机不装 WSL, PowerShell netsh portproxy 加 Task Scheduler 登录时重建 → iPhone ccc app 填 Tailscale IP 跟 shared_secret → 四条 curl 全返 ok.

后续问题:
- log: `~/CcCompanion/apns-server/push.log` 跟 `push.err.log`
- 改 config 后重启 service: `systemctl --user restart apns-server.service`
- 看 cc session: `tmux attach -t opia`, Ctrl-b d 解 attach 不杀 session
- 改 portproxy 端口: 改第 7.2 节脚本里的 8795 跟 firewall rule 重跑
