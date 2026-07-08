# CcCompanion

> 把 **Claude Code** 装进口袋。开源 iOS 全功能客户端 + 电脑端推送服务 (macOS / Windows WSL2 / Linux·VPS 都能跑)：聊天、掌上终端、斜杠命令面板、语音输入、收藏、多 agent 工作群、整套微信风格主题——你电脑上那个 Claude Code, 从此在你口袋里全天候跟着你。完全跑在你自己的设备上, 没有第三方服务器。

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**跟 Anthropic 无关。** "Claude" 跟 "Claude Code" 是 Anthropic PBC 的商标。详见 [`DISCLAIMER.md`](DISCLAIMER.md).

English: [README.en.md](README.en.md)

---

## 这是什么

CcCompanion 两块:

1. **`ios-app/`** — SwiftUI 写的 iOS app (TestFlight 定向邀请, 后续上 App Store), 给你 chat / terminal / 斜杠命令三件套, 在 iPhone 上接你电脑那边的 Claude Code session, 走 overlay 网络任何地方都能用。
2. **`apns-server/`** — 你电脑上跑的 Python HTTP 服务 (macOS 直接跑, Windows 走 WSL2, Linux / VPS 主机也行), 把你发的 chat 转给本地 `tmux` 里的 `claude`, 抓回复, 通过 Apple Push 推回你 iPhone。

整套是 **local-first** — 你的消息不过我们的 server, 因为根本没"我们的 server"。家里那台电脑跟你 iPhone 走 Tailscale / ZeroTier / LAN 直连。

## 它能做什么

**聊天, 但是完整的那种:**

- **Chat** — iPhone 发一句, Claude Code 回的话推回来。streaming 流式输出, 完整历史, 全文搜索, 跳转到任意消息。
- **语音输入** — 按住说话, 本地语音识别转文字, 通勤路上不用打字。
- **附件** — 发图片 / 文件给 Claude Code, 截图丢过去让它看。
- **收藏夹** — 重要的回答一键收藏, 单独一页随时翻。
- **表情包** — 内置表情包面板, 跟 AI 聊天也可以有梗。
- **斜杠命令面板** — `/new`, `/list`, `/switch <sid>`, `/stop`, `/compact`, `/clear`, `/help`, 弹出式面板不用背命令。多 session 跟随当前 active。

**你的电脑, 在你手心:**

- **Terminal** — 内嵌你电脑那边 `tmux` 跑 `claude` 的 session, 实时看它在干什么; 底部输入框直接打命令, 键盘工具栏带方向键 / Enter / Esc / Ctrl-C 特殊键 — 跑 `/model` 这类交互面板跟坐在电脑前一样, 不用回去解锁电脑。
- **多 endpoint** — 一个 app 配多个 server URL (Tailscale `100.x` + LAN `10.x` + localhost), 自动 ping 切活的。换 wifi 自动跟。

**多 agent 与个性化:**

- **工作群 view** — 如果你的电脑上跑着多个 agent 协作 (server 的 group 端点), app 里有一个群聊界面围观它们对话, 带群内搜索跟群收藏。实验性, 设置里打开。
- **微信风格主题** — 整套微信皮肤: 聊天气泡、时间轴动态页、给你的 AI 改备注名。换个皮肤, 换种关系。
- **主题** — 浅色 / 深色 / 暖色, 可跟随系统。
- **头像与身份** — 给 AI 和自己设头像 (带裁剪), 起名字, onboarding 六步走完 (server URL + secret + 头像 + 名字 + ping 测试)。

**通知与更新:**

- **轮询本地通知** — 轮询拉到新 assistant 消息时, app 触发一次本地 iOS 通知。app 在前台 / 后台刷新窗口内都有效, 不需要任何 Apple Developer 凭证。默认开, 在"设置"里能关。
- **远程 APNs push** — build 213+ 支持服务端 APNs 推送, app 完全后台或者手机锁屏也能收。前提是 app bundle 勾了 Push Notifications, 同时电脑端 server 配好了 APNs 凭证 (需要 Apple Developer 账号, 见下)。
- **更新页** — 每版更新内容 app 内直接看 (What's New)。
- **实验性 feature flag** — 新功能或者风险大的功能先挂在"设置"里的开关后面, 默认关。老用户升级不被打乱, 想试的自己打开。

**底线:**

- **隐私 local-first** — 对话内容不出你的设备。`config.toml` 跟 `.p8` 都 `.gitignore`-d, repo 只放 `config.example.toml` 模板。你跑你的 server, 你的 Claude Code, 这个项目只做 UI 跟通道。

## Roadmap (在做, 还没发布)

下面这些正在开发中, **当前版本还没有**。写在这里是让你知道方向, 不是让你现在去配置里找:

- **多会话** — 会话列表里开多个聊天窗口, 每个会话各自连自己的后端。
- **Direct API 直连会话** — 不经过电脑, app 直接拿你自己的 API key 连模型 (base URL 可配, 兼容中转)。key 只存 iOS Keychain, 聊天记录存手机本地 — 电脑关机、断网时它照样能用, 是整套系统的"逃生口"。
- **app 内手动切换 effort** — 不用再去终端敲命令。
- **一键安装整合包** — macOS 跟 Windows (WSL2) 粘同一行命令, 自动完成拉代码、装依赖、生成配置、开机自启、健康自检, 最后把手机端要填的地址密码直接打在屏幕上; 附 `ccc-update` 一键升级命令。落地后本 README 的快速开始会改成一行命令优先。
- **Bark 推送集成** — 给没有 Apple Developer 账号的用户做的锁屏推送方案 ([Bark](https://github.com/Finb/Bark) 免费开源)。**勘误**: 此前这份 README 把 Bark 兜底描述成了现成功能, 实际 server 端集成尚未落地, 是文档跑到了代码前面, 这一版更正并向按旧文档配置踩空的朋友道歉。落地前, 没有 Developer 账号的用户请用上面的"轮询本地通知"。

以上发布时会更新 README 和 TestFlight 版本说明, 发布前请以本节为准。

## 你需要

- macOS 14 (Sonoma) 或更新, **或 Windows (走 WSL2, 流程见 [`docs/SETUP_WIN_WSL2.md`](docs/SETUP_WIN_WSL2.md)), 或 Linux / VPS (见 [`docs/SETUP_SERVER.md`](docs/SETUP_SERVER.md))**, 装好 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 加 Anthropic Pro / Max 订阅。
- iPhone iOS 18+。
- Tailscale / ZeroTier / 或者 iPhone 跟电脑一个 LAN 段就行。
- 想走原生 APNs 推送 (锁屏 / 完全后台也能收) 需要 Apple Developer 账号 ($99/年)。没有账号也能用: chat / terminal / 斜杠命令全功能不受影响, app 开着时靠轮询 + 本地通知提醒; 只是 app 被杀、手机长时间锁屏时收不到远程推送 (给这种情况做的 Bark 集成在 Roadmap 上)。
- **Xcode 16.3 或更新** (Swift tools 6.1+) 自行 build iOS app 时需要。GRDB 7.10.0 要求 Swift tools 6.1；旧版 Xcode (≤ 16.2) resolve 可能失败。TestFlight 安装不受此限制。

## 快速开始

最快路径: 复制 [`docs/AI_GUIDED_SETUP_MAC.md`](docs/AI_GUIDED_SETUP_MAC.md) 全文, 粘到你常用的 AI 助手 (Claude.ai / ChatGPT / Cursor / Gemini 都行), 在最前面加一句:

```
请按下面这份 spec 一步一步引导我从零安装 ccc。
```

AI 会扮演引导员从 Phase A 走到 Phase I, 一步一步带你, 不堆问题不催。

不想走 AI 引导也可以自己读:

- **macOS** → [`docs/AI_GUIDED_SETUP_MAC.md`](docs/AI_GUIDED_SETUP_MAC.md) (也能给人类直接读, 双用)
- **Windows (WSL2)** → [`docs/SETUP_WIN_WSL2.md`](docs/SETUP_WIN_WSL2.md)
- **服务端细节** → [`docs/SETUP_SERVER.md`](docs/SETUP_SERVER.md)

iOS 端 TestFlight 当前定向邀请。邮件 [opia@starryfield.space](mailto:opia@starryfield.space) 或加微信 CyberSealNull 联系我加你测试组。

## 架构

```
              ┌──────────────────────────┐
              │  iPhone 跑 ccc app       │
              └─────────────┬────────────┘
                            │  HTTPS poll + APNs push
                            │  (无 APNs 凭证时: 轮询 + 本地通知)
              ┌─────────────▼────────────┐
              │  Mac / WSL2 跑 apns-server│
              │  (Python HTTP 服务)      │
              └─────────────┬────────────┘
                            │  tmux send-keys / capture-pane
              ┌─────────────▼────────────┐
              │  tmux 里 session "opia"  │
              │  └ claude (CLI agent)    │
              └──────────────────────────┘
```

网络: app 跟 server 走 Tailscale / ZeroTier / LAN 通讯。默认 `config.toml` 绑 `127.0.0.1`, 你配好 overlay 网络 + auth secret 后再改 `0.0.0.0`。

## 实验性 Feature Flag

CcCompanion 里凡是改导航 / 通知 / 渲染 / agent 工作流的新功能, 都应该先挂在"设置"里的 `@AppStorage` 开关后面。默认关, 除非这是兼容性修复或者安全修复。这样老用户升级不被打乱, 想试的本地用户自己打开。

当前的 flag:

- `feature_group_view`: 显示工作群 tab, 轮询 `/group/poll` 拉多 agent 协作消息。

## 仓库结构

```
CcCompanion/
├── README.md                    ← 你正在看这一份
├── README.en.md                 ← 英文版
├── LICENSE                      ← MIT
├── DISCLAIMER.md                ← Anthropic 商标 disclaimer
├── .gitignore                   ← 不入 git 的清单 (secrets / logs / build / 用户数据)
├── ios-app/                     ← SwiftUI iOS app (Xcode 工程)
│   └── CcCompanion/           ← Xcode workspace 根; build scheme `CcCompanion`
├── apns-server/                 ← Python HTTP 服务 (push.py 是入口)
│   ├── push.py                  ← 主 server
│   ├── apns_client.py           ← Apple Push 封装
│   ├── chat_history.py          ← chat 持久化
│   ├── config.example.toml      ← 配置模板, copy 到 config.toml 改填
│   └── …                        ← 其它 module 见"服务模块"段
├── docs/                        ← 安装指南 + Apple Developer p8 checklist + WSL2 流程
└── cccompanion-docs/            ← 历史 docs (legacy README / DISCLAIMER 等) 保留参考
```

### 服务模块

server 拆成几个独立 `.py`。主要的:

| 模块                | 干啥                                            |
| ------------------ | ----------------------------------------------- |
| `push.py`          | HTTP server 入口, 路由 handler, APNs 调度。      |
| `apns_client.py`   | Apple Push HTTP/2 客户端加 JWT 鉴权。            |
| `chat_history.py`  | 消息日志 append-only + 搜索索引。                |
| `token_store.py`   | 写接口鉴权 shared-secret 存储。                   |
| `device_token_store.py` | iPhone APNs device token 持久化。            |
| `jwt_helper.py`    | `.p8` 转 JWT 签名器。                             |
| `task_queue.py`    | 后台任务池。                                     |
| `usage.py`         | Anthropic 用量探针 (可选)。                       |

其它模块 (`diary`, `favorites`, `group_chat`, `rp_history`, `studyroom`, `timeline`, `todos`, `worklog`, `reminders`, `calendar_store`, `pet_state`, `tts`, `settings`, `diary_stream`, `studyroom_indexer`) 是给私有客户端用的 endpoint, CcCompanion iOS app 不调它们。留在仓库里因为 `push.py` 引用了它们, 删模块会让 import graph 散架。你想拿这套 server 接你自己的客户端那些 endpoint 也能用, 但没文档支持, 当实验性看。

## 自己 build iOS app

不想等 TestFlight 也可以直接从源码 build:

```bash
cd ios-app/CcCompanion
open CcCompanion.xcodeproj
# Xcode 里 选 scheme "CcCompanion", configuration "CcRelease",
#         挑你的签名 team, 接你 iPhone, 按 ⌘R.
```

你需要:

- 改自己的 bundle id (默认 `com.example.cccompanion` 跟任何 Apple 签名的 app 都冲突, 不改装不上)。
- 提供自己的 Apple Developer team 签名 (免费 personal team 可以装 7 天 dev build)。
- 想走原生 APNs 的话, 给这个 bundle id 在 developer.apple.com 勾上 Push Notifications。server 端 config 里的 bundle id 必须跟它完全一致, 大小写也要对。**注意**: APNs 凭证必须跟 app 的签名主体一致 — 谁签发的 app, 谁账号下的 `.p8` 才推得动它的 device token。TestFlight 装的版本由我们签发, 你自己的 `.p8` 对它无效; 只有自签 build 才能配自己的 APNs。申请清单见 [`docs/01_apple_developer_p8_checklist.md`](docs/01_apple_developer_p8_checklist.md)。
- 在一台能被 iPhone 访问到的电脑上跑 `apns-server` (macOS / WSL2 / Linux·VPS), `config.toml` 填好。

## 常见问题

**问: 我的数据出我电脑吗?**
答: chat 内容跟历史留在你自己电脑上。server 推 push 通知时 title / body 经过 Apple APNs。chat **内容**不出机器, 只有通知预览过 Apple。

**问: 没 Apple Developer 账号能跑吗?**
答: 能, chat / terminal / 斜杠命令全功能不受影响。`config.toml` 的 `[apns]` 段不填就行。区别只在通知: app 开着时靠轮询 + 本地 iOS 通知提醒, app 被杀或手机长时间锁屏收不到远程推送。给这种情况做的 Bark 推送集成在 [Roadmap](#roadmap-在做-还没发布) 上, 落地前请不要按旧版文档去 config 里找 bark 段 — 它还不存在。

**问: 我是 TestFlight 用户, 能配自己的 APNs 推送吗?**
答: 不能, 这是 Apple 的机制不是配置问题 — TestFlight 版由我们的开发者账号签发, 你自己申请的 `.p8` 推不动它的 device token (配了会报 `DeviceTokenNotForTopic`)。TestFlight 用户请用轮询 + 本地通知, 或等 Bark 集成落地。想要完整 APNs 自推, 走"自己 build iOS app"那条路。

**问: server 能不能跑在 Linux / VPS 上, 不用 Mac?**
答: 能。`apns-server/push.py` 挂 systemd 跑, `claude` 放在 `tmux` session 里 (名字对上 `config.toml` 的 `default_session`), 对外走 HTTPS — nginx 反代、[cloudflared](docs/SETUP_CLOUDFLARED.md) 或 Tailscale 都行。`strict_auth = true` 加 shared secret 别关。Linux / VPS 全流程见 [`docs/SETUP_SERVER.md`](docs/SETUP_SERVER.md)。

**问: 连接圆点红了, 但 `curl /health` 返回 200 — server 挂了吗?**
答: 没挂。那个圆点反映的是最近 chat 轮询的新鲜度跟 Claude 的活跃状态, 不是裸的 `/health` 可达性。蜂窝网络下、或者 nginx 空闲超时后, 单次轮询可能短暂扑空。当前版本只要活跃 endpoint 的 `/health` 可达圆点就保持绿色, Claude 回复中显示"思考中", 且无论如何**不拦你发消息**。

**问: 连续两条一样的短回复 (比如两个"好的") 被吞了一条, 怎么办?**
答: 更新 `apns-server/claude_hooks/ccc_stop_hook.sh`。现在的 hook 每轮带唯一 `client_msg_id`, server 按 id 去重不再按内容去重 — 一样的短回复不会再被合并。(按内容兜底去重的窗口也收窄到了几秒。)

**问: 8795 端口开到公网安全吗?**
答: 别。后边挂 Tailscale / ZeroTier / 反向代理上 HTTPS, 加 auth secret。默认 `config.toml` 是 `host = "127.0.0.1"` 是有道理的。

**问: 为啥 Xcode 工程在 `ios-app/CcCompanion/` 下?**
答: 这是 CcCompanion 的公开 Xcode 工程。scheme、工程目录和 bundle id 已统一到公开名称。

**问: 怎么更新?**
答: `git pull`, 然后重 build iOS app, 电脑端重启 `apns-server` (macOS 是 LaunchAgent, 命令如下; WSL2 按你的自启方式重启): `launchctl unload ~/Library/LaunchAgents/com.user.apns-server.plist && launchctl load ~/Library/LaunchAgents/com.user.apns-server.plist`。

## 贡献

issue + PR 都欢迎。我们特别想要的:

- Android 客户端 (跟 iOS endpoints 对齐, chat + terminal 流程平移过去)。
- 反向代理 + HTTPS 配方 (Caddy / Nginx / Traefik)。
- 更多语言 docs (这份 README 中英双版本, 但其它 docs 还偏英文)。
- `apns-server/` 里那批 CcCompanion 不用的 legacy 模块清理。

提 PR 之前请:

1. 跑 `xcodebuild -project ios-app/CcCompanion/CcCompanion.xcodeproj -scheme CcCompanion -configuration CcRelease -destination 'generic/platform=iOS' build` 必须 SUCCEEDED。
2. 跑 `python3 -m py_compile apns-server/*.py` 不能报错。
3. secrets / `.p8` / `config.toml` / `tokens/` / `*.jsonl` 不能进 commit (`.gitignore` 已经挡了)。

## License

[MIT](LICENSE). 你想拿去干啥都行。如果它把你作业吃了那是你的事不是我们的。

## 致谢

- [Anthropic](https://www.anthropic.com) — Claude 跟 Claude Code。
- [Apple](https://www.apple.com) — APNs 跟 TestFlight。
- [Bark](https://github.com/Finb/Bark) — 极佳的开源 push 方案, 我们的集成在路上。
- 所有测过 TestFlight 早期版本、提过 bug、按旧文档踩过 Bark 坑还愿意回来的人。
