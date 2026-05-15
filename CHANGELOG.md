# Changelog

## Unreleased

- Split the APNs server implementation into a `server/` package while keeping `apns-server/push.py` as the compatibility entry point.
- Added `apns-server/scripts/doctor.py` for local preflight checks: Python version, installed dependencies, config parsing, tmux, Claude Code CLI, port availability, and Python syntax.
- Moved the Live Activity disable switch into `config.toml` as `[apns].live_activity_disabled`.
- Added stderr logging and timeout monitoring for background subprocess launches.
- Made Studyroom YAML parsing degrade gracefully when optional `PyYAML` is not installed.
