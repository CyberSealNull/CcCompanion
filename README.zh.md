# CcCompanion

> 把 **Claude Code** 装进口袋。开源 iOS 客户端 + 一个小 Python 推送服务。完全跑在你自己的 Mac 跟你自己的手机上。

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**跟 Anthropic 无关。** "Claude" 跟 "Claude Code" 是 Anthropic PBC 的商标。详见 [`DISCLAIMER.md`](DISCLAIMER.md).

English version: [README.md](README.md)

---

## 这是什么

CcCompanion 两块:

1. **`ios-app/`** — SwiftUI 写的 iOS app (TestFlight 公开, 后续上 App Store), 给你 chat / terminal / 斜杠命令三件套, 在 iPhone 上接你 Mac 那边的 Claude Code session, 走 overlay 网络任何地方都能用。
2. **`apns-server/`** — Mac 上跑的 Python HTTP 服务, 把你发的 chat 转给本地 `tmux` 里的 `claude`, 抓回复, 通过 Apple Push (或者 [Bark](https://github.com/Finb/Bark) 作零 Apple Developer 兜底) 推回你 iPhone。

整套是 **local-first** — 你的消息不过我们的 server, 因为根本没"我们的 server"。家里那台 Mac 跟你 iPhone 走 Tailscale / ZeroTier / LAN 直连。

## 它能做什么

- **Chat** — iPhone 发一句, Claude Code 回的话推回来。streaming, 历史, 搜索, 跳消息, 收藏, 附件 (图片 / 文件)。
- **Terminal** — 内嵌你 Mac 那边 `tmux` 跑 `claude` 的 session, 点开看 "claude 刚干了啥", 不用回去解锁 Mac。
- **斜杠命令** — `/new`, `/list`, `/switch <sid>`, `/stop`, `/compact`, `/clear`, `/help`. 多 session 跟随当前 active。
- **多 endpoint** — 一个 app 配多个 server URL (Tailscale `100.x` + LAN `10.x` + localhost), 自动 ping 切活的。换 wifi 自动跟。
- **Onboarding wizard** — 第一次启动 6 步走完 (server URL + secret + 头像 + 名字 + ping 测试)。
- **主题** — 浅色 / 深色 / 暖色, 可跟随系统。
- **隐私** — `config.toml` 跟 `.p8` 都 `.gitignore`-d, repo 只放 `config.example.toml` 模板。

## 你需要

- macOS 14 (Sonoma) 或更新, 装好 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 加 Anthropic Pro / Max 订阅。
- iPhone iOS 18+。
- Tailscale / ZeroTier / 或者 iPhone 跟 Mac 一个 LAN 段就行。
- 想走原生 APNs 推送需要 Apple Developer 账号 ($99/年), 不想买就走 [Bark](https://github.com/Finb/Bark), 一样能收 push 通知。
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

iOS 端 TestFlight 装: <https://testflight.apple.com/join/PLACEHOLDER> (v1.0 上线时填)。

## 架构

```
              ┌──────────────────────────┐
              │  iPhone 跑 ccc app       │
              └─────────────┬────────────┘
                            │  HTTPS poll + APNs push
                            │  (或者 Bark 兜底)
              ┌─────────────▼────────────┐
              │  Mac 跑 apns-server      │
              │  (Python HTTP 服务)      │
              └─────────────┬────────────┘
                            │  tmux send-keys / capture-pane
              ┌─────────────▼────────────┐
              │  tmux 里 session "opia"  │
              │  └ claude (CLI agent)    │
              └──────────────────────────┘
```

网络: app 跟 server 走 Tailscale / ZeroTier / LAN 通讯。默认 `config.toml` 绑 `127.0.0.1`, 你配好 overlay 网络 + auth secret 后再改 `0.0.0.0`。

## 仓库结构

```
CcCompanion/
├── README.md                    ← 英文版
├── README.zh.md                 ← 你正在看这一份
├── LICENSE                      ← MIT
├── DISCLAIMER.md                ← Anthropic 商标 disclaimer
├── .gitignore                   ← 不入 git 的清单 (secrets / logs / build / 用户数据)
├── ios-app/                     ← SwiftUI iOS app (Xcode 工程)
│   └── CcCompanion/           ← Xcode workspace 根; build scheme `CcCompanion`
├── apns-server/                 ← Python HTTP 服务
│   ├── push.py                  ← 兼容入口
│   ├── main.py                  ← 便捷入口
│   ├── server/                  ← HTTP handler、路由模块、运行时状态
│   ├── scripts/doctor.py        ← 本地体检脚本
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
| `push.py`          | 兼容入口，保留给已有 LaunchAgent 和旧文档命令。  |
| `server/main.py`   | server 启动、配置加载和 HTTP runtime。           |
| `server/handler.py` | 通用 HTTP handler：鉴权、JSON 响应和路由分发。  |
| `server/routes_*.py` | 按 chat、chain、tmux、push、misc 分组的端点实现。 |
| `apns_client.py`   | Apple Push HTTP/2 客户端加 JWT 鉴权。            |
| `chat_history.py`  | 消息日志 append-only + 搜索索引。                |
| `token_store.py`   | 写接口鉴权 shared-secret 存储。                   |
| `device_token_store.py` | iPhone APNs device token 持久化。            |
| `jwt_helper.py`    | `.p8` 转 JWT 签名器。                             |
| `task_queue.py`    | 后台任务池。                                     |
| `usage.py`         | Anthropic 用量探针 (可选)。                       |

其它模块 (`diary`, `favorites`, `group_chat`, `rp_history`, `studyroom`, `timeline`, `todos`, `worklog`, `reminders`, `calendar_store`, `pet_state`, `tts`, `settings`, `diary_stream`, `studyroom_indexer`) 是给私有客户端用的 endpoint, CcCompanion iOS app 不调它们。留在仓库里是因为删除它们会让 server import graph 散架。你想拿这套 server 接你自己的客户端那些 endpoint 也能用, 但没文档支持, 当实验性看。

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
- 在一台能被 iPhone 访问到的 Mac 上跑 `apns-server`, `config.toml` 填好。

## 常见问题

**问: 我的数据出 Mac 吗?**
答: chat 内容跟历史留在你 Mac 上。server 推 push 通知时 title / body 经过 Apple APNs (或者你选了 Bark 就经过 Bark relay)。chat **内容**不出机器, 只有通知预览过 Apple / Bark。

**问: 没 Apple Developer 账号能跑吗?**
答: 能。`config.toml` 的 `[apns]` 段不填, 装 [Bark](https://github.com/Finb/Bark) 走 push。Bark 免费, 开源, 跟着作者的 relay 跑 (或者你自己部署一份 Bark)。

**问: 8795 端口开到公网安全吗?**
答: 别。后边挂 Tailscale / ZeroTier / 反向代理上 HTTPS, 加 auth secret。默认 `config.toml` 是 `host = "127.0.0.1"` 是有道理的。

**问: 为啥 Xcode 工程在 `ios-app/CcCompanion/` 下?**
答: 这是 CcCompanion 的公开 Xcode 工程。scheme、工程目录和 bundle id 已统一到公开名称。

**问: 怎么更新?**
答: `git pull`, 然后重 build iOS app, Mac 端重启 `apns-server` LaunchAgent: `launchctl unload ~/Library/LaunchAgents/com.user.apns-server.plist && launchctl load ~/Library/LaunchAgents/com.user.apns-server.plist`。

## 贡献

issue + PR 都欢迎。我们特别想要的:

- Android 客户端 (跟 iOS endpoints 对齐, chat + terminal 流程平移过去)。
- 反向代理 + HTTPS 配方 (Caddy / Nginx / Traefik)。
- 更多语言 docs (这份 README 中英双版本, 但其它 docs 还偏英文)。
- `apns-server/` 里那批 CcCompanion 不用的 legacy 模块清理。

提 PR 之前请:

1. 跑 `xcodebuild -project ios-app/CcCompanion/CcCompanion.xcodeproj -scheme CcCompanion -configuration CcRelease -destination 'generic/platform=iOS' build` 必须 SUCCEEDED。
2. 跑 `python3 -m py_compile apns-server/*.py apns-server/server/*.py apns-server/scripts/*.py` 不能报错。
3. 安装服务端依赖后跑 `cd apns-server && .venv/bin/python scripts/doctor.py`。
4. secrets / `.p8` / `config.toml` / `tokens/` / `*.jsonl` 不能进 commit (`.gitignore` 已经挡了)。

## License

[MIT](LICENSE). 你想拿去干啥都行。如果它把你作业吃了那是你的事不是我们的。

## 致谢

- [Anthropic](https://www.anthropic.com) — Claude 跟 Claude Code。
- [Apple](https://www.apple.com) — APNs 跟 TestFlight。
- [Bark](https://github.com/Finb/Bark) — 极佳的零配置 push 兜底方案。
- 所有测过 TestFlight 早期版本跟提过 bug 的人。
