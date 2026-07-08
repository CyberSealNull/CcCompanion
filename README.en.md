# CcCompanion

> **Claude Code** in your pocket. A full-featured open-source iOS client + a computer-side push server (runs on macOS / Windows WSL2 / Linux·VPS): chat, handheld terminal, slash-command panel, voice input, favorites, multi-agent group view, and a complete WeChat-style theme — the Claude Code running on your computer, with you around the clock. Runs entirely on your own devices. No third-party servers.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Not affiliated with Anthropic.** "Claude" and "Claude Code" are trademarks of Anthropic PBC. See [`DISCLAIMER.md`](DISCLAIMER.md).

中文版: [README.md](README.md)

---

## What is this

CcCompanion has two parts:

1. **`ios-app/`** — a SwiftUI iOS app (TestFlight invite-only for now, App Store later) that gives you chat / terminal / slash commands on your iPhone, connected to the Claude Code session on your computer over an overlay network — works from anywhere.
2. **`apns-server/`** — a Python HTTP service on your computer (natively on macOS, inside WSL2 on Windows, or on a Linux / VPS host) that forwards your chat to the local `claude` running in `tmux`, captures replies, and pushes them back to your iPhone via Apple Push.

The whole thing is **local-first** — your messages never touch our server, because there is no "our server". Your computer and your iPhone talk directly over Tailscale / ZeroTier / LAN.

## What it can do

**Chat, the complete kind:**

- **Chat** — send from iPhone, get Claude Code's replies pushed back. Streaming, full history, full-text search, jump to any message.
- **Voice input** — hold to talk, on-device speech recognition, no typing on your commute.
- **Attachments** — send images / files to Claude Code; toss it a screenshot and let it look.
- **Favorites** — one-tap save for answers that matter, browsable on their own page.
- **Stickers** — a built-in sticker panel, because chatting with your AI can have memes too.
- **Slash-command panel** — `/new`, `/list`, `/switch <sid>`, `/stop`, `/compact`, `/clear`, `/help` in a popover, no memorizing. Multi-session follows the current active one.

**Your computer, in your palm:**

- **Terminal** — an embedded view of the `tmux` session running `claude` on your computer; watch what it's doing in real time, type commands from the input bar, with a keyboard toolbar for arrow keys / Enter / Esc / Ctrl-C — interactive panels like `/model` work just like sitting at your desk. No need to go unlock the computer.
- **Multi-endpoint** — configure several server URLs in one app (Tailscale `100.x` + LAN `10.x` + localhost); it pings and switches to whichever is alive. Follows you across wifi changes.

**Multi-agent & personalization:**

- **Group view** — if your computer runs multiple collaborating agents (the server's group endpoints), the app has a group-chat screen to watch them talk, with in-group search and favorites. Experimental, enable in Settings.
- **WeChat-style theme** — a full skin: chat bubbles, a moments-style timeline page, and a custom nickname for your AI. Change the skin, change the relationship.
- **Themes** — light / dark / warm, can follow the system.
- **Avatars & identity** — set avatars for the AI and yourself (with cropping), pick names; a 6-step onboarding wizard (server URL + secret + avatar + name + ping test).

**Notifications & updates:**

- **Polling local notifications** — when polling picks up a new assistant message, the app fires a local iOS notification. Works while the app is foregrounded / within background-refresh windows, and requires no Apple Developer credentials. On by default, can be turned off in Settings.
- **Remote APNs push** — build 213+ supports server-side APNs push, so you get notified even when the app is fully backgrounded or the phone is locked. Requires the app bundle to have Push Notifications enabled and the computer-side server configured with APNs credentials (needs an Apple Developer account, see below).
- **What's New** — per-version release notes right inside the app.
- **Experimental feature flags** — new or risky features ship behind Settings toggles, off by default. Upgrades never disrupt existing users; the curious flip the switch themselves.

**The baseline:**

- **Privacy, local-first** — conversation content never leaves your devices. `config.toml` and `.p8` are `.gitignore`-d; the repo only ships a `config.example.toml` template. You run your server, your Claude Code — this project is just the UI and the pipe.

## Roadmap (in development, not shipped yet)

The items below are being worked on and are **not in the current version**. They're listed so you know where this is going — not so you go hunting for them in Settings:

- **Multi-session** — multiple chat windows in a session list, each connected to its own backend.
- **Direct API sessions** — the app talks to a model directly with your own API key, no computer in the loop (configurable base URL, proxy-friendly). Keys live only in the iOS Keychain, transcripts stay on the phone — it keeps working when your computer is off or offline. The escape hatch of the whole system.
- **In-app effort switching** — no more typing commands in the terminal for this.
- **Bark push integration** — lock-screen push for users without an Apple Developer account ([Bark](https://github.com/Finb/Bark) is free and open source). **Erratum**: earlier versions of this README described Bark fallback as an existing feature; the server-side integration had not actually landed. The docs got ahead of the code — this revision corrects that, with apologies to anyone who went looking for the bark config section. Until it lands, use "polling local notifications" above.

When these ship we'll update the README and the TestFlight release notes. Until then, this section is the source of truth.

## What you need

- macOS 14 (Sonoma) or newer, **or Windows (via WSL2, see [`docs/SETUP_WIN_WSL2.md`](docs/SETUP_WIN_WSL2.md)), or Linux / a VPS (see [`docs/SETUP_SERVER.md`](docs/SETUP_SERVER.md))**, with [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and an Anthropic Pro / Max subscription.
- iPhone on iOS 18+.
- Tailscale / ZeroTier / or just have the iPhone and the computer on the same LAN.
- Native APNs push (lock-screen / fully-backgrounded delivery) requires an Apple Developer account ($99/yr). Without one, everything else still works: chat / terminal / slash commands are unaffected, and local notifications cover you while the app is open; you just won't get remote push when the app is killed or the phone stays locked (the Bark integration on the Roadmap is for exactly that case).
- **Xcode 16.3 or newer** (Swift tools 6.1+) if you build the iOS app yourself. GRDB 7.10.0 requires Swift tools 6.1; older Xcode (≤ 16.2) may fail to resolve. TestFlight installs are not affected.

## Quick start

Fastest path: paste this into macOS Terminal. Windows / WSL2 uses the same command, but is currently beta until a real Windows-machine smoke test is complete:

```bash
curl -fsSL https://raw.githubusercontent.com/CyberSealNull/CcCompanion/main/install.sh | bash
```

The installer checks prerequisites, clones the repo, creates the Python venv, generates `config.toml`, starts `claude` in `tmux`, sets up auto-start, runs `/health`, and prints the Server URL + Secret for iPhone onboarding. Later updates are:

```bash
ccc-update
```

If you want to understand each step, or you get stuck and want an AI assistant to guide you, copy the full text of [`docs/AI_GUIDED_SETUP_MAC.md`](docs/AI_GUIDED_SETUP_MAC.md), paste it into your favorite AI assistant (Claude.ai / ChatGPT / Cursor / Gemini all work), and prepend one line:

```
Please guide me step by step through installing ccc from scratch, following this spec.
```

The AI plays setup guide from Phase A to Phase I — one step at a time, no question-dumping, no rushing.

Prefer reading it yourself:

- **macOS** → [`docs/AI_GUIDED_SETUP_MAC.md`](docs/AI_GUIDED_SETUP_MAC.md) (written to be human-readable too)
- **Windows (WSL2, beta, pending real-machine validation)** → [`docs/SETUP_WIN_WSL2.md`](docs/SETUP_WIN_WSL2.md)
- **Server details** → [`docs/SETUP_SERVER.md`](docs/SETUP_SERVER.md)

The iOS app is currently TestFlight invite-only. Email [opia@starryfield.space](mailto:opia@starryfield.space) or add WeChat CyberSealNull to get invited.

## Architecture

```
              ┌──────────────────────────┐
              │  iPhone running ccc app  │
              └─────────────┬────────────┘
                            │  HTTPS poll + APNs push
                            │  (no APNs creds: polling + local notifications)
              ┌─────────────▼────────────┐
              │  Mac/WSL2: apns-server   │
              │  (Python HTTP service)   │
              └─────────────┬────────────┘
                            │  tmux send-keys / capture-pane
              ┌─────────────▼────────────┐
              │  tmux session "cc"       │
              │  └ claude (CLI agent)    │
              └──────────────────────────┘
```

Networking: the app and server talk over Tailscale / ZeroTier / LAN. The one-shot installer writes `strict_auth = true`, a strong random `shared_secret`, and binds the server to `0.0.0.0` so the phone can reach it. If you install manually, `config.example.toml` defaults to `127.0.0.1`; switch to `0.0.0.0` only after your overlay network + auth secret are in place.

## Experimental feature flags

Any new CcCompanion feature that touches navigation / notifications / rendering / agent workflows should ship behind an `@AppStorage` toggle in Settings, off by default — unless it's a compatibility or security fix. Existing users stay undisturbed; local users who want it flip it on.

Current flags:

- `feature_group_view`: shows the group tab, polling `/group/poll` for multi-agent collaboration messages.

## Repo layout

```
CcCompanion/
├── README.md                    ← Chinese version
├── README.en.md                 ← you are here
├── LICENSE                      ← MIT
├── DISCLAIMER.md                ← Anthropic trademark disclaimer
├── .gitignore                   ← what never enters git (secrets / logs / build / user data)
├── ios-app/                     ← SwiftUI iOS app (Xcode project)
│   └── CcCompanion/           ← Xcode workspace root; build scheme `CcCompanion`
├── apns-server/                 ← Python HTTP service (push.py is the entry)
│   ├── push.py                  ← main server
│   ├── apns_client.py           ← Apple Push wrapper
│   ├── chat_history.py          ← chat persistence
│   ├── config.example.toml      ← config template, copy to config.toml and fill in
│   └── …                        ← other modules, see "Server modules"
├── docs/                        ← setup guides + Apple Developer p8 checklist + WSL2 flow
└── cccompanion-docs/            ← historical docs (legacy README / DISCLAIMER etc.) kept for reference
```

### Server modules

The server is split into standalone `.py` modules. The main ones:

| Module             | What it does                                     |
| ------------------ | ------------------------------------------------ |
| `push.py`          | HTTP server entry, route handlers, APNs dispatch. |
| `apns_client.py`   | Apple Push HTTP/2 client with JWT auth.           |
| `chat_history.py`  | Append-only message log + search index.           |
| `token_store.py`   | Shared-secret storage for write-endpoint auth.    |
| `device_token_store.py` | iPhone APNs device token persistence.        |
| `jwt_helper.py`    | `.p8`-to-JWT signer.                              |
| `task_queue.py`    | Background task pool.                             |
| `usage.py`         | Anthropic usage probe (optional).                 |

The other modules (`diary`, `favorites`, `group_chat`, `rp_history`, `studyroom`, `timeline`, `todos`, `worklog`, `reminders`, `calendar_store`, `pet_state`, `tts`, `settings`, `diary_stream`, `studyroom_indexer`) are endpoints for a private client; the CcCompanion iOS app doesn't call them. They stay in the repo because `push.py` imports them and removing them would break the import graph. You're welcome to build your own client against those endpoints — undocumented, treat as experimental.

## Build the iOS app yourself

Don't want to wait for TestFlight? Build from source:

```bash
cd ios-app/CcCompanion
open CcCompanion.xcodeproj
# In Xcode: pick scheme "CcCompanion", configuration "CcRelease",
#           choose your signing team, plug in your iPhone, hit ⌘R.
```

You'll need to:

- Change the bundle id (the default `com.example.cccompanion` conflicts with any Apple-signed app; it won't install unchanged).
- Provide your own Apple Developer team signing (a free personal team can install 7-day dev builds).
- For native APNs, enable Push Notifications for that bundle id at developer.apple.com. The bundle id in the server config must match it exactly, including case. **Note**: APNs credentials must belong to whoever signed the app — only the signer's `.p8` can push to its device tokens. TestFlight builds are signed by us, so your own `.p8` won't work against them; only self-signed builds can use your own APNs. Checklist: [`docs/01_apple_developer_p8_checklist.md`](docs/01_apple_developer_p8_checklist.md).
- Run `apns-server` on a computer reachable from your iPhone (macOS / WSL2 / Linux·VPS), with `config.toml` filled in.

## FAQ

**Q: Does my data leave my computer?**
A: Chat content and history stay on your own machine. When the server pushes a notification, the title/body pass through Apple APNs. Chat **content** never leaves the machine; only notification previews pass through Apple.

**Q: Can I run this without an Apple Developer account?**
A: Yes — chat / terminal / slash commands are fully functional. Just leave the `[apns]` section of `config.toml` empty. The only difference is notifications: with the app open you get polling + local iOS notifications; you won't get remote push when the app is killed or the phone stays locked. The Bark integration for exactly this case is on the [Roadmap](#roadmap-in-development-not-shipped-yet) — until it lands, don't go looking for a bark config section per older docs; it doesn't exist yet.

**Q: I'm a TestFlight user — can I configure my own APNs push?**
A: No, and it's Apple's mechanism, not a configuration problem — TestFlight builds are signed by our developer account, so a `.p8` you request yourself can't push to their device tokens (you'd get `DeviceTokenNotForTopic`). TestFlight users: use polling + local notifications, or wait for the Bark integration. For full self-hosted APNs, take the "Build the iOS app yourself" path.

**Q: Can I run the server on Linux / a VPS instead of a Mac?**
A: Yes. Run `apns-server/push.py` under systemd, keep `claude` in a `tmux` session whose name matches `default_session` in `config.toml`, and expose it over HTTPS — an nginx reverse proxy, or [cloudflared](docs/SETUP_CLOUDFLARED.md) / Tailscale. Keep `strict_auth = true` with a shared secret. See [`docs/SETUP_SERVER.md`](docs/SETUP_SERVER.md) for the Linux/VPS walkthrough.

**Q: The connection dot is red but `curl /health` returns 200 — is the server down?**
A: No. That dot reflects recent chat-poll freshness and Claude activity, not raw `/health` reachability. On cellular, or behind an idle nginx timeout, a single poll can briefly miss. The current build keeps the dot green whenever the active endpoint's `/health` is reachable, shows "thinking" while Claude is replying, and **never blocks sending** either way.

**Q: Duplicate short replies (e.g. two "Got it.") get dropped — how do I fix it?**
A: Update `apns-server/claude_hooks/ccc_stop_hook.sh`. The current hook sends a unique `client_msg_id` per turn, so the server dedupes on that id instead of on message content — identical short replies are no longer collapsed. (The content-fallback dedupe window was also narrowed to a few seconds.)

**Q: Is it safe to expose port 8795 to the internet?**
A: Don't. Put it behind Tailscale / ZeroTier / a reverse proxy with HTTPS, plus the auth secret. The default `config.toml` binds `host = "127.0.0.1"` for a reason.

**Q: Why is the Xcode project under `ios-app/CcCompanion/`?**
A: That's the public Xcode project for CcCompanion. Scheme, project directory, and bundle id are unified under the public name.

**Q: How do I update?**
A: `git pull`, rebuild the iOS app, and restart the server (on macOS it's a LaunchAgent, command below; on WSL2 restart however you set up auto-start): `launchctl unload ~/Library/LaunchAgents/com.user.apns-server.plist && launchctl load ~/Library/LaunchAgents/com.user.apns-server.plist`.

## Contributing

Issues and PRs welcome. Things we'd especially love:

- An Android client (matching the iOS endpoints, porting the chat + terminal flows).
- Reverse proxy + HTTPS recipes (Caddy / Nginx / Traefik).
- Docs in more languages (this README is bilingual, but the other docs lean English).
- Cleanup of the legacy server modules CcCompanion doesn't use.

Before opening a PR:

1. `xcodebuild -project ios-app/CcCompanion/CcCompanion.xcodeproj -scheme CcCompanion -configuration CcRelease -destination 'generic/platform=iOS' build` must SUCCEED.
2. `python3 -m py_compile apns-server/*.py` must pass.
3. No secrets / `.p8` / `config.toml` / `tokens/` / `*.jsonl` in commits (`.gitignore` already blocks them).

## License

[MIT](LICENSE). Do whatever you want with it. If it eats your homework, that's on you, not us.

## Credits

- [Anthropic](https://www.anthropic.com) — Claude and Claude Code.
- [Apple](https://www.apple.com) — APNs and TestFlight.
- [Bark](https://github.com/Finb/Bark) — an excellent open-source push solution; our integration is on the way.
- Everyone who tested early TestFlight builds, filed bugs, hit the Bark pothole in the old docs, and came back anyway.
