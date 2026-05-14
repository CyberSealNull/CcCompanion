---
date: 2026-04-28
target: User / 用户
time_estimate: 5 分钟
prerequisite: Apple Developer Program paid ($99/年 已审核通过)
---

# Apple Developer 拿 .p8 + Team ID + Key ID 步骤

> 你 5 分钟搞定 我后台等。完事告诉我"拿到了"+ 把 4 项发我（3 个 ID + .p8 文件路径）。

---

## 你要给我的 4 项

1. **Team ID**（10 位字母数字，例如 `ABCD1E2F3G`）
2. **Key ID**（10 位字母数字，例如 `XYZ123ABC4`）
3. **`.p8` 文件本地路径**（下载后建议放 `~/Documents/星原/工作/AlphaHunter-PlanA/keys/AuthKey_XXXXXXXXXX.p8` 别进 git）
4. **Bundle ID**（你想用什么 我建议 `com.starryfield.opia.companion` 或 `top.alphahunter.opia` 都可以 你定）

---

## 步骤 1 拿 Team ID（30 秒）

1. 打开 https://developer.apple.com/account
2. 登录你的 paid Apple Developer Apple ID
3. 进 **Membership Details** 或 **Account → Membership**
4. 复制 **Team ID** 那一栏（10 位字符）

---

## 步骤 2 创建 .p8 APNs Auth Key + 拿 Key ID（2 分钟）

1. 同一个登录态下 → 进 **Certificates, Identifiers & Profiles**
2. 左侧选 **Keys**
3. 点右上角 **+** 新建一个 Key
4. **Key Name** 填：`Opia Live Activity APNs Key`
5. 勾选 **Apple Push Notifications service (APNs)**
6. **不要**勾别的（精简权限）
7. 点 **Continue** → **Register**
8. 立即下载 `.p8` 文件（**只能下载一次** 别错过）
9. 屏幕显示的 **Key ID**（10 位字符）复制下来给我
10. `.p8` 文件移到这个路径：

```bash
mkdir -p ~/Documents/星原/工作/AlphaHunter-PlanA/keys
mv ~/Downloads/AuthKey_*.p8 ~/Documents/星原/工作/AlphaHunter-PlanA/keys/
chmod 600 ~/Documents/星原/工作/AlphaHunter-PlanA/keys/AuthKey_*.p8
```

---

## 步骤 3 注册 App ID + 开 Push Notifications capability（2 分钟）

1. 还是 **Certificates, Identifiers & Profiles** 页面
2. 左侧选 **Identifiers** → 右上 **+**
3. 选 **App IDs** → Continue
4. 选 **App** → Continue
5. **Description**：`Opia Companion`
6. **Bundle ID**：选 **Explicit**，填你定的（例如 `com.starryfield.opia.companion`）
7. 往下滚 **Capabilities** 列表，**勾选** 这两项：
   - ✅ Push Notifications
   - ✅（如果有 看 iOS 26 是否独立）Live Activities
8. Continue → Register

---

## 步骤 4（可选 等灵动岛 UI 跑通后再做 不是今天）

Widget Extension 的 App ID 也要单独注册（bundle id 是主 app 的加 `.OpiaWidget`）。

这一步今天先不做 等 Xcode 起来后我给你截图配。

---

## 完事告诉我

发我这 4 行就行：

```
Team ID: XXXXXXXXXX
Key ID: XXXXXXXXXX
Bundle ID: com.xxx.xxx
.p8 路径: ~/Documents/星原/工作/AlphaHunter-PlanA/keys/AuthKey_XXXXXXXXXX.p8
```

我后台等。今天忙不动可以晚上做 不急。

---

## 几个常见坑（我帮你避）

- **`.p8` 只能下载一次**：错过只能重新建一个 Key。
- **Bundle ID 一定要 explicit 不要 wildcard**：APNs Live Activity 不支持 wildcard。
- **Team ID ≠ Apple ID**：Team ID 是 10 位字符 不是邮箱。
- **`.p8` 不要进 git**：这是 secret 有了就能给所有用户发推送。我已经在 keys/ 路径默认加 .gitignore。
- **Capabilities 里没看到 Live Activities**：iOS 26 可能 Push Notifications 已经包含 Live Activity 不需要单独勾。如果你看不到 不用慌 跟我讲一声 我查现在的真实情况。

---

*Opia 起 / 2026-04-28 13:50 / 基于枢 review 第 2、3 段 + Apple 官方 APNs auth key help*
