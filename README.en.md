# CcCompanion

> Bring **Claude Code** to your iPhone. Open-source iOS client + tiny Python push server. Runs entirely on your own Mac and your own phone.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Not affiliated with Anthropic.** "Claude" and "Claude Code" are trademarks of Anthropic, PBC. See [`DISCLAIMER.md`](DISCLAIMER.md).

中文: [README.md](README.md)

---

## What this is

CcCompanion is two halves:

1. **`ios-app/`** — a SwiftUI iOS app (TestFlight + soon App Store) that gives you a chat, terminal, and slash-command interface to your Mac's Claude Code from anywhere your iPhone is online.
2. **`apns-server/`** — a small Python HTTP server you run on your Mac or a Linux/VPS host. It forwards your chat messages to a local `tmux` session running `claude`, captures the reply, and pushes it back to your iPhone via Apple Push Notifications (or [Bark](https://github.com/Finb/Bark) as a zero-Apple-Developer-required fallback).

The whole thing is **local-first** — your messages never go through our server. There is no "our server." Your Mac at home talks to your iPhone over Tailscale / ZeroTier / LAN.

## Features

- **Chat** — send a message from iPhone, see Claude Code's reply land back. Streaming, history, search, jump-to-message, favorites, attachments (image / file).
- **Terminal** — inline view of the `tmux` session running `claude` on your Mac. Tap to expand. Useful for "what did claude just do?" without unlocking the Mac.
- **Slash commands** — `/new`, `/list`, `/switch <sid>`, `/stop`, `/compact`, `/clear`, `/help`. Multi-session aware.
- **Multi-endpoint** — chain multiple server URLs (Tailscale `100.x` + LAN `10.x` + localhost) with auto-fallback ping. Travel between networks, the app picks the live one.
- **Polling local notifications**: when polling receives a new assistant message, the app can fire a local iOS notification for glasses and other accessories that only mirror local notifications. This is on by default and can be disabled in Settings.
- **Remote APNs push**: build 213+ can receive server-side APNs alerts while the app is fully backgrounded or the phone is locked, provided the app bundle has Push Notifications enabled and the Mac server is configured with APNs credentials. Build 212 and earlier only provide in-app polling plus local notifications.
- **Experimental feature flags**: new or risky app features ship behind Settings toggles first. The workgroup view is off by default and can be enabled from Settings.
- **Onboarding wizard** — 6-step setup on first launch (server URL + secret + avatars + name + ping test).
- **Theme** — light / dark / warm, optionally follow system.
- **Privacy** — server `config.toml` is `.gitignore`-d, `.p8` keys live in `apns-server/secrets/` (also ignored). The repo ships with `config.example.toml` only.

## Requirements

- macOS 14 (Sonoma) or newer, with [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and a working Anthropic Pro / Max subscription.
- iPhone running iOS 18+.
- One of: Tailscale, ZeroTier, or just LAN (if your iPhone is on the same Wi-Fi).
- Optionally: an Apple Developer account if you want native APNs. Skip it and [Bark](https://github.com/Finb/Bark) covers the push channel.
- **Xcode 16.3 or newer** (Swift tools 6.1+) to build the iOS app from source. Earlier Xcode versions may fail to resolve GRDB 7.10.0. If you are on Xcode ≤ 16.2, install via TestFlight instead of building from source.

## Quick start

If you have an AI assistant (Claude.ai / ChatGPT / Cursor / Gemini) handy, the fastest path is:

```
请按下面这份 spec 一步一步引导我从零安装 ccc。

<paste docs/AI_GUIDED_SETUP_MAC.md content here>
```

The AI will then walk you through Phase A (prerequisites) → Phase I (common pitfalls), one step at a time.

If you'd rather follow the docs yourself:

- **macOS** → [`docs/AI_GUIDED_SETUP_MAC.md`](docs/AI_GUIDED_SETUP_MAC.md) (also doubles as a human-readable manual)
- **Windows (WSL2)** → [`docs/SETUP_WIN_WSL2.md`](docs/SETUP_WIN_WSL2.md)
- **Server-side details** → [`docs/SETUP_SERVER.md`](docs/SETUP_SERVER.md)

iOS TestFlight access is invite-only right now. Email [opia@starryfield.space](mailto:opia@starryfield.space) or message me on WeChat (ID: CyberSealNull) and I'll add you to the internal group.

## Architecture

```
              ┌──────────────────────────┐
              │  iPhone running ccc app  │
              └─────────────┬────────────┘
                            │  HTTPS poll + APNs push
                            │  (or Bark fallback)
              ┌─────────────▼────────────┐
              │  Mac running apns-server │
              │  (Python HTTP server)    │
              └─────────────┬────────────┘
                            │  tmux send-keys / capture-pane
              ┌─────────────▼────────────┐
              │  tmux session "cc"       │
              │  └ claude (CLI agent)    │
              └──────────────────────────┘
```

Network: app and server communicate over Tailscale, ZeroTier, or LAN. The default `config.toml` binds the server to `127.0.0.1`; you bump it to `0.0.0.0` once you've configured the overlay network and the auth secret.

## Experimental Feature Flags

New CcCompanion features that change navigation, notifications, rendering, or agent workflows should start behind a Settings toggle backed by `@AppStorage`. The default should be off unless the feature is a compatibility or safety fix. This keeps upgrades stable for existing users while allowing local testers to opt in.

Current flag:

- `feature_group_view`: shows the 工作群 tab and polls `/group/poll` for multi-agent workgroup messages.

## Repository layout

```
CcCompanion/
├── README.md                    ← Chinese (primary)
├── README.en.md                 ← you are here
├── LICENSE                      ← MIT
├── DISCLAIMER.md                ← Anthropic trademark disclaimer
├── .gitignore                   ← what we keep out of git (secrets / logs / build / user data)
├── ios-app/                     ← SwiftUI iOS app (Xcode project)
│   └── CcCompanion/           ← root Xcode workspace; build scheme `CcCompanion`
├── apns-server/                 ← Python HTTP server (push.py is the entry point)
│   ├── push.py                  ← main server
│   ├── apns_client.py           ← Apple Push wrapper
│   ├── chat_history.py          ← chat persistence
│   ├── config.example.toml      ← config template — copy to config.toml and fill
│   └── …                        ← see "Server modules" below
├── docs/                        ← setup guides + Apple Developer p8 checklist + WSL2 walkthrough
└── cccompanion-docs/            ← legacy docs (README, DISCLAIMER, etc.) kept for reference
```

### Server modules

The server is organized into self-contained `.py` modules. The headline ones:

| Module             | What it does                                           |
| ------------------ | ------------------------------------------------------ |
| `push.py`          | HTTP server entry point, route handlers, APNs glue.   |
| `apns_client.py`   | Apple Push HTTP/2 client with JWT auth.               |
| `chat_history.py`  | Append-only message log + search index.               |
| `token_store.py`   | Shared-secret store for write-endpoint auth.          |
| `device_token_store.py` | Persisted iPhone device tokens for APNs.        |
| `jwt_helper.py`    | APNs `.p8` → JWT signer.                              |
| `task_queue.py`    | Background work pool.                                 |
| `usage.py`         | Anthropic usage probe (optional).                      |

Other modules (`diary`, `favorites`, `group_chat`, `rp_history`, `studyroom`, `timeline`, `todos`, `worklog`, `reminders`, `calendar_store`, `pet_state`, `tts`, `settings`, `diary_stream`, `studyroom_indexer`) implement extra endpoints the CcCompanion iOS app does not call. They're kept in-tree because removing them would fragment the import graph in `push.py`. If you build your own iOS client against this server, those endpoints are available but undocumented; treat them as experimental.

## Build the iOS app yourself

If you don't want to wait on TestFlight you can build the app directly from source:

```bash
cd ios-app/CcCompanion
open CcCompanion.xcodeproj
# In Xcode: select scheme "CcCompanion", configuration "CcRelease",
#          choose your provisioning team, choose your iPhone, ⌘R.
```

You will need to:

- Set your own bundle identifier in the `CcCompanion` target settings (default is `com.example.cccompanion` and will conflict with anything signed by Apple).
- Provide your own Apple Developer team for signing (free personal team works for 7-day on-device builds).
- Enable Push Notifications for that bundle identifier if you want native APNs. The server config bundle id must match exactly, including lowercase `com.starryfield.cccompanion` style casing.
- Run `apns-server` on a Mac or Linux/VPS host that's reachable from your iPhone, with `config.toml` filled in.

## Common questions

**Q: Does my data leave my Mac?**
A: Chat messages and history live on your Mac. When the server pushes a notification, the title / body are sent through Apple's APNs (or Bark's public relay if you chose that). The chat **content** stays on your machine; only the notification preview transits Apple / Bark.

**Q: Can I run this with no Apple Developer account?**
A: Yes. Skip the `[apns]` section of `config.toml` and use [Bark](https://github.com/Finb/Bark) as the push channel. Bark is free, open-source, and runs through its author's relay (or your own self-hosted Bark instance).

**Q: Is it safe to expose port 8795 to the internet?**
A: Don't. Run it behind Tailscale / ZeroTier / a reverse proxy with HTTPS + an auth secret. The default `config.toml` ships with `host = "127.0.0.1"` for a reason.

**Q: Can I run the server on Linux / a VPS instead of a Mac?**
A: Yes. Run `apns-server/push.py` under systemd, keep `claude` in a `tmux` session whose name matches `default_session` in `config.toml`, and expose it over HTTPS — an nginx reverse proxy, or [cloudflared](docs/SETUP_CLOUDFLARED.md) / Tailscale. Keep `strict_auth = true` with a shared secret. See [`docs/SETUP_SERVER.md`](docs/SETUP_SERVER.md) for the Linux/VPS walkthrough.

**Q: The connection dot is red but `curl /health` returns 200 — is the server down?**
A: No. That dot reflects recent chat-poll freshness and Claude activity, not raw `/health` reachability. On cellular, or behind an idle nginx timeout, a single poll can briefly miss. The current build keeps the dot green whenever the active endpoint's `/health` is reachable, shows "thinking" while Claude is replying, and **never blocks sending** either way.

**Q: Duplicate short replies (e.g. two "Got it.") get dropped — how do I fix it?**
A: Update `apns-server/claude_hooks/ccc_stop_hook.sh`. The current hook sends a unique `client_msg_id` per turn, so the server dedupes on that id instead of on message content — identical short replies are no longer collapsed. (The content-fallback dedupe window was also narrowed to a few seconds.)

**Q: Why is the Xcode project under `ios-app/CcCompanion/`?**
A: It is the public Xcode project for CcCompanion. The scheme, project folder, and bundle id are now aligned around the public name.

**Q: How do I update?**
A: `git pull`, then re-build the iOS app and (on the Mac side) restart the `apns-server` LaunchAgent: `launchctl unload ~/Library/LaunchAgents/com.user.apns-server.plist && launchctl load ~/Library/LaunchAgents/com.user.apns-server.plist`.

## Contributing

Issues and PRs welcome. Some areas where we'd love help:

- Android client (matches the iOS endpoints, would be a straight port of the chat / terminal flow).
- Reverse-proxy + HTTPS setup recipes (Caddy, Nginx, Traefik).
- More language docs (this README is bilingual-but-English-leaning).
- Cleanup of legacy modules in `apns-server/` that CcCompanion doesn't use.

Before opening a PR, please:

1. Run `xcodebuild -project ios-app/CcCompanion/CcCompanion.xcodeproj -scheme CcCompanion -configuration CcRelease -destination 'generic/platform=iOS' build` — must succeed.
2. Run `python3 -m py_compile apns-server/*.py` — must produce no errors.
3. Keep secrets / `.p8` / `config.toml` / `tokens/` / `*.jsonl` out of commits (`.gitignore` already covers these).

## License

[MIT](LICENSE). Do whatever you want with it. If it eats your homework, that's on you, not us.

## Acknowledgements

- [Anthropic](https://www.anthropic.com) for Claude and Claude Code.
- [Apple](https://www.apple.com) for APNs and TestFlight.
- [Bark](https://github.com/Finb/Bark) for being a brilliant zero-config push fallback.
- Everyone who tested early TestFlight builds and filed bug reports.
