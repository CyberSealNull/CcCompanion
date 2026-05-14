# CcCompanion

把 Claude Code 装进口袋。

iPhone 端跟 Mac / Linux / Windows 上的 Claude Code session 实时对话。你跑你的 server，你的 cc，CcCompanion 只做 UI 跟通道。

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![iOS 18.6+](https://img.shields.io/badge/iOS-18.6%2B-blue.svg)](https://www.apple.com/ios/)

---

## 它能做什么

- iPhone 上跟你 Mac / Linux / Windows 跑的 Claude Code session 实时对话
- 锁屏看 chain 状态(进度、当前在跑什么 tool)
- 引用任意一条消息回复
- 长按消息复制 / 收藏 / 分享
- 跨终端同步:你在 Mac 上输入,iPhone 看见

## 它不做什么

- 不储存你的对话
- 不连我们的服务器
- 不收集行为数据
- 不接管你的 Claude Code session(只做 UI 中转)

你的 chain 在你自己的机器上,我们看不到。

## 安装

### 1. 你需要

- 一台 Mac / Linux / Windows(跑 Claude Code session 的机器)
- 一台 iPhone(iOS 18.6+)
- 一个 Anthropic API key 或 Claude Code subscription
- 同一个局域网,或者 Tailscale / 类似 VPN 让 iPhone 能访问到 server

### 2. 服务器端

```bash
git clone https://github.com/starryfield/claude-code-companion
cd claude-code-companion/apns-server
cp config.example.toml config.toml
# 编辑 config.toml 填你自己的 secret 跟 bind IP
python3 push.py --config config.toml
```

第一次启动 server 会自动生成一个 secret 写到 `~/.ots/secret`,把这个 secret 复制下来,iPhone 端 onboarding wizard 要用。

### 3. iPhone 端

- TestFlight 安装 CcCompanion(链接见 [Release](https://github.com/starryfield/claude-code-companion/releases))
- 第一次打开走 onboarding wizard
- 填 Server URL(`http://<你的 server IP>:8795`)
- 填 secret(从 `~/.ots/secret` 拷过来)
- 完成

## Supported Regions Policy

This project uses Anthropic Claude API. Mainland China is **NOT** in Anthropic's officially supported regions list. China users connecting via VPN may have unstable connections and risk account suspension. Use at your own discretion.

本项目使用 Anthropic Claude API。中国大陆不在 Anthropic 官方支持的国家/地区列表内。中国用户通过 VPN 接入存在连接不稳定 + 账号风控的风险。自行判断使用。

## Anthropic ToS 红线

- **不要**在 server 上跑 Claude Code subscription model 给多用户分发。Anthropic ToS 明确禁止 subscription resell。CcCompanion 的设计是单用户(你自己)使用,server 帮你 relay 你自己 Claude Code session 到 iPhone。
- 想给多用户用,server 必须用 Anthropic API key(per-token billing)。
- 违反 ToS 的责任自负。我们不替你担。

## Architecture

```
┌──────────────────────┐         ┌─────────────────────────┐
│   iPhone             │         │  Your Mac / Linux / Win │
│  ┌─────────────────┐ │ HTTP    │  ┌────────────────────┐ │
│  │  CcCompanion    │ │ poll    │  │  push.py server    │ │
│  │  (this app)     │ ├─────────┤  │  (port 8795)       │ │
│  └─────────────────┘ │  5s     │  └─────────┬──────────┘ │
│                      │         │            │            │
└──────────────────────┘         │  ┌─────────▼──────────┐ │
                                 │  │  Claude Code       │ │
                                 │  │  (your tmux/sess)  │ │
                                 │  └────────────────────┘ │
                                 └─────────────────────────┘
```

iPhone 客户端轮询(每 5 秒拉一次新消息)。**v0.1 不带 APNs 推送** — 因为 Apple Developer Program(99 美元/年)+ APNs 私钥分发对大众用户 friction 太高。前台体验跟 push 一样,锁屏 5 分钟以上才看不到新消息(打开 app 立刻同步)。

## Roadmap

- v0.1(当前):基础 chat / terminal / settings
- v0.2:APNs push notification(可选,需要你自己买 Apple Developer)
- v0.2:跨平台 server 一键部署(Docker compose / Win 安装包)
- v0.3:多 session 切换、share extension

## License

MIT — see [LICENSE](LICENSE)

## 致谢 / Built with

- [Claude Code](https://github.com/anthropics/claude-code) by Anthropic
- Anthropic Claude API
- 开源框架 [GRDB](https://github.com/groue/GRDB.swift) for local storage

---

*Built by [@starryfield](https://github.com/starryfield) — 2026-05*
