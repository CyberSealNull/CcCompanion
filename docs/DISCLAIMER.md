# OTS / ClaudeCodeCompanion 免责声明

> 本文档同时提供中英文版本。请在使用本框架前完整阅读。
> Last updated: 2026-05-09

---

## 中文版

### 1. 风险自负

OTS 框架（含 push.py server、iOS app、Mac 端集成、相关脚本与文档）按"现状"提供，不附带任何明示或暗示的担保，包括但不限于适销性、特定用途适用性、不侵权的担保。使用本框架带来的一切后果由使用者自行承担。

### 2. 与 Anthropic 无关联

本项目与 Anthropic 公司无任何官方关联、合作或背书。Claude、Claude Code、Claude API 是 Anthropic 的注册商标或商标。本框架仅是基于 Anthropic 公开提供的 Claude Code CLI 与 MCP 协议的第三方集成工具。

### 3. Anthropic 账号封禁风险

使用本框架可能改变 Claude Code 账号的访问模式，包括但不限于：

- 通过 HTTP server 与 tmux 注入将 iOS / 网页消息驱动到 Claude Code session
- 多个并发 Claude Code session 同账号同时运行
- 在 settings.json 加入 hook 脚本自动响应 tool use / Stop / UserPromptSubmit 事件
- 派活 / 自动化脚本通过 tmux send-keys 替代人工输入

**任何上述行为都可能被 Anthropic 服务端 abuse 检测系统识别为非人类自动化访问，触发 Anthropic [Consumer Terms §3](https://www.anthropic.com/legal/consumer-terms) 中关于"automated or non-human means"的条款，导致账号被限速、暂停或永久封禁。** 是否触发由 Anthropic 风控模型判定，本项目无法控制亦无法预测。账号被封后产生的订阅费损失、数据丢失、工作中断等任何损失，使用者自负。

### 4. 地区合规风险

Claude.ai 与 Claude Code 仅在 [Anthropic Supported Regions](https://www.anthropic.com/supported-countries) 中明确列出的国家/地区合法使用。中国大陆当前不在列。AUP 明确禁止"facilitate Claude/API access to users in violation of our Supported Regions Policy"。在不支持地区使用本框架（含通过 VPN / 代理 / 跨境网络）属于使用者个人行为，与本项目无关，由此导致的账号封禁、法律风险、合规风险由使用者自行承担。

### 5. 内容合规风险

通过本框架与 Claude 交互的所有内容必须遵守 [Anthropic Acceptable Use Policy](https://www.anthropic.com/legal/aup)，包括但不限于禁止生成 erotic chats、CSAM、暴力极端、政治操纵、欺诈、医疗法律金融未授权专业建议、敏感个人信息处理等。本项目不审核、不监控、不存储使用者的对话内容，但使用者使用本框架进行的任何违反 AUP 的行为，由使用者自行承担全部责任。

### 6. 服务端安全自负

本项目提供的 server (push.py) 默认绑定 0.0.0.0，提供 /chat、/tmux、/group 等可远程驱动 Claude Code 的端点。强烈建议：

- 设置 `strict_auth = true` 并使用强随机 shared secret
- 仅在受控网络（localhost、Tailscale、ZeroTier、家庭内网等）暴露端口
- 不要将 server 直接暴露到公网
- 定期 rotate shared secret

未按上述建议配置导致的远程入侵、prompt 注入、账号被滥用、数据泄露等损失，由使用者自负。

### 7. 不提供官方支持

本项目作为社区开源工具维护，不提供 SLA、不保证可用性、不保证向后兼容、不提供商业支持。issue / PR / 群内提问会尽力回复但不构成承诺。

### 8. 推荐使用方式

为降低风险，强烈建议：

1. 新装 Claude Code 后先正常人工使用 1-2 周建立 baseline
2. 不要使用 `claude --print` / launchd timer 等无人交互的 CLI 调用模式
3. 同账号常驻并发 Claude Code session 控制在 2 个以内
4. 高强度自动化任务使用 Anthropic API key（pay-as-you-go）而非 Pro/Max subscription
5. 在受 Anthropic 支持的地区合规使用
6. 对话内容遵守 AUP

---

## English Version

### 1. Use at Your Own Risk

The OTS framework (including push.py server, iOS app, Mac integration, scripts, and documentation) is provided "AS IS" without warranty of any kind, express or implied, including but not limited to warranties of merchantability, fitness for a particular purpose, and noninfringement. All consequences of using this framework are borne by the user.

### 2. Not Affiliated with Anthropic

This project has no official affiliation, partnership, or endorsement from Anthropic. Claude, Claude Code, and Claude API are trademarks of Anthropic. This framework is a third-party integration built on Anthropic's publicly available Claude Code CLI and MCP protocol.

### 3. Anthropic Account Suspension Risk

Use of this framework may alter the access pattern of your Claude Code account, including but not limited to:

- Driving Claude Code sessions via HTTP server and tmux injection from iOS or web messages
- Running multiple concurrent Claude Code sessions on the same account
- Configuring settings.json hooks to auto-respond to tool use / Stop / UserPromptSubmit events
- Automated dispatch scripts that replace human input via tmux send-keys

**Any of the above behaviors may be flagged by Anthropic's server-side abuse detection as automated or non-human access, triggering [Consumer Terms §3](https://www.anthropic.com/legal/consumer-terms) clause prohibiting "automated or non-human means" of access, and resulting in account throttling, suspension, or permanent termination.** Whether triggering occurs is determined by Anthropic's risk model and is outside this project's control. Subscription fees, data loss, work disruption, or any other loss following account suspension are the user's responsibility.

### 4. Regional Compliance Risk

Claude.ai and Claude Code are only authorized for use in countries/regions explicitly listed in [Anthropic Supported Regions](https://www.anthropic.com/supported-countries). The AUP explicitly prohibits "facilitating Claude/API access to users in violation of our Supported Regions Policy." Use of this framework in unsupported regions (including via VPN, proxy, or cross-border networking) is the user's individual responsibility, and any resulting account suspension, legal risk, or compliance risk is borne by the user.

### 5. Content Compliance Risk

All content interacted with through this framework must comply with [Anthropic's Acceptable Use Policy](https://www.anthropic.com/legal/aup), including but not limited to prohibitions on erotic chats, CSAM, violent extremism, political manipulation, fraud, unauthorized professional advice in medical/legal/financial contexts, and unauthorized handling of sensitive personal information. This project does not review, monitor, or store user conversation content, but any AUP violation by the user is the user's full responsibility.

### 6. Server Security at User's Risk

The server (push.py) provided binds to 0.0.0.0 by default and exposes /chat, /tmux, /group, and other endpoints capable of remotely driving Claude Code. Strong recommendations:

- Set `strict_auth = true` with a strong random shared secret
- Only expose the server within a controlled network (localhost, Tailscale, ZeroTier, home LAN, etc.)
- Do not expose the server directly to the public internet
- Rotate the shared secret periodically

Remote intrusion, prompt injection, account abuse, or data leakage caused by misconfiguration is the user's responsibility.

### 7. No Official Support

This project is maintained as a community open-source tool with no SLA, no availability guarantee, no backward compatibility guarantee, and no commercial support. Issues, PRs, and group questions will be addressed best-effort but do not constitute a commitment.

### 8. Recommended Usage

To reduce risk, strongly recommended:

1. After installing Claude Code, use it normally for 1-2 weeks to establish a baseline before deploying this framework
2. Do not use `claude --print` / launchd timer-based headless CLI invocations
3. Limit persistent concurrent Claude Code sessions on the same account to 2 or fewer
4. Use Anthropic API key (pay-as-you-go) for high-intensity automation instead of Pro/Max subscription
5. Use in Anthropic-supported regions in compliance with their policy
6. Ensure all conversation content complies with the AUP

---

*By using this framework you acknowledge that you have read, understood, and agreed to all terms above.*
*使用本框架即表示你已阅读、理解并同意上述全部条款。*
