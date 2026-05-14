# DISCLAIMER

CcCompanion is provided **AS IS** without warranty of any kind. Use at your own risk.

---

## 1. Privacy

- CcCompanion **does not** collect or transmit any user data to the developer.
- Your chat history, tokens, and configuration are stored **locally on your devices** (iPhone + your own server).
- No analytics, no telemetry, no remote logging.
- The developer cannot recover your data if you lose it.

## 2. You are running your own infrastructure

- You provide your own Claude Code session (Mac / Linux / Windows).
- You provide your own Anthropic API key or Claude Code subscription.
- You provide your own server (push.py, runs on your machine).
- The developer **does not** host any backend service for you.
- If your server goes down, the app stops working. That is by design.

## 3. Anthropic Terms of Service

- This project depends on [Anthropic Claude API](https://www.anthropic.com/) and/or [Claude Code](https://github.com/anthropics/claude-code).
- You must comply with Anthropic's [Terms of Service](https://www.anthropic.com/legal/consumer-terms) and [Acceptable Use Policy](https://www.anthropic.com/legal/aup).
- **Specifically prohibited:** running Claude Code subscription on a server to resell or distribute access to multiple users. CcCompanion is designed for **single-user** use only (yourself).
- If you want to serve multiple users, use Anthropic API keys (per-token billing) on your server.
- Violation of Anthropic ToS may result in account suspension. The developer takes no responsibility.

## 4. Supported Regions

- Anthropic Claude API is **not officially supported in Mainland China**.
- Connecting via VPN may result in unstable connections or account suspension.
- The developer takes no responsibility for VPN-related account issues.
- Use at your own discretion.

## 5. Security

- The default `shared_secret` is auto-generated on first server boot. **Rotate it** if you suspect leakage.
- Keep `~/.ots/secret` file permissions at `0600`.
- Bind your server to `127.0.0.1` or your VPN interface (e.g., Tailscale `100.x.x.x`). **Do not** bind to `0.0.0.0` unless you understand the risk.
- The remote-control endpoints (`/tmux/send`, `/chain/restart`, etc.) are **disabled by default** in v0.1. Re-enable only if you understand the risks.

## 6. No SLA, No Support

- This is a community project. There is no service-level agreement.
- Bug reports welcome via GitHub Issues. Response time is best-effort.
- Email feedback: `letters@starryfield.space`

## 7. License

This software is licensed under MIT. See [LICENSE](LICENSE) for full terms.

---

By using CcCompanion you acknowledge you have read and understood this disclaimer.

*Last updated: 2026-05-10*
