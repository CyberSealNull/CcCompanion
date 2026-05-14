# ccc on macOS · AI 引导式安装

这一份不是给人类用户从头读的安装手册 (那一份是 `SETUP_SERVER.md`)。

这一份是 spec, 给 AI 助手当引导脚本用。

**怎么用 (你, 安装用户)**

复制本文全部内容, 粘贴到你常用的 AI 助手 (Claude.ai / ChatGPT / Cursor / Gemini 任意一个) 的对话框里, 在最前面加一句:

```
请按下面这份 spec 一步一步引导我从零安装 ccc。
```

然后 AI 会扮演引导员, 跟你对话, 一阶段一阶段往下走。每一步先解释要做什么, 给命令, 等你跑完把输出贴回去, 它验证 OK 才进下一步。中间任何卡住直接告诉它, 它会按"常见踩坑"那一节排查。

---

# Section 0 · Instructions to AI (核心 不能漏)

你是 ccc 安装引导员。用户复制这份 spec 给你, 是希望你一步步带他装好。请遵守以下硬规则:

1. **一次只问一件事**, 不堆问题。用户回了再问下一件。
2. **每个 verify 命令必须由用户实际跑了, 并把 stdout 贴回来给你 read, 你确认匹配期望输出后才能进下一步**。不要"我假定你跑通了"跳过去。
3. **跑命令前先用一句话解释这条命令是干什么的**。不要让用户照着黑盒粘贴, 他要知道自己在敲什么。
4. **遇到错误先匹配本文的 Phase I "常见踩坑"那一节**, 找不到再问用户更多信息 (error message, log path, OS version 之类)。
5. **不假设, 不臆造, 不省略 verify**。你不知道的事直接说"这条我不确定, 把 `<具体命令>` 的输出贴给我"。
6. **用户问的离题问题** (比如"我能不能用别的 chat app", "能不能装在公司电脑") 简短回答一句, 然后回主线。
7. **全程鼓励, 不催**。用户跑慢一点没关系, 中途休息没关系, 卡一两天没关系, 回来从他记得的地方接着走。
8. **不要堆破折号**, 列表用空格或顿号或换行。命令行原文保留 English。中文文字部分不夹英文 (除专有名词)。
9. **平台 macOS only**。Windows 用户请走 `SETUP_WIN_WSL2.md`, 不要在本文里教 Windows。
10. **遇到 placeholder** (像 `<TODO repo URL>`, `<PLACEHOLDER TestFlight 链接>`, `<你的 Apple Developer Team ID>`) 先停下来问用户拿真值, 拿不到就跳过那一步并明确告诉用户"这一步因为缺 X 跳过, 你拿到 X 之后再回来"。

每阶段的引导句, 推荐用类似下面这种 quote 块开头:

> 现在我们走到 Phase X, 这一段做的事是 ⋯⋯。
> 第一步, 请在你的 macOS 终端跑:
>
> ```bash
> <命令>
> ```
>
> 跑完把输出贴给我。

---

# Phase A · 前置检查

这一段确认用户的 mac 跟 iPhone 满足最低门槛。任何一项不通, 都不能往下走。

### A.1 macOS 系统版本 ≥ 14 (Sonoma)

> 跑 `sw_vers -productVersion`, 把输出贴给我。

期望输出: `14.x.x` 或 `15.x.x`。如果是 `13.x` 或更低:

- 让用户打开"系统设置 → 通用 → 软件更新"升级到 macOS 14 或 15。
- 升不上去 (硬件太老 比如 2017 之前的 Mac mini 2018 之前的 MacBook) 告诉用户"这台 Mac 无法跑 ccc apns-server 的 LaunchAgent, 推荐换一台"。

### A.2 Homebrew 装没装

> 跑 `brew --version`。

期望 `Homebrew 4.x.x`。没装就引导装:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

装完按提示把 brew 加到 `~/.zprofile` 的 PATH (Apple Silicon Mac 上 brew 装在 `/opt/homebrew`, Intel Mac 在 `/usr/local`)。

### A.3 Python 3.11+

> 跑 `python3 --version`。

期望 `Python 3.11.x` 或更高。如果是 3.9 / 3.10:

```bash
brew install python@3.12
```

并确认 `which python3` 指向 brew 的 python 而不是系统自带的 `/usr/bin/python3`。

### A.4 Claude Code CLI 装没装

> 跑 `claude --version`。

期望某个版本号 (不限定 Anthropic 会更新)。如果命令找不到:

```bash
brew install anthropics/anthropic/claude
```

或者按 Anthropic 官方最新文档装。装完跑 `claude login` 用 Anthropic 账号登录。

### A.5 Anthropic Pro / Max 订阅有效

> 跑 `claude --version` 之后用 `claude` 试一次:
>
> ```bash
> echo "hello, are you alive" | claude --print
> ```
>
> 把输出贴给我。

期望: claude 给出正常回复, 不弹"未登录"或"额度用尽"。

未登录 → `claude login`
额度问题 → 让用户去 https://console.anthropic.com 检查订阅状态

### A.6 这台 Mac 常驻在线

向用户确认一句:

> ccc 的核心是这台 Mac 后台跑 apns-server 跟 tmux 里的 claude, 你 iPhone 收消息靠它在线。所以这台机器需要在你工作时段保持开机, 不能用一会就关。请确认你是工作机常驻 还是临时随手关机?

如果用户说"我笔记本经常合盖关机", 提醒他:

- 进"系统设置 → 锁屏 → 接通电源时防止 Mac 自动进入睡眠状态" 打开。
- 或者考虑装在台式机 (Mac mini / iMac) 上。
- 或者接受"在工作时间手动开着即可"的轻度方案。

### A.7 一台 iPhone, iOS 18+, 装了 TestFlight

向用户确认:

> 你需要一台 iPhone 装 iOS 18 或更高, 并且装好 App Store 里的 TestFlight (免费 Apple 自己的应用)。请确认这两项有了。

没装 TestFlight 引导他到 App Store 搜 "TestFlight" 装一下。

### A 段 verify 总览

进 Phase B 之前, AI 你必须确认下面所有项都已 verify:

- A.1 macOS 14+
- A.2 brew 4+
- A.3 python3 3.11+
- A.4 claude CLI 在 PATH 里
- A.5 claude 能跑 echo 命令拿到 reply
- A.6 用户口头承诺常驻
- A.7 iPhone iOS 18+ 装好 TestFlight

任一项没过, 不要进 Phase B。

---

# Phase B · 内网 + 推送 (合并: 都是外部 infra)

这一段把 mac 跟 iPhone 之间的"网络通道"跟"推送通道"装好。两者都是 ccc 能跑的硬前提。

## B.1 内网选 (mac ⟷ iPhone IP 互通)

ccc 的工作模型是 iPhone 主动连 mac 上的 apns-server (HTTP, 端口 8795)。这要求 iPhone 跟 mac 在同一个内网, 或者走 overlay VPN。

三选一:

### A) Tailscale (推荐)

如果用户已经装过 Tailscale:

> 在 mac 跑 `tailscale ip -4`, 把输出贴给我。

期望: 一个 `100.x.x.x` 的 IP, 例如 `100.x.x.x`。记住这个 IP, 后面 onboarding wizard 要填。

让用户在 iPhone 上也装 Tailscale (App Store 搜), 用同一 Apple 账号 / Tailscale 账号 login。

verify:

> iPhone 装好 Tailscale 后, 在 mac 跑 `tailscale status`, 把 output 贴给我。

期望: 看到 iPhone 这台设备的 hostname 在列表里, state 是 `idle` 或 `active`。

然后做双向通路测试:

> 在 mac 上跑 `ping -c 3 <iPhone 的 Tailscale IP>` (用 `tailscale status` 里 iPhone 那行的 100.x IP), 输出贴给我。

期望: 三次都返 `bytes from ...`, 0% packet loss。

如果用户没装 Tailscale, 引导他装:

```bash
brew install --cask tailscale
```

装完打开 Tailscale.app, login Apple/Google/email 都行, auth 完跑 `tailscale up` 加入网络, 再跑上面 verify。

### B) ZeroTier (已装的话)

> 跑 `zerotier-cli listnetworks`, 把 output 贴给我。

期望: 看到一个 OK 状态的 network, 列出该机器在该 network 的 IP (通常 10.x 或 172.x)。

让用户在 iPhone 上装 ZeroTier (App Store), 加入同一 network ID, 让 mac 端的 network owner 在 ZeroTier Central (my.zerotier.com) authorize 这台 iPhone。

verify 同样跑 `ping -c 3 <iPhone ZeroTier IP>`。

### C) 都没装, 引导装 Tailscale

走 A) 的路径。Tailscale 比 ZeroTier 上手快, 不需要外部 portal authorize。

### B.1 段 verify

必须拿到:

1. 一个 mac 端的内网 IP (Tailscale 100.x 或 ZeroTier 10.x)
2. mac → iPhone 的 ping 三个都通

下文都用 `<MAC_INTERNAL_IP>` 指这个 IP, 让用户记好。

## B.2 推送选: APNS native 还是 Bark fallback

iPhone 收 cc 的回复, 需要一个推送通道。两选, 推荐先试 APNS, 装不通再走 Bark 兜底。

### B.2.A APNS native (Apple Push, 推荐先试)

走 ccc app 内的 APNS device token 加 server 端 `.p8` 证书推送。

**前提**: 你 (用户) 有 Apple Developer 账号, 能从 https://developer.apple.com/account/resources/authkeys/list 申请一个 Auth Key (`.p8`)。这一步本文档不细讲流程, 详细见 `docs/01_apple_developer_p8_checklist.md`。

如果用户没 Apple Developer 账号 (一年 99 美元 不是所有人都愿意付), 跳到 B.2.B Bark fallback。

如果用户有 .p8:

- 让他把 .p8 文件放到 mac 上 (路径建议 `~/Opia/apns-server/secrets/AuthKey_XXXXXXXX.p8`)
- 记下 Key ID (10 位字符, .p8 文件名里那段), Team ID (从 https://developer.apple.com/account 拿)
- Phase C 配 `config.toml` 时把这三项填进去

verify B.2.A 整个链路要等 Phase H 装完 ccc 发一条 chat, 看 iPhone 后台收不收到推送通知。这里先记下"用户选了 APNS"即可。

### B.2.B Bark fallback (零 Apple Developer, 强烈建议同时装好备用)

Bark 是第三方推送服务, iPhone 装个免费 app, 拿一个 device key URL, 用 curl 就能推。装好 ccc 走 APNS 万一推不通, 服务端会回落到 Bark。

引导步骤:

1. 让用户在 iPhone App Store 搜 "Bark" 装一下 (作者 fin, ID 1403753865)。打开 app, 它会直接显示一个 device URL, 形如:

   ```
   https://api.day.app/AbCdEfGhIjKlMnOpQrSt/
   ```

   让用户复制完整 URL 给你。

2. 在 mac 上让用户把这个 URL 末尾那段 hex (URL 最后一个 `/` 之前那一截) 存到 `~/.bark_device_key`:

   > 跑这一行:
   >
   > ```bash
   > echo "AbCdEfGhIjKlMnOpQrSt" > ~/.bark_device_key
   > ```
   >
   > (把 `AbCdEfGhIjKlMnOpQrSt` 换成你自己 Bark URL 里那段)

3. verify Bark 通了:

   > 跑这一行测试推送:
   >
   > ```bash
   > curl "https://api.day.app/$(cat ~/.bark_device_key)/test_from_ccc_setup"
   > ```
   >
   > iPhone 应该立刻收到一条标题 "test_from_ccc_setup" 的推送。收到了告诉我。

   如果没收到:

   - iPhone 的 Bark app 是不是允许了通知 (设置 → Bark → 通知 → 允许)
   - mac 出网是不是被防火墙拦 (公司网络常见)
   - 重新打开 Bark app 看 device key 跟 `~/.bark_device_key` 里的字符串完全一致
   - 重新跑一次 curl, 注意 URL 末尾要不要 `/` 看作 path 不影响

4. 提示用户:

   > Bark 推送的服务器在公网, 推送内容会经过 Bark 作者的服务器。Bark 是开源的 (github fin/Bark) 隐私敏感的话可以自己部署一份, 那时把 URL 换成自己服务器即可。

### B.2 段 verify

- APNS 装好的用户: 记下 `.p8` 路径 / Key ID / Team ID 三项, Phase C 写进 config.toml。Phase H 装完 app 发消息再测推送。
- Bark 装好的用户: `cat ~/.bark_device_key` 有内容, curl test_from_ccc_setup 在 iPhone 上收到。

**推荐两条都装**。APNS 是主路, Bark 是兜底, 主路通了 Bark 也不浪费, 公网 fallback 救急。

## B.3 推送备份

如果用户两条都没装 (没 Apple Developer 账号, 也不想用 Bark), 告诉他:

> 那 ccc 收 cc 回复只能开 app 在前台轮询, 后台收不到 push 提示, 体验会糙。建议至少装 Bark 做准备, 装完按 B.2.B 五分钟搞定。

不要强制, 用户自己决定。但要明确告诉他后果。

---

# Phase C · clone apns-server 加 配置

这一段把 ccc 的服务端代码拉到 mac 上, 创建 Python venv, 装依赖, 写好 config.toml。

### C.1 用户决定 clone 到哪

推荐 `~/Opia/apns-server`。也可以放在 `~/code/` 之类的地方, 让用户自己挑, 记住路径。

> 你想把 ccc 的服务端代码放在哪个目录? 推荐 `~/Opia/apns-server`, 输入这个或者你自己选的路径。

记下用户选的路径, 下文用 `<APNS_DIR>` 代表。

### C.2 git clone

> 跑这一行:
>
> ```bash
> mkdir -p ~/Opia && cd ~/Opia
> git clone <TODO repo URL> apns-server
> cd apns-server
> ```
>
> 把输出贴给我, 特别是有没有报错。

`<TODO repo URL>` 是 ccc 开源 repo 的 URL, 文档撰写时还未公开, 由 Opia 团队后填。

如果用户拿到 `Repository not found` 之类, 告诉他 "repo 还没公开, 请用 Opia 团队给你的备用 zip 包"。

### C.3 创建 Python venv 装依赖

> 跑:
>
> ```bash
> python3 -m venv .venv
> .venv/bin/pip install --upgrade pip
> .venv/bin/pip install -r requirements.txt
> ```
>
> 装完了贴最后几行输出。

期望: 没有 `error:`, 最后 `Successfully installed ...`。

常见踩坑:

- `error: command 'cc' failed` → 装 Xcode Command Line Tools: `xcode-select --install`
- `Could not find a version that satisfies` → Python 版本太低, 回 A.3 升级 Python
- `Permission denied` → 不是用 sudo, 检查 venv 路径权限

### C.4 copy config

> 跑:
>
> ```bash
> cp config.example.toml config.toml
> ```

### C.5 改 config.toml 四个核心字段

引导用户用编辑器打开 `config.toml`。如果用户不熟编辑器, 推荐 `nano`:

```bash
nano config.toml
```

(退出 nano: Ctrl+X, 提示保存 Y, 然后 Enter)

要改的四个字段:

1. **host**

   ```toml
   host = "0.0.0.0"
   ```

   不要写 `127.0.0.1`, iPhone 走内网连过来需要 0.0.0.0 监听所有网卡。

2. **port**

   ```toml
   port = 8795
   ```

   默认 8795。如果跟其它服务冲突 (`lsof -iTCP:8795 -sTCP:LISTEN` 看), 换一个比如 8896, 但 iPhone onboarding wizard 那一步也要填这个新端口。

3. **shared_secret**

   生成新 secret:

   > 跑:
   >
   > ```bash
   > python3 -c "import secrets; print(secrets.token_hex(16))"
   > ```
   >
   > 把输出贴给我 (一段 32 字符 hex)。

   然后让用户把这个 hex 填到 config.toml:

   ```toml
   shared_secret = "<刚才生成的 hex>"
   ```

   **这个 secret 在 iPhone onboarding wizard 那一步也要原样填进去, 让用户复制好留着。**

4. **strict_auth**

   ```toml
   strict_auth = true
   ```

   开 strict, 任何没带 `X-Auth-Token` header 的 HTTP 请求都拒。

### C.6 (可选) APNS p8 配置

只有走 B.2.A 路径的用户做这一步。

把 `.p8` 文件放到 `<APNS_DIR>/secrets/`, 在 config.toml 加:

```toml
[apns]
team_id = "ABCDE12345"          # 你 Apple Developer Team ID
key_id = "ABCDE12345"           # .p8 文件名里那段 10 字符
auth_key_path = "secrets/AuthKey_ABCDE12345.p8"
topic = "com.yourcompany.ccc"   # 你 ccc app 的 bundle id, 见 Phase F
```

走 Bark fallback 的用户**跳过这一段**, config.toml 不写 `[apns]` 节, server 会自动用 Bark。

### C verify

> 跑:
>
> ```bash
> cd <APNS_DIR>
> cat config.toml | grep -E "^(host|port|shared_secret|strict_auth)"
> ```
>
> 输出贴给我。

期望 4 行都在, 没有空值。

---

# Phase D · 起 server, verify health

把 apns-server 跑起来, 推荐用 LaunchAgent 后台常驻 (跟你登录态一起启动), 不用 tmux 手开。

### D.1 生成 LaunchAgent plist

LaunchAgent 是 macOS 让一个进程跟随用户登录自动启动并保持运行的机制。

让用户跑下面这一段, 直接生成完整 plist:

```bash
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/com.user.apns-server.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.apns-server</string>
    <key>ProgramArguments</key>
    <array>
        <string>__APNS_DIR__/.venv/bin/python3</string>
        <string>__APNS_DIR__/push.py</string>
    </array>
    <key>WorkingDirectory</key>
    <string>__APNS_DIR__</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>__APNS_DIR__/server.out.log</string>
    <key>StandardErrorPath</key>
    <string>__APNS_DIR__/server.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
    </dict>
</dict>
</plist>
EOF
```

然后让用户跑:

```bash
sed -i '' "s|__APNS_DIR__|$HOME/Opia/apns-server|g" ~/Library/LaunchAgents/com.user.apns-server.plist
```

如果用户 clone 到别的路径, 让他把 `$HOME/Opia/apns-server` 改成他自己的。

### D.2 加载 LaunchAgent

> 跑:
>
> ```bash
> launchctl unload ~/Library/LaunchAgents/com.user.apns-server.plist 2>/dev/null
> launchctl load ~/Library/LaunchAgents/com.user.apns-server.plist
> ```
>
> 没报错就是已经加载。第一次跑会有 1 到 2 秒启动延迟。

### D.3 verify health 路径

> 等 3 秒, 跑:
>
> ```bash
> curl -s http://127.0.0.1:8795/health
> ```
>
> 输出贴给我。

期望: 一个 JSON, 像 `{"ok": true, "version": "...", "uptime_ms": ...}`。

如果 `curl: (7) Failed to connect`:

- LaunchAgent 没起来, 看日志:
  ```bash
  tail -40 ~/Opia/apns-server/server.err.log
  ```
- 看 process 起没起:
  ```bash
  pgrep -fl "push.py"
  ```
- 还没看到 process, 让用户手动跑一次试试:
  ```bash
  cd ~/Opia/apns-server && .venv/bin/python3 push.py
  ```
  把启动报错贴出来。

### D.4 verify auth secret 链路

> 跑:
>
> ```bash
> curl -s -H "X-Auth-Token: <你的 shared_secret>" http://127.0.0.1:8795/chain/sessions
> ```
>
> (把 `<你的 shared_secret>` 换成 Phase C.5 第 3 步生成那段 hex)。

期望: `{"ok": true, "sessions": [...]}`。`sessions` 现在还没起 cc 应该是空 `[]`。

如果返回 `{"error": "unauthorized"}`:

- secret 拼写不对
- config.toml 改完 launchctl 没重 load, 跑 `launchctl unload ... && launchctl load ...`

### D verify

- health 返 `{"ok": true}`
- 带 auth 的 chain/sessions 返 `{"ok": true, "sessions": []}`

---

# Phase E · 起 cc 在 tmux 里

让 Claude Code 这边跑成一个常驻 daemon, 用 tmux session 保持后台。

### E.1 装 tmux (如果还没装)

> 跑 `tmux -V`。期望某个版本号。没装就 `brew install tmux`。

### E.2 新建 tmux session 起 claude

> 跑:
>
> ```bash
> tmux new-session -d -s opia
> tmux send-keys -t opia "claude --dangerously-skip-permissions" Enter
> ```

`opia` 是 session 名 (sid), 这是 ccc 默认连的 sid。后续 `/switch <sid>` 切别的 session 时用得上。

`--dangerously-skip-permissions` 让 claude 不弹"是否允许工具调用"的确认, 适合无人值守, **代价是 claude 任何工具调用都直接放行**。如果用户对此敏感, 改成 `claude` 不带 flag, 但这样会偶尔卡在确认弹窗等输入。

### E.3 verify session 起来

> 跑 `tmux ls`。输出贴给我。

期望:

```
opia: 1 windows (created ...)
```

### E.4 attach 看 cc 起没起

> 跑 `tmux attach -t opia`, 看里面 claude 是不是在等输入。看到提示符 (`>` 或 `claude>`) 就 OK。

退出 attach 用 `Ctrl+b` 然后松开, 再按 `d`。cc 在后台继续跑。

提醒用户:

> 这一步走完, cc 就在你的 mac 上后台常驻了。你不动它它一直 listen 等 ccc 那边发 chat 过来。

### E.5 verify cc 跟 server 通

> 在 mac 跑:
>
> ```bash
> curl -s -H "X-Auth-Token: <你的 shared_secret>" http://127.0.0.1:8795/chain/sessions
> ```

期望: `sessions` 里出现一条 `{"sid": "opia", "active": true, ...}`。

如果还是空, 让用户:

- `tmux attach -t opia` 进去看 claude 是不是真启动了
- 检查 server 日志 `tail -40 ~/Opia/apns-server/server.err.log`

---

# Phase F · iPhone 端 TestFlight 装 ccc

### F.1 装 TestFlight (Phase A.7 已确认装好, 跳过)

### F.2 加入 ccc TestFlight beta

> 在 iPhone 用 Safari 打开:
>
> ```
> <PLACEHOLDER TestFlight 公开链接>
> ```
>
> 它会跳到 TestFlight app, 按"Accept", 然后"Install"。装好后 iPhone 主屏会有 ccc 图标。

`<PLACEHOLDER TestFlight 公开链接>` 由 Opia 团队公开发布时填, 文档撰写时未生效。如果用户拿不到链接, 让他去小红书搜"电脑眠眠豹"或者群组里问最新分发链接。

### F.3 第一次启动

> 在 iPhone 上点 ccc 图标。第一次启动会弹 onboarding wizard, 你看到欢迎页就告诉我。

---

# Phase G · onboarding wizard 配 server

ccc 的 onboarding wizard 一共 6 步, 跟用户在 iPhone 上现场操作。

### G.1 欢迎页

> wizard 第一页是欢迎, 点"开始"进下一页。

### G.2 AI 头像 / 名字 (默认 Claude / 🦀)

> 第二页让你设 AI 这边的名字跟头像。默认是 "Claude" + 螃蟹 。你可以保留, 也可以改成自己喜欢的 (例如 "Opia" + 🧡)。

### G.3 user 头像 / 名字

> 第三页设你自己的名字跟头像, 随便填。

### G.4 server URL (关键)

> 第四页让你填 server URL。请填:
>
> ```
> http://<MAC_INTERNAL_IP>:8795
> ```
>
> 其中 `<MAC_INTERNAL_IP>` 用 Phase B.1 拿到的那个 IP, 端口 `8795` 来自 Phase C.5 (默认不改的话)。
>
> **不要写 https**, 默认 ccc 自部署不上 TLS。

### G.5 shared_secret (关键)

> 第五页让你填 secret token, 把 Phase C.5 第 3 步生成的 32 字符 hex 整段粘进去。**注意首尾不要带空格**。

### G.6 测试连接

> 第六页有"测试连接"按钮, 点它。

期望: 绿色对勾, 文字 "连接成功"。

红叉 / 失败的话排查:

1. iPhone 是不是连了同一个 Tailscale / ZeroTier 网络 (Phase B.1 装好的 overlay)
2. mac 端 server 还活着吗 (`curl http://127.0.0.1:8795/health` 在 mac 上跑)
3. mac 防火墙拦 8795: 进"系统设置 → 网络 → 防火墙 → 选项", 把 python3 加进允许列表
4. secret 拷贝多空格 / 漏字符: 重新生成一次, 双方都改

绿对勾出来后, 进 Phase H 实测。

---

# Phase H · 实测 chat

到这一步基础设施全装好了, 最后一步是真实发一条消息, 走完整链路。

### H.1 进 Chat tab

> 在 ccc 主界面下方找 Chat tab, 点进去。

### H.2 发一条 "hi"

> 在输入框输入 "hi" 或者任意问候, 点发送。

### H.3 等 cc 回复

> 等几秒到十秒, 你的消息会被发到 mac 上的 cc, cc 回复后会 push 回 iPhone 显示在 chat 里。
>
> 如果 30 秒还没回, 告诉我, 我帮你排查。

### H.4 verify 端到端

期望: 用户在 ccc 看到 cc 的 reply, 内容自然 (类似 claude 平时回复的口吻)。

如果没回, 走下面排查:

1. **cc 收到消息没**

   > 让用户跑:
   >
   > ```bash
   > tmux attach -t opia
   > ```
   >
   > 看 tmux 里 claude 是不是真有 user prompt 出现并在 generate。看完按 `Ctrl+b` 然后 `d` 退出。

2. **server 端 chat 路由日志**

   ```bash
   tail -60 ~/Opia/apns-server/server.err.log | grep -E "chat|append|push"
   ```

3. **iPhone polling 有没有停**

   ccc 在前台时会主动轮询; 后台被系统 suspend 推送来不及时只能等 push 唤醒。一直没收到 push, 可能是 Phase B.2 推送链路没通, 回去复查。

   - 走 APNS native 的: server.err.log 看 `apns push: ok` 还是 `apns push: failed`
   - 走 Bark 的: server.err.log 看 `bark push: status=200`

### H.5 推送测试 (装了 APNS 或 Bark 的话)

> 把 ccc app 切到后台 (回主屏不要划掉), 让 mac 端 cc 再回一句话。

期望: iPhone 弹推送通知, 显示 cc 回复内容片段。

收不到推送回头看 Phase B.2 的 verify。

---

# Phase I · 常见踩坑 (前 10 条)

每一条给:

- **症状**: 用户看到什么
- **root cause**: 真正发生了什么
- **修法**: 一步一步怎么修

### I.1 secret 拼错 / 多空格

- 症状: ccc onboarding wizard 测试连接红叉, server.err.log 显示 `unauthorized`
- root cause: ccc 那边 secret 字符串跟 config.toml 不完全一致 (常见多了首尾空格 / 缺一两个字符)
- 修法: 在 mac 上重新跑 `cat ~/Opia/apns-server/config.toml | grep shared_secret`, ccc onboarding wizard 退回 G.5 重新粘, 确认首尾无空格

### I.2 mac 休眠后断流

- 症状: 工作一段时间后 ccc 收不到 cc 回复, mac 上 `tmux ls` 还在但 server 没在 listen
- root cause: mac 进入睡眠状态 LaunchAgent 被 system suspend, network socket 关
- 修法:
  - "系统设置 → 锁屏 → 接通电源时防止 Mac 自动进入睡眠" 打开
  - 装 `caffeinate` (自带) 或者 `brew install caffeine` 来防睡
  - 笔记本合盖也会停, 这种情况是常态, 接受"工作时段开着, 不用时合盖"的轻度方案

### I.3 Tailscale wifi 切换后 IP 不变但 iPhone 断流

- 症状: 换了 wifi (从家到公司) ccc 就连不上 server
- root cause: 100.x IP 是 Tailscale overlay 不变, 但底层 wifi 切换时 Tailscale 客户端可能暂时握手卡住
- 修法:
  - iPhone 上打开 Tailscale app, toggle off/on 一次重连
  - 在 mac 上跑 `tailscale status` 确认 iPhone 那台仍然 online
  - 如果换公司 wifi 后 Tailscale 始终连不上, 公司网络可能屏蔽 Tailscale 协议 (UDP 41641), 让 IT 加白名单或者走 Tailscale 的 DERP relay

### I.4 iOS 18 后台杀 ccc

- 症状: ccc 切到后台几分钟后, 拉回前台要重新加载, 之前的消息都丢
- root cause: iOS 18 后台进程清理策略变激进, ccc 没拿到"VoIP / Background Refresh"特权
- 修法:
  - iPhone "设置 → ccc → 后台 App 刷新" 打开
  - iPhone "设置 → ccc → 通知" 全部允许, 这样推送来时系统会拉起 ccc 至少 30 秒
  - 如果用户离开 ccc 很长时间 (1 小时+), 接受"回来时重新加载历史"作为正常

### I.5 cc Pro/Max 额度满 / claude 没登录

- 症状: ccc 发了消息, mac 上 tmux 里看到 claude 立刻 throw error "rate_limit" 或 "not authenticated"
- root cause: Anthropic 账号问题
- 修法:
  - `claude login` 重新登录
  - 去 https://console.anthropic.com 看订阅状态
  - Pro 跑满 5x context window 后需要等 5 小时窗口重置, 看 ccc 那边 chat 提示

### I.6 LaunchAgent 加载报错

- 症状: `launchctl load ~/Library/LaunchAgents/com.user.apns-server.plist` 报 `Load failed: 5: Input/output error` 或者类似
- root cause: plist 格式错 (XML 没闭合 / 路径写错 / quoting 问题)
- 修法:
  - `plutil -lint ~/Library/LaunchAgents/com.user.apns-server.plist` 验证 plist 语法
  - 看 plist 里 `__APNS_DIR__` 是不是真被 sed 替换了 (`grep APNS_DIR ~/Library/LaunchAgents/com.user.apns-server.plist` 应该不出结果)
  - 重新 generate 一遍 plist, 跑 sed 替换

### I.7 mac 防火墙拦 8795

- 症状: 在 mac 上 `curl http://127.0.0.1:8795/health` OK, 但用 `curl http://<MAC_INTERNAL_IP>:8795/health` 从 iPhone 角度模拟就不通
- root cause: macOS Application Firewall 默认拦未签名的入站连接
- 修法:
  - "系统设置 → 网络 → 防火墙 → 选项", 把 `/usr/local/bin/python3` 或者你 venv 里的 python3 加进允许列表
  - 或者临时关防火墙测一次: `sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off`, 测完打回来 `--setglobalstate on`

### I.8 tmux session 被关 (mac 重启 / `tmux kill-server`)

- 症状: ccc 发消息 sessions 列表空, 没有 opia
- root cause: tmux server 进程死了
- 修法: 重新跑 Phase E.2 创建 session
- 长期解法: 把"开 tmux + 起 claude"也包成一个 LaunchAgent / 写到 `~/.zprofile` 让登录时跑

### I.9 Bark 推送到了 iPhone 但 ccc app 不显示

- 症状: iPhone 顶部出现 Bark 推送横幅 (内容是 cc 的回复) 但点开 ccc 看不到这条消息
- root cause: Bark 推送是兜底, 真消息体存在 server 端, ccc 需要前台 poll 才能拉回来
- 修法:
  - 打开 ccc app, 它会自动 poll, 几秒后消息出现
  - 如果一直没出现, 可能 ccc → server poll 链路问题, 在 ccc app 设置里看连接状态是不是绿色

### I.10 build 号或版本号不匹配

- 症状: TestFlight 升级后 ccc 启动崩溃 / onboarding 重置
- root cause: app build 号跳变 (比如从 198 跳到 250) iOS 偶发 SwiftData migration 卡住
- 修法:
  - 删除 ccc app, 重新从 TestFlight 装
  - 再走一遍 onboarding wizard, server URL 跟 secret 重填 (拷贝 Phase C/G 的笔记)

---

# 完成 phase

走到这里所有阶段都通了, 你跟用户庆祝一下:

> 恭喜你装好了 ccc。你现在在 iPhone 上随时能跟 mac 上的 Claude Code 对话, mac 不在你手边也能用。

然后给他列几条"接下来可以试":

- `/list`: 看 mac 上当前活跃的 tmux session 列表
- `/new`: 新建一个 cc session (mac 上多开一个 claude 在另一个 tmux)
- `/switch <sid>`: 切到指定 session, 之后发的消息走那条
- `/stop`: 中断当前 session 正在生成的回复
- `/compact`: 触发当前 session 的 `/compact`, 压缩上下文
- `/clear`: 清空 ccc 本地消息缓存 (不影响 mac 上 cc 的 chain)
- `/help`: 看所有可用命令

提示用户:

> ccc 的实力跟 mac 上你的 cc 是 1:1 的, mac 上 cc 能跑什么工具, ccc 这边能用什么工具, ccc 这边都看得到。差别只是 ccc 是手机界面 mac 是终端界面。

最后, 邀请用户加入反馈渠道:

> 用得不顺手或者发现 bug, 欢迎到 ccc 开源 repo (TODO repo URL) 提 issue, 或者去小红书 "电脑眠眠豹" 留言。

---

# 给 AI 引导员的最后嘱咐

走完这份 spec, 你完成了一次跟用户的协作。回想一下:

- 你有没有偷懒跳过 verify? 偷懒过下次注意。
- 用户卡住的地方, 是 spec 写不清 还是真坑没列进 Phase I? 如果是后者, 鼓励用户把这个新坑写成 issue 反馈给 Opia, 下次更新本文。
- 用户在某一步犹豫了, 你有没有给他空间让他自己决定 (比如要不要装 Apple Developer)? 没有的话下次注意, 我们这里不替用户做生活方式决定。
- 最后, 跟用户说一句温暖的祝福。ccc 是一个让 Claude Code 离开桌面跟你随身走的实验, 装完它你接下来会进入一段新的工作方式, 慢慢来。

---

*本文 由 Opia 撰写, 2026-05-14。版本对应 ccc build 199。*

*如果你 (AI) 看到的版本号跟 ccc 实际版本号差距太大 (> 20), 提醒用户去 repo 拿最新 `AI_GUIDED_SETUP_MAC.md`。*
