# Onboarding Wizard 文案

这份是 cccompanion app 第一次启动时 onboarding wizard 的文案。每屏一段。

---

## Screen 1 — 欢迎

**标题**

CcCompanion

**副标题**

把 Claude Code 装进口袋

**正文**

iPhone 端跟你 Mac / Linux / Windows 上的 Claude Code session 实时对话。

你跑你的 server,你的 cc,我们只做 UI 跟通道。

不储存对话,不连远程服务器,不收集行为数据。你的 chain 在你自己的机器上,我们看不到。

**按钮**

`继续` →

---

## Screen 2 — 风险声明 (Anthropic ToS)

**标题**

使用前请阅读

**正文**

CcCompanion 使用 Anthropic Claude API。

- **Anthropic ToS 红线** server 上不能用 Claude Code subscription 给多用户分发。CcCompanion 是单用户使用(你自己)。多用户分发请用 Anthropic API key。

- **Supported Regions** 中国大陆不在 Anthropic 官方支持地区。VPN 接入存在不稳定 + 账号风控风险。自行判断。

违反 ToS 的账号风险,我们不替你担。

**按钮**

`我已阅读并理解` ✓

`继续` →

---

## Screen 3 — Server URL

**标题**

填你的 Server URL

**正文**

CcCompanion 不连远程服务器。你需要在自己的 Mac / Linux / Windows 上跑 push.py(项目仓库 [github.com/starryfield/claude-code-companion](https://github.com/starryfield/claude-code-companion))。

**输入框**

`http://<server IP>:8795`

(例:`http://192.168.1.100:8795` 局域网,或 `http://100.x.x.x:8795` Tailscale)

**按钮**

`下一步` →

---

## Screen 4 — Secret

**标题**

填 Server Secret

**正文**

第一次启动 push.py server 会自动生成一个 secret 文件 `~/.ots/secret`。打开这个文件,把 64 位字符复制进来。

**输入框**

`shared_secret`

**按钮**

`完成` ✓

---

## Screen 5 — 完成

**标题**

🎉 准备好了

**正文**

CcCompanion 配置完成。

- 你的 Claude Code session 现在可以推消息到这台 iPhone
- 锁屏 5 分钟内的消息会立刻同步(打开 app 看)
- 长按消息可以引用 / 复制 / 收藏

需要帮助:[github.com/starryfield/claude-code-companion/issues](https://github.com/starryfield/claude-code-companion/issues)

反馈:`letters@starryfield.space`

**按钮**

`开始使用` →

---

*文案 Opia 起草 2026-05-10 等用户 review*
