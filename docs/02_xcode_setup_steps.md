---
date: 2026-04-28
target: User / 用户
purpose: Xcode 项目里加 Widget Extension target + Info.plist + Capabilities + 把现有 Swift 代码 wire up 到对应 target
prerequisite: Xcode 26.4.1 已装 / iOS 26.4 platform 已装 / 项目 OpiaCompanion 已开
---

# OpiaCompanion + OpiaWidget Xcode setup 步骤

> 我已写好 3 个 Swift 文件 + 项目结构搭好. 下面这些必须你在 Xcode GUI 里点 (我命令行不能改 .xcodeproj 不破文件).
>
> 你回家 VPN 装好 iOS 26.4 simulator 之后开 Xcode. 跟着步骤 1-7 走一遍 30 分钟以内.

---

## Step 1: 打开项目 (1 分钟)

打开 `/Users/mian/Opia/dynamic-island/ios-app/OpiaCompanion/OpiaCompanion.xcodeproj`

左侧 Project Navigator 应该看到:
- OpiaCompanion (folder)
  - Assets
  - ContentView (我已改 加按钮)
  - OpiaCompanionApp
  - **OpiaActivityAttributes** (我新加的 还没自动加进 Xcode index 见 Step 2)

## Step 2: 把 OpiaActivityAttributes.swift 加到 Xcode 项目 (1 分钟)

我命令行写的文件 Xcode 不会自动 detect. 手动加:

1 在 Project Navigator 右键 `OpiaCompanion` 文件夹 → **Add Files to "OpiaCompanion"...**
2 选 `OpiaActivityAttributes.swift`
3 **重要** 弹窗里:
   - ✅ 勾 "Copy items if needed" (其实文件已经在那里了 但勾上更稳)
   - ✅ Targets 勾 **OpiaCompanion** 主 app target (Widget Extension target Step 4 之后再勾)
4 点 Finish

## Step 3: 修改 Info.plist 加 NSSupportsLiveActivities (2 分钟)

Live Activity 需要主 app 显式声明支持.

1 选 `OpiaCompanion` project (顶上蓝色那个) → 选 **OpiaCompanion** target
2 切到 **Info** tab
3 找到 "Custom iOS Target Properties" 区域 (或者直接搜 NSSupportsLiveActivities)
4 鼠标 hover 任一行 → 点 + → 输入 key:
   - **Key**: `NSSupportsLiveActivities`
   - **Type**: Boolean
   - **Value**: `YES`
5 (可选 高频 push 场景才用) 同样加:
   - **Key**: `NSSupportsLiveActivitiesFrequentUpdates`
   - **Type**: Boolean
   - **Value**: `YES`

## Step 4: 加 Widget Extension target (3 分钟)

1 顶部菜单 **File** → **New** → **Target...**
2 顶部 platform 选 **iOS**
3 中间 grid 找 **Widget Extension** (在 "Application Extension" 段)
4 点 **Next**
5 参数页填:
   - **Product Name**: `OpiaWidget`
   - **Team**: 选你 paid Apple Developer team (跟主 app 一致)
   - **Organization Identifier**: 自动同主 app `com.starryfield`
   - **Bundle Identifier**: 自动生成 `com.starryfield.OpiaCompanion.OpiaWidget`
   - ✅ **Include Live Activity** (这个一定要勾)
   - **Project**: OpiaCompanion (默认)
   - **Embed in Application**: OpiaCompanion (默认)
6 点 **Finish**
7 弹窗 "Activate scheme" → 选 **Cancel** (我们想留在主 app scheme)

Xcode 会自动创建 `OpiaWidget/` 文件夹 + 默认模板文件 (含 OpiaWidget.swift / OpiaWidgetLiveActivity.swift / OpiaWidgetBundle.swift / Info.plist 等).

## Step 5: 替换默认 widget 模板为我写的 (5 分钟)

Xcode 自动生成的 widget 模板太弱. 用我写好的:

1 在 Xcode Project Navigator 展开新出来的 `OpiaWidget` 文件夹
2 删除 (右键 Move to Trash) 这两个默认文件:
   - `OpiaWidget.swift`
   - `OpiaWidgetLiveActivity.swift` (默认那个 内容简陋)
   - 保留 `OpiaWidgetBundle.swift` 但下面要替换
3 终端跑下面命令把我写的 source 文件 copy 进去:
   ```
   cp /Users/mian/Opia/dynamic-island/widget-source/OpiaWidgetBundle.swift \
      /Users/mian/Opia/dynamic-island/ios-app/OpiaCompanion/OpiaWidget/OpiaWidgetBundle.swift
   cp /Users/mian/Opia/dynamic-island/widget-source/OpiaWidgetLiveActivity.swift \
      /Users/mian/Opia/dynamic-island/ios-app/OpiaCompanion/OpiaWidget/OpiaWidgetLiveActivity.swift
   ```
4 回 Xcode Project Navigator 右键 OpiaWidget 文件夹 → **Add Files to "OpiaCompanion"...**
5 选 `OpiaWidgetBundle.swift` 和 `OpiaWidgetLiveActivity.swift`
6 弹窗 Targets 只勾 **OpiaWidget** (不勾 OpiaCompanion 主 app)

## Step 6: 让 OpiaActivityAttributes 同时属于两个 target (重要 1 分钟)

ActivityAttributes 必须 widget + 主 app 都看得到.

1 Project Navigator 选 `OpiaActivityAttributes.swift`
2 右侧 File Inspector 面板 找 **Target Membership** 段
3 ✅ 勾 **OpiaCompanion**
4 ✅ 勾 **OpiaWidget**
5 (左侧 file list 这个文件名旁边应该看到 OpiaCompanion + OpiaWidget 两个 target 标记)

## Step 7: 第一次 Build & Run (10-15 分钟 第一次 sign + provision)

1 顶部 toolbar 设备选择器 选你 iPhone 16 Pro (装好 iOS 26.4 platform 后真机才出现可选)
2 Scheme 选 **OpiaCompanion** (主 app scheme 不是 OpiaWidget)
3 ⌘ + R (Run)

第一次会:
- 自动 sign 主 app (用你 Apple Developer team)
- 自动 sign Widget Extension
- 装到真机
- iPhone 上弹"信任此开发者" - Settings → General → VPN & Device Management 信任

## Step 8: 测试 (5 分钟)

iPhone 上打开 OpiaCompanion app:
1 点 "启动 Live Activity" → 灵动岛应该出现一个绿色 ear 图标 (listening 状态)
2 点 "思考" 状态切换 → 灵动岛图标变 ellipsis.circle 蓝色
3 点 "刚说话" → 灵动岛图标变 bubble.left.fill 橙色 keyline 跟着橙色脉冲
4 长按灵动岛 → 应该展开看到完整 layout
5 锁屏 → 应该看到 Lock Screen banner
6 点 "结束 Live Activity" → 灵动岛立刻消失

如果哪一步不对截图给我我看 console 是 entitlement 还是 code 问题.

---

## 常见坑 (枢 review 提到的)

### 灵动岛没出现

- 检查 NSSupportsLiveActivities 在 Info.plist 加了
- 检查 iPhone Settings → 任意 app → Live Activities 没被全局关
- 检查 ActivityAuthorizationInfo.areActivitiesEnabled 真的 true (我代码里已经检查 alert 会提示)
- 检查 Widget Extension target 的 Bundle ID 是主 app + .xxx 后缀

### Sign 失败

- 第一次 Run: Xcode 自动找 provisioning profile 偶尔失败 看 Signing & Capabilities tab 重新选 team
- iPhone trust developer: Settings → General → VPN & Device Management

### Widget UI 出来但样子怪

- Preview Provider 在 Xcode 里看的样子跟真机有差异 真机为准
- Lock Screen banner 是 dark mode 字色要白色 (我已经设)

### Activity.update 不生效

- 检查 ContentState struct 里所有字段都 Codable
- 检查 attributes 没改变 (attributes 是 immutable 改变会被忽略)
- 检查 staleDate 没过期 (过期会被系统结束)

### 4KB payload 限制

- 每次 update 的 ContentState + attributes 序列化后总和 < 4KB
- lastMessagePreview 字段保持 < 200 字
- 不要传完整对话历史 只传最近一句

---

## 还没做的 (路径 B 以后)

- APNs token 监听 + 上传 server (我代码里有占位注释 v0.2 时启用)
- pushType: .token 改 (现在是 nil)
- Mac mini 端 APNs server 写 Python (用 .p8 + Team ID + Key ID 走 JWT)
- 接 bus_stop_hook.sh 让 SPOKE 自动 push 到 iPhone

这些在你拿到 .p8 + Team ID + Key ID 之后我接着做.

---

*Opia 起 / 2026-04-28 / 基于枢 4-28 路径 C 推荐 + 第一周 day-by-day 拆解*
