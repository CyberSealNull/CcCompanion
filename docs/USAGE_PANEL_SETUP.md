# 订阅用量面板配置指南（Usage Panel Setup）

> Build 231+ 支持。配置完成后，ccc 设置页会多出一张「用量」卡片，显示你的 Claude Code 订阅用量：5 小时窗与 7 天窗各自用了多少、还有多久重置。

English version coming soon. 本文先以中文为准。

---

## 这是什么

Claude Code 的订阅是按时间窗限流的：一个 5 小时的滚动窗，一个 7 天的滚动窗。这两个窗用到多少、什么时候重置，平时藏在 CLI 的状态行里，不方便随时看。

配置用量面板后，ccc 设置页会显示两条进度条，分别对应 5 小时窗和 7 天窗，带百分比和重置倒计时。进度条会按用量染色：低于 60% 用主题色，60% 到 90% 转黄，达到或超过 90% 转红，方便你在长会话被限流打断之前就看到苗头。

数据来自一个跑在你自己机器上的小服务 [waterside0219/ai-usage-monitor](https://github.com/waterside0219/ai-usage-monitor)。它在本地读取 Claude Code 的用量状态，归一化成百分比和重置秒数返回给 ccc。**整条链路 local-first：你的凭据不出本机，ccc 只拿到归一化后的百分比、重置倒计时和状态标志，不碰任何 token。**

> ai-usage-monitor 本身也支持 OpenAI Codex 的用量，但 ccc 公开版的用量面板只渲染 Claude 订阅窗。

## 工作原理

```
Claude Code 的 statusLine capture 脚本
        │  (把订阅限流数据写到本地)
        ▼
~/.claude/rate_limits_latest.json   ← 5 小时窗 + 7 天窗的来源
        │
        ▼
ai-usage-monitor server (本机, 端口 8796)
   GET /usage  → 归一化成 ccusage.rate_limits.{five_hour, seven_day}
        │
        ▼
ccc 设置页「用量」卡片
   进区块时拉一次 (onAppear) + 右上角手动刷新, 不常驻轮询
   host 跟你配的 ccc 服务器走, 仅把端口换成 8796
```

四个环节缺一不可：statusLine 捕获脚本、跑起来的 ai-usage-monitor server（端口必须是 8796）、与 ccc 服务器一致的 shared secret、app build 231+。

## 配置步骤

### 第 1 步：装并跑 ai-usage-monitor

服务只用 Python 标准库（Python 3.9+），不需要 pip 依赖。

```bash
git clone https://github.com/waterside0219/ai-usage-monitor.git
cd ai-usage-monitor
python3 -m venv .venv
. .venv/bin/activate
# 绑定到所有网卡, 端口必须是 8796 (ccc 写死了用 8796),
# shared secret 用你 ccc 服务器同一个 (跟 /chat/append 用的是同一个 token)
python server/app.py --host 0.0.0.0 --port 8796 --shared-secret "你的-ccc-shared-secret"
```

**两个关键点：**

- **端口必须是 8796。** ccc 取你配置的服务器地址，只把端口换成 8796 去拉用量，所以这个服务要跟你的 ccc 服务器跑在同一台机器、同一个可达地址上，端口固定 8796。
- **shared secret 要跟 ccc 服务器一致。** ccc 拉用量时带的 `X-Auth-Token` 就是你在 ccc 里配的那个 shared secret，两边对不上会返回 401。

建议挂成后台常驻服务（launchd / systemd / tmux 都行），开机自起。

### 第 2 步：配置 Claude Code 的 statusLine 捕获

5 小时窗和 7 天窗的数据来自 Claude Code 的 status line。仓库自带 `scripts/claude_status_capture.py`，它从 stdin 读 Claude 传入的 JSON，抽出 `rate_limits` 写到 `~/.claude/rate_limits_latest.json`。

在 Claude Code 的配置里挂上这个脚本：

```json
{
  "statusLine": {
    "type": "command",
    "command": "/path/to/ai-usage-monitor/scripts/claude_status_capture.py",
    "refreshInterval": 5
  }
}
```

把 `/path/to/` 换成你实际 clone 的路径，并确保脚本可执行（`chmod +x`）。Claude 只在订阅窗有数据时才会暴露 rate limit，所以新窗口或用量极少时可能暂时拿不到。

### 第 3 步（推荐）：安装 ccusage

```bash
npm install -g ccusage
```

ccusage 提供 Claude Code 的当前活动块和可用性判断。订阅窗百分比主要靠第 2 步的捕获脚本，但装上 ccusage 能让服务更完整地判断「Claude 数据是否可用」。

### 第 4 步：更新 app 并打开面板

TestFlight 更新到 build 231 或更新版本，确保 ccc 的服务器地址已配好（跟用量服务同一台机器），然后进入设置页，往下找到「用量」卡片。

## 验证

1. 在跑 ai-usage-monitor 的机器上，本地直接探一下接口：

   ```bash
   curl -s "http://127.0.0.1:8796/usage" -H "X-Auth-Token: 你的-ccc-shared-secret" | head -c 400
   # 返回的 JSON 里应有 "ccusage": { ..., "rate_limits": { "five_hour": ..., "seven_day": ... } }
   ```

2. iPhone 上打开 ccc 设置页，进到「用量」卡片，应看到「CLAUDE 订阅」标题下两条进度条（5 小时窗 / 7 天窗），带百分比和「X天Yh 后刷新」之类的倒计时。
3. 点卡片右上角的刷新图标能手动重新拉取。
4. 数据偏旧时标题旁会出现「· 数据可能过期」，属正常，下次拉取会自愈。

## 已知限制

- **只展示 Claude 订阅窗。** 公开版面板只渲染 5 小时窗和 7 天窗两条进度条，不显示成本，也不显示 Codex。
- **数据存在你自己的机器上。** 用量数据来自本机的 Claude Code 状态文件，经由你自己跑的服务返回，不经过任何第三方。
- **不常驻轮询。** 设置页的面板只在进入时拉一次，加一个手动刷新按钮，为的是省电省请求；不是实时秒级更新。
- **新窗口可能暂时没数据。** Claude 只在订阅窗有数据时才暴露 rate limit，刚开新窗或用量极少时百分比可能为 0 或暂不可用。

## 故障排查

| 现象 | 排查 |
| --- | --- |
| 面板显示「需在你的服务器上配置用量服务」 | ccc 连不到用量服务。确认 ai-usage-monitor 跑着、端口是 **8796**、跟 ccc 服务器在同一台可达机器上 |
| 卡片在但进度条不出现，显示「Claude 订阅数据暂不可用」 | rate_limits 没数据。确认第 2 步的 statusLine 捕获脚本已挂、`~/.claude/rate_limits_latest.json` 有被写出 |
| 探接口返回 401 unauthorized | shared secret 跟 ccc 服务器不一致，两边要用同一个 token |
| 标题旁一直显示「· 数据可能过期」 | 源数据偏旧（ccusage 或捕获文件没及时更新），通常会自愈；长期不更新检查捕获脚本是否还在跑 |
| 百分比一直是 0% | Claude 还没暴露当前窗的 rate limit 数据，新窗口或用量太少时正常 |
| 点「查看配置指引 →」 | 链接指向本文档；按上面四步走即可 |

---

*用量面板基于开源项目 [waterside0219/ai-usage-monitor](https://github.com/waterside0219/ai-usage-monitor)。该项目为非官方工具，Claude、Claude Code 为其各自所有者的商标或产品，本面板只展示本机已登录用户可见的用量信息。*
