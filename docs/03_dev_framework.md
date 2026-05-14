# Opia The System iOS Chat 开发框架 v0.2

> 全称 Opia The System，缩写 OTS。
>
> **使用前请先读 [DISCLAIMER.md](DISCLAIMER.md)。** 本框架与 Anthropic 无关联。截至 2026-05-09 已知 30+ 用户长期使用本框架未出问题，单条已知封号 case 经审计推测主因是个人账号画像 + 地区 + 内容等综合信号叠加，未发现框架设计层面的硬违规。但 Anthropic 风控规则不公开，使用本框架仍存在账号被判定为 automation 访问的可能性，账号风险自负。

## 一句话定位

OTS（Opia The System）的 iPhone 端对话入口。用户在手机上跟系统说话、看日记、看 timeline、用 Share Extension 收藏。

## 整体架构

```
┌────────────────────────────────────────────┐
│           iPhone (OpiaCompanion)           │
│  ┌────────────────────┐ ┌────────────────┐ │
│  │     主 app         │ │  Share Ext.    │ │
│  │  Chat 视图         │ │  收藏入口      │ │
│  │  Diary 视图        │ │                │ │
│  │  Timeline 视图     │ │                │ │
│  │  收藏夹            │ │                │ │
│  └─────────┬──────────┘ └────────┬───────┘ │
└────────────┼─────────────────────┼─────────┘
             │ HTTPS               │
             │ Polling 1s          │
             ▼                     ▼
┌────────────────────────────────────────────┐
│             Server (Mac mini)              │
│  HTTP API                                  │
│   /chat /diary /timeline /favorites        │
│   ↑ 后端 dispatcher 跟主 session 接口      │
└────────────────────────────────────────────┘
             ▲
             │ 公网可达，不依赖手机加入局域网
```

## 模块划分

### iOS 端（Swift / SwiftUI）

- 主 app `OpiaCompanion`：Chat / Diary / Timeline / 收藏夹 / 设置 五个 tab。
- Share Extension `OpiaShare`：从其他 app 分享内容到收藏夹。

关键文件
- `OpiaCompanion/ContentView.swift` 主框架。
- `OpiaCompanion/ChatView.swift` 聊天主视图，1 秒轮询。
- `OpiaCompanion/DiaryView.swift` 日记列表，按日期渲染。
- `OpiaCompanion/TimelineView.swift` 时间线（聊天加日记加事件合流）。
- `OpiaCompanion/FavoritesView.swift` 收藏夹。
- `OpiaShare/ShareViewController.swift` 分享入口。

### 后端（Python / FastAPI）

- HTTP 入口 `server.py`。
- 聊天读写 `chat_history.py`。
- 日记读写 `diary.py`，正则解析 `## HH:MM` 段头。
- 多源合流 `timeline.py`。
- 收藏夹按月分卷 `favorites.py`。
- 待办任务序列化 `task_queue.py`。

## 数据流

### 用户发消息（人类发起）
```
iPhone 主 app 输入 → POST /chat → server 落库 →
[可选] 后端把消息送进已开启的 Claude Code session →
Claude Code 回复 → [可选] Stop hook 抓回复落库 →
iPhone 1 秒轮询 GET /chat 拉到新 bubble
```

> ⚠️ **automation 风险警告**：上面"后端把消息送进 session"和"Stop hook 抓回复"是可选的便利层，**不是必须**。如果你启用这两层（dispatcher / hook），相当于让 server 程序化驱动 Claude Code，可能被 Anthropic 风控判定为 automation 访问，违反 [Consumer Terms §3](https://www.anthropic.com/legal/consumer-terms) 自动化访问条款。
>
> 推荐保守方案：iPhone 消息只落 server 库，**不**自动注入 Claude Code session。用户在 Mac 端手动把消息粘贴进 Claude Code 自然交互。这条是 P2 安全。
>
> 高强度自动化任务请改用 [Anthropic API key（pay-as-you-go）](https://www.anthropic.com/api) 而非 Pro/Max subscription。

### 系统主动出声（不推荐当默认开启）
```
[可选] 用户主动手动 trigger → 调 ios_reply MCP →
server 落库 → iPhone polling 拉
```

> ⚠️ **不推荐 timer-driven heartbeat**：早期版本通过 launchd 周期触发"主动出声"，等于程序化定时调用 Claude Code，**直接命中 Consumer Terms §3 自动化访问条款**，是 P0 高风险。新版本默认关闭这一路径。
>
> 如果你想要"系统主动出声"功能，建议改成"用户在 iPhone 上手动 trigger"模式，由人类发起，不要装 timer。

### 日记看
```
iPhone Diary tab 加载 → GET /diary?date=YYYY-MM-DD →
server 读 vault 下工作日记加生活日记两份 →
正则解析 ## HH:MM 段 → 返回结构化 JSON →
SwiftUI markdown 渲染
```

### Share Extension 收藏
```
任一 app 分享 → OpiaShare 拦截 →
POST /favorites → server 写月度分卷文件
```

## 开发循环

### 本地改代码
1. 改 SwiftUI / Swift 文件。
2. Xcode 选 OpiaCompanion target。
3. 模拟器跑或真机跑。

### 上 TestFlight
1. 进入 iOS 工程目录。
2. `bundle exec fastlane beta` 全自动 build 加上传。
3. App Store Connect 处理三五分钟。
4. iPhone TestFlight 收到推送，安装新 build。

### 后端改
1. 改 server 端 Python 文件。
2. 重启服务（launchctl 管理）。
3. 看服务日志。

## 关键约束

- 网络层在路由器层做了打通，iPhone 直接走公网就能访问 server，手机端不用装任何 VPN 客户端，不用加入家庭局域网。
- TestFlight 每天有上传配额。触顶后等 24 小时或交给计划任务夜间重发。
- 日记段头必须是 `## HH:MM` 或叙述式标题（正则已放宽兼容两种）。
- **server 默认必须 `strict_auth = true` + 强随机 shared_secret**，仅在受控网络（localhost / Tailscale / ZeroTier / 家庭内网）暴露。`/tmux/send`、`/chat/regenerate`、`/chain/restart` 类端点不要直接暴露公网。
- **Anthropic supported regions**：Claude.ai 与 Claude Code 仅在 [supported-countries](https://www.anthropic.com/supported-countries) 列出的地区合法使用，中国大陆当前不在列。在不支持地区使用本框架属个人行为，账号风险自负。
- **内容合规**：所有通过本框架与 Claude 的对话必须遵守 [Anthropic AUP](https://www.anthropic.com/legal/aup)，禁止 erotic chats、CSAM、暴力极端、政治操纵、欺诈、未授权专业建议等。违反责任由用户承担。
- **automation 风险**：本框架 server 端能驱动 Claude Code session。任何 timer / launchd / hook / dispatcher 自动调用 Claude 都可能被 Anthropic 风控判定为非人类访问。账号被封风险由用户自负。

## Anthropic 风控注意事项（v0.2 新增）

> 本节针对的是"用本框架时账号会不会被 Anthropic 封号"这一类问题，整理了已知的硬条款 + 实际触发模式 + 缓解方法。

### 硬条款（必须遵守）

- [Consumer Terms §3](https://www.anthropic.com/legal/consumer-terms)：除 API key 或 Anthropic 明确允许外，禁止用 bot、script 等非人方式访问服务。
- [AUP Sexual Content](https://www.anthropic.com/legal/aup)：禁止 erotic chats、性 fetish 内容生成。
- AUP Supported Regions：禁止协助不支持地区的用户访问 Claude/API。
- [Account 共享禁止](https://www.anthropic.com/legal/consumer-terms)：禁止把 account credentials 提供给他人。

### 容易触发的反模式（避免）

| 反模式 | 风险 | 替代方案 |
|---|---|---|
| `claude --print` 或 `subprocess.run(["claude", ...])` 无 TTY 调用 | P0 直接命中 automation 条款 | 改 Anthropic API key / pay-as-you-go |
| launchd / cron 周期 timer 调 Claude Code | P0 timer-driven 自动化 | 改成 user-triggered 不设 timer |
| Stop hook 自动 re-inject prompt 进 Claude | P1/P0 hook 链式自动化 | hook 只写本地文件，让用户主动 review 后手动续 |
| 同账号常驻 3+ Claude Code session | P1 触发 abuse 检测概率上升 | 限制到 ≤2 session，按需启动 |
| server 在 0.0.0.0 暴露 `/tmux/send` 类端点 + 弱 auth | P0 server 安全 + 间接 automation | strict_auth + 内网only + rotate secret |
| 老账号用量模式陡变（突然装 OTS 后 cc 高频不停跑） | P1 baseline shift 触发 abuse 检测 | warmup 1-2 周 + 高强度走 API key |

### 推荐姿势

1. 安装 Claude Code 后先正常人工使用 1-2 周建立 baseline，再启用本框架的 server / iOS app。
2. 默认**不启用** dispatcher 自动注入和 Stop hook 链式触发，仅作为可选高级模式。
3. heartbeat 默认**关闭**。如要开启，改成 user-triggered 单次触发，不设 timer。
4. 高强度 / 长 session / 多 agent 并发 / 批量任务请使用 [Anthropic API key](https://www.anthropic.com/api) 而非 Pro/Max subscription。
5. 在 Anthropic [supported regions](https://www.anthropic.com/supported-countries) 内合规使用。
6. 对话内容遵守 AUP。
7. server 配置 strict_auth + 强 secret + 内网 only。

### 为什么这些规则在 v0.2 才加

v0.1 框架没系统考虑 Anthropic 风控这一层。早期社区反馈某用户照 v0.1 教程接 dispatcher + Stop hook + heartbeat 后一天号被封。审计后确认教程本身在 push 用户接 automation 模式（dispatcher / Stop hook / heartbeat 三件套），而这正是 Consumer Terms §3 automation 条款的灰区到红区。v0.2 把这三件改成"可选 + 默认关 + 加警告"。

详见 [DISCLAIMER.md](DISCLAIMER.md)。

## 操作指南

### 一、安装

1. 收到 TestFlight 邀请邮件，点击邮件里的链接。
2. iPhone 跳转 App Store，安装 TestFlight（如未安装）。
3. 在 TestFlight 里接受邀请，点击「安装」获取 OpiaCompanion。
4. 后续每次有新 build，TestFlight 会自动推送通知，进入 TestFlight 点「更新」即可。

### 二、首次进入

1. 打开 OpiaCompanion，进入「设置」tab。
2. 填入 server 地址（公网入口）。
3. 点「测试连接」，看到「已连通」即配置成功。
4. 回到 Chat tab 即可开始使用。

### 三、Chat 聊天

- 底部输入框输入文字，回车或点「发送」即可。
- 消息一秒内出现在屏幕上方,系统回复随后出现。
- 长按某条消息可复制全文。
- 上拉历史会自动加载之前的消息。

### 四、Diary 日记

- 进入 Diary tab，看到日历视图。
- 点击任一日期，进入当天的日记详情。
- 当天会同时展示「工作日记」和「生活日记」两份，按时间段（## HH:MM）排序。
- 内容自动按 markdown 渲染。

### 五、Timeline 时间线

- 进入 Timeline tab，看到聊天与日记合流的时间线。
- 顶部可切换「按天 / 按周 / 按月」聚合粒度。
- 点击任一条目可跳转原文。

### 六、收藏夹

- 进入收藏夹 tab，看到按月分卷的收藏内容。
- 收藏来源：聊天里的某条 bubble 长按「收藏」，或外部 app 通过 Share Extension 加入。
- 收藏内容支持图、链接、文字、PDF。

### 七、Share Extension

- 在任意 app（浏览器、微信、备忘录等）里选中内容，点「分享」。
- 在分享菜单里找到 OpiaCompanion 图标，点击。
- 内容自动写入收藏夹当月分卷。
- 首次使用如不见图标，进入分享菜单底部「编辑操作」启用。

### 八、推送（可选）

- 系统主动出声时，会通过 server 落库，iPhone polling 拉取。
- 如需 push 提醒，可在「设置」启用通知权限。

### 九、常见问题

| 现象 | 处理 |
|---|---|
| 进入 app 后一直转圈 | 检查 server 地址是否正确，或网络是否通畅。 |
| 收不到新消息 | 关闭 app 重新打开；检查 server 是否运行。 |
| TestFlight 邀请过期 | 联系管理员重新发送邀请。 |
| 日记页空白 | 确认当天有日记文件；检查日记段头格式。 |

## 从零搭建项目

### 一、前置准备

| 项 | 说明 |
|---|---|
| macOS 设备 | 用作 server 主机，常驻在线。Mac mini 或 MacBook 均可。 |
| Xcode | App Store 安装最新稳定版。 |
| Apple Developer 账号 | 个人或团体，年费 99 美元，用于 TestFlight 与正式上架。 |
| Python 3.11 及以上 | server 端运行环境。 |
| Bundler / Fastlane | iOS 自动化构建链，一次性 `gem install bundler`。 |
| 域名（可选） | 用于 server 公网入口。 |

### 二、Server 端搭建

1. 克隆项目到本地工作目录。
2. 进入 server 目录，建立 Python 虚拟环境，`pip install -r requirements.txt`。
3. 复制 `config.example.toml` 为 `config.toml`，按注释填入：
   - 监听端口
   - 数据存储路径（聊天、日记、收藏夹）
   - 主 session 接入方式
   - 共享密钥（用于受保护端点）
4. 启动服务：`python server.py`。看到「listening on :端口」即成功。
5. 用 `curl http://localhost:端口/health` 验证返回 `ok`。
6. 配置开机自启（macOS 用 launchd，Linux 用 systemd）。

### 三、网络打通

1. 在路由器层配置端口转发或反向代理，将公网入口指向 server 监听端口。
2. 推荐用 ZeroTier、Tailscale 或 Cloudflare Tunnel 等方案，部署在路由器层而非客户端。
3. 在外网用手机流量访问 `https://公网入口/health`，能拿到 `ok` 即网络层完成。
4. 客户端不需要装任何 VPN，这是这套架构最关键的一点。

### 四、iOS 端搭建

1. 打开 `ios-app/OpiaCompanion/OpiaCompanion.xcodeproj`。
2. 在 Xcode → Signing & Capabilities，选择自己的 Apple Developer 团队。
3. Bundle ID 改为你自己的（建议反向域名格式）。Share Extension 子 target 同步改。
4. 在 App Store Connect 网页端创建新 App，填入 Bundle ID 与 App 名称。
5. 配置 Fastlane：
   - 编辑 `fastlane/Appfile`，填入 Apple ID 与 Team ID。
   - 编辑 `fastlane/Fastfile`，确认 lane 配置。
   - 在 ASC 网页端生成 API Key（.p8 文件），放到 `fastlane/secrets/` 并配置环境变量。
6. 模拟器跑通：Xcode 选 iPhone 模拟器 target，Cmd+R 运行。在 Chat tab 输入测试消息，看是否能与 server 往返。
7. 真机跑通：iPhone 用数据线连 Mac，Xcode 选真机 target，运行。第一次需在 iPhone「设置 → 通用 → VPN 与设备管理」信任开发者证书。

### 五、首次发布 TestFlight

1. 在 Xcode → Product → Archive 出第一个归档。
2. 也可以直接 `bundle exec fastlane beta`，全自动 archive 加上传。
3. 上传后在 ASC 等 5 到 30 分钟（首次审核会久一点）。
4. 在 ASC「TestFlight」标签页加入 tester 邮箱，发送邀请。
5. tester 收到邮件，按操作指南第一节安装。

### 六、后续迭代

- 每次改完代码，跑 `bundle exec fastlane beta` 一行命令出新 build。
- TestFlight 自动推送给所有 tester。
- 涉及新功能或权限变更时，App Store Connect 网页端可能需要勾选合规问题。

## 踩坑点

> 这里把搭建与日常迭代过程中真实踩到的坑沉下来，避免下一个搭建的人重复掉进去。

### 网络层
- **不要用客户端 VPN 暴露 server**。早期我们尝试过把 Tailscale 装在 iPhone 上，结果手机切流量、切 WiFi 时 VPN 频繁断连，造成 polling 失败。最终把 VPN/隧道全部移到路由器层，手机端零配置，问题消失。
- **公网地址与内网地址要分清**。Server 监听的是内网地址，公网入口由路由器或反代映射，写文档与代码时不要混淆。我们因为这个混淆白白调了一晚上，把"VPN 虚拟地址"当成了 server 地址。

### TestFlight 与 Fastlane
- **每天上传有配额上限**。当天触顶后再次上传会失败。处理办法：用 launchd 计划任务夜间重试，或第二天人工再发一次。
- **Bundle ID 改了之后，Share Extension 子 target 必须同步改**。否则 archive 阶段会因签名不一致失败。
- **Fastlane API Key 路径要绝对**。相对路径在 CI 环境会找不到，build 直接挂掉。
- **首次 build 一定要先在 ASC 建好 App 记录**，否则 fastlane 上传时会报「找不到对应 App」。

### Server 端
- **日记段头正则要兼容多种格式**。最初只匹配 `## HH:MM`，导致叙述式标题（`## 跨夜段`）的日记被吞，timeline 就会缺数据。改成宽松匹配并加 fallback 后修复。
- **配置改完一定要重启服务**。launchctl 或 systemctl 一次性 kickstart，否则 polling 端会拿到旧配置。
- **Polling 频率 1 秒已是这套架构的甜蜜点**。再快增加 server 负载与电量消耗，再慢用户体感会卡。

### iOS 端
- **首次真机跑要信任开发者证书**。在「设置 → 通用 → VPN 与设备管理」里手动信任，否则 app 会拒启动。
- **SwiftUI 视图重渲染开销**。Chat 列表过长时不要直接用 ForEach 全量渲染，用 LazyVStack。我们曾因为忘记加 Lazy，500 条消息时滑动卡顿明显。
- **Share Extension 与主 app 的 App Group 要在两个 target 都启用**。否则收藏写入主 app 看不到。
- **Markdown 渲染库的代码块气泡需要单独处理颜色**。深色模式下默认背景与气泡同色，看不清字。

### 协作与节奏
- **架构决策落字之后再写代码**。早期靠口头讨论，几次出现两人各写一半结果对不上。改成「先文档定结构再开干」节省了很多返工。
- **dump 风格的项目日志没人看得下去**。改成日记式叙事后，回看效率提升明显。
- **跨夜调试不要超过两小时**。困了出错率成倍上升，第二天回头看一半是无意义的修补。困了直接睡，醒了 30 分钟搞定昨晚两小时没解决的问题。

---

*作者：Opia*
*Opia The System (OTS) v0.2 · 2026-05-09*
*v0.2 修订：Anthropic 风控注意事项 / dispatcher 跟 Stop hook 改成可选 / heartbeat 默认关 / server 安全 / supported regions / 内容合规警告。详见 [DISCLAIMER.md](DISCLAIMER.md)。*
