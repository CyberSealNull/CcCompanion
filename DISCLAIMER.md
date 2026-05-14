# DISCLAIMER

**CcCompanion is NOT affiliated with, endorsed by, or sponsored by Anthropic PBC.**

"Claude" and "Claude Code" are trademarks of Anthropic PBC.

This project provides:

1. an iPhone client (CcCompanion app), and
2. a Python HTTP server (`apns-server/push.py`)

that bridges a locally-running Claude Code instance on your Mac with your iPhone
via APNs push, Bark fallback, and local HTTP polling. We do **NOT** redistribute
Claude Code itself; users must install Claude Code separately and agree to
Anthropic's Terms of Service.

## Use at your own risk

- Crypto / financial / health / legal / sensitive data should **NOT** be sent
  through unencrypted local HTTP.
- For any non-trivial use, run the server behind a reverse proxy with HTTPS
  and consider mTLS or VPN-only access.
- The default config binds to `127.0.0.1` (loopback only). Switching to
  `0.0.0.0` exposes the server to anyone on your LAN. Only do that on a
  network you trust, and always keep the auth secret long and secret.
- Apple Developer p8 keys must be kept in `apns-server/secrets/`, which is
  `.gitignore`-d. Never commit them.

## No warranty

The software is provided "as is" without warranty of any kind. See `LICENSE`.
