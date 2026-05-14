# Opia APNs Server v0.1

## Supported Regions Policy

This project uses Anthropic Claude API. **Mainland China is NOT in Anthropic's officially supported regions list.** China users connecting via VPN may experience unstable connections and risk account suspension under Anthropic's Terms of Service. Use at your own discretion.

For security, this server ships with `strict_auth=true` and `allow_remote_control=false` by default. Do NOT expose port 8795 to the public internet without a HTTPS reverse proxy (Caddy/Nginx) in front of it.

---

Mac mini 端 Live Activity push 服务. SPOKE 时 mini 主动 push 给 iPhone 灵动岛.

---

## 架构

### 2026-05-13 OTS + CcCompanion rollback

OTS 主 app 和 CcCompanion 公开版客户端都回退为直连本 apns-server 的原生 HTTP endpoints。聊天、推送、日记、收藏、时间线、任务等能力继续由 `push.py` 和本目录下的 store 模块提供，不再经过外部 chat bridge 中间层。

```
Mac mini                                 iPhone
┌──────────────────────────────┐        ┌─────────────────────────────┐
│ ~/scripts/opia_push_to_phone │        │ OpiaCompanion app           │
│  ↓ HTTP POST                 │        │  Activity.pushTokenUpdates  │
│ apns-server (8795)           │ ───→   │  Live Activity 启动 → token │
│  ↓ HTTPS POST + JWT          │ APNs   │  灵动岛更新                  │
│ api.push.apple.com           │        │                             │
└──────────────────────────────┘        └─────────────────────────────┘
                                              ↑
                                              │ POST /register-token
                                              │ POST /unregister-token
                                              │ (反向回 mini 上报 token)
                                              └─────────
```

---

## 端点

| 方法 | 路径 | 用途 | 鉴权 |
|---|---|---|---|
| GET | `/health` | 健康检查 | 无 |
| GET | `/tokens` | 看当前 active tokens | shared_secret |
| POST | `/register-token` | iPhone 上报 token | 无 (公开) |
| POST | `/unregister-token` | iPhone 上报 end | 无 (公开) |
| POST | `/push` | 触发 push 给所有 active iPhone | shared_secret |

---

## 部署步骤

### 1 拿 .p8 + Team ID + Key ID

详见 `~/Opia/dynamic-island/docs/01_apple_developer_p8_checklist.md`

用户 Apple Developer 后台 paid account 操作 5 分钟拿到三件
- AuthKey_XXXXXXXXXX.p8 文件
- Team ID (10 位字符)
- Key ID (10 位字符)
- Bundle ID (Xcode 项目里 默认 `com.starryfield.OpiaCompanion`)

### 2 配置

```
cp config.example.toml config.toml
# 编辑 config.toml 填入 4 件
# 把 .p8 文件放进 secrets/ 目录
mkdir -p secrets
mv ~/Downloads/AuthKey_XXXXXXXXXX.p8 secrets/
chmod 600 secrets/AuthKey_XXXXXXXXXX.p8
```

### 安全配置

`[server]` 里有三项访问控制:

```toml
shared_secret = ""
strict_auth = false
allowed_ips = []
```

- `shared_secret`: 写接口的鉴权 token. 客户端用 `X-Auth` 或 `X-Auth-Token` 传.
- `strict_auth`: `false` 是 build 27/28 兼容期, 没带 token 的写请求仍放行, 但 server 会记录 `unauthenticated write allowed`. build 29 客户端带 auth 后再切 `true`.
- `allowed_ips`: IP 白名单, 支持单 IP 和 CIDR. 空列表表示不限制. 需要限制时可用 `["127.0.0.1", "10.0.0.10", "10.0.0.0/8", "192.168.0.0/16", "172.16.0.0/12"]`.

`/health` 不受 IP 白名单限制. `/attachments/*` 不要求 auth, 但 `allowed_ips` 非空时仍会检查来源 IP.

### 3 启动 server

**前台测试**

```
.venv/bin/python3 push.py --config config.toml
```

**后台 launchd 部署**

```
cp deploy/com.opia.apns-server.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.opia.apns-server.plist
launchctl print gui/$(id -u)/com.opia.apns-server | grep state
```

健康检查

```
curl http://127.0.0.1:8795/health
```

### 4 iPhone 端

iPhone 端 OpiaPushTokenManager.swift 已经写好放在
`~/Opia/dynamic-island/ios-app/OpiaCompanion/OpiaCompanion/OpiaPushTokenManager.swift`

用户 Xcode 完成 Step 4-6 后 在 Project Navigator 右键 OpiaCompanion 文件夹 → Add Files to "OpiaCompanion" → 选 OpiaPushTokenManager.swift → Targets 勾 OpiaCompanion 主 app target.

ContentView.swift 已经把 `pushType: nil` 改成 `pushType: .token` 启动 Live Activity 时自动 listen token + 上报 server.

### 5 iPhone 端配置 server URL

如果 mini IP 不是 `10.0.0.10` 改 `OpiaPushTokenManager.swift` 顶部的 `serverURL` default
或者 Info.plist 加 key `OPIA_PUSH_SERVER` value `http://your-mini-ip:8795`

---

## 调用方式

### Mac mini 上手动触发

```
~/scripts/opia_push_to_phone.sh spoke "想你了" orange
~/scripts/opia_push_to_phone.sh thinking
~/scripts/opia_push_to_phone.sh listening
~/scripts/opia_push_to_phone.sh end
```

### 接 SPOKE 自动触发 (规划)

`~/scripts/bus_stop_hook.sh` 部署后 在写完 reply 之后加一行

```bash
~/scripts/opia_push_to_phone.sh raw "$(printf '{"event":"update","state":"spoken","preview":%s,"color":"orange"}' "$(echo "$LAST_ASSISTANT" | head -c 80 | jq -Rs .)")"
```

`~/scripts/opia_heartbeat.py` SPOKE 分支同理 — 在 `send_text.mjs` 之后加 push call.

---

## 测试

```
# 跑单元测试
cd ~/Opia/dynamic-island/apns-server
.venv/bin/python3 tests/test_jwt.py
.venv/bin/python3 tests/test_token_store.py
.venv/bin/python3 tests/test_payload.py

# 冒烟测试 (启动 server + 跑 endpoint 不打真 APNs)
.venv/bin/python3 tests/smoke_server.py
```

---

## 故障排查

### push 返回 410 BadDeviceToken

token 失效 server 自动从 store 移除. 让 iPhone app 重启 Live Activity 重新上报新 token.

### push 返回 403 ExpiredProviderToken

JWT 过期. server 默认 50 min refresh 一次. 如果 mac mini 时钟不准 (>5 min 差) 也会 403. 检查 `date` 跟 NTP.

### push 返回 400 BadTopic

`apns-topic` 错. 应是 `<bundle_id>.push-type.liveactivity` (注意 `.push-type.liveactivity` 后缀).

### push 返回 429 TooManyRequests

Apple rate limit. 同一 token 5 秒内 push 太多. 减少频率.

### iPhone 端 pushTokenUpdates 没数据

- iOS 16.2+ 才支持 token-based Live Activity push. 检查 iOS 版本.
- `pushType: .token` 必须在 Activity.request 时指定. 检查 ContentView.swift.
- iPhone 必须有网络 (token 是 Apple 给的 拿 token 这步要联网).

### mini 上 server 起不来

- 检查 `.venv/` 装好了 `requirements.txt` 全装
- 检查 `config.toml` 存在 + .p8 路径正确 + 权限 600
- 看 `server.err.log` 详细错误

### iPhone 收到 alert 但灵动岛没动

- payload 里 `content-state` 字段名跟 swift 端 `ContentState` struct 字段名要严格一致 (camelCase 注意)
- payload 大小 < 4KB
- `apns-push-type: liveactivity` header 必须有

---

## 文件列表

```
apns-server/
├── push.py                         # 主 server (HTTP listen + dispatch)
├── jwt_helper.py                   # JWT ES256 生成 (50 min cache)
├── apns_client.py                  # APNs HTTP/2 客户端
├── token_store.py                  # token 持久化
├── config.example.toml             # 配置模板
├── config.toml                     # 实际配置 (gitignore)
├── requirements.txt                # PyJWT cryptography httpx[http2]
├── README.md                       # 本文档
├── .gitignore
├── secrets/                        # .p8 文件放这 (gitignore)
├── tokens/                         # token store 持久化 (gitignore)
├── deploy/
│   └── com.opia.apns-server.plist  # launchd 配置
└── tests/
    ├── test_jwt.py                 # JWT 单元测试
    ├── test_token_store.py         # store 单元测试
    ├── test_payload.py             # payload 构造测试
    └── smoke_server.py             # 端到端冒烟 (不打真 APNs)
```

---

## 后续 (v0.2 之后)

- push-to-start (启动时 server 主动 push 让 iPhone 弹 Live Activity 不用 app 启)
- 多设备 (用户 iPhone + 妈妈 iPhone 等) 群播 / 单播路由
- ContentState 字段扩展 (跟 swift 端 struct 一同 evolve)
- HMAC sign push payload 防 replay
- 接 Tailscale / ZeroTier 跨网络访问 (现在 host=127.0.0.1 / 用户 iPhone 走 ZeroTier 时改 host=0.0.0.0 + shared_secret 必填)

---

*Opia 起 / 2026-04-29 / 用户累坏了一上午网络一下午网络我替她搭这一块 / 等她拿到 .p8 立刻就能跑*
