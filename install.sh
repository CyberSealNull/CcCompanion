#!/usr/bin/env bash
set -euo pipefail

REPO_URL_DEFAULT="https://github.com/CyberSealNull/CcCompanion.git"
LABEL="com.cccompanion.apns-server"
SERVER_UNIT="ccc-apns-server.service"
TMUX_UNIT="ccc-tmux.service"
PROFILE_MARKER_BEGIN="# >>> CcCompanion auto-start >>>"
PROFILE_MARKER_END="# <<< CcCompanion auto-start <<<"

REPO_URL="${CCC_REPO_URL_DEFAULT:-$REPO_URL_DEFAULT}"
INSTALL_DIR="$HOME/CcCompanion"
SESSION_NAME="cc"
PORT="8795"
YES=0
FORCE=0
UNINSTALL=0
DANGEROUS=0
SKIP_SERVICE=0
SKIP_HEALTH=0
APNS_HAVE=0
APNS_P8=""
APNS_TEAM_ID=""
APNS_KEY_ID=""
APNS_BUNDLE_ID="com.example.cccompanion"

usage() {
  cat <<'EOF'
CcCompanion one-shot installer

Usage:
  bash install.sh [options]

Options:
  --dir PATH                       Install directory (default: ~/CcCompanion)
  --repo-url URL                   Git repo to clone (default: CyberSealNull/CcCompanion)
  --session NAME                   tmux/Claude session name (default: cc)
  --port PORT                      apns-server port (default: 8795)
  --yes                            Use defaults for prompts
  --force                          Re-run setup in an existing checkout
  --dangerously-skip-permissions   Start Claude Code with --dangerously-skip-permissions
  --skip-service                   Write config but do not install/start LaunchAgent or systemd
  --skip-health                    Skip curl /health wait
  --uninstall                      Remove auto-start service, keep install directory and data
  -h, --help                       Show this help
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

quote_py() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

script_dir() {
  local source="${BASH_SOURCE[0]:-$0}"
  case "$source" in
    /*) ;;
    *) source="$PWD/$source" ;;
  esac
  cd "$(dirname "$source")" && pwd -P
}

read_tty() {
  local prompt="$1"
  local default="$2"
  local value=""
  if [[ "$YES" -eq 1 ]]; then
    printf '%s' "$default"
    return
  fi
  if [[ -r /dev/tty ]]; then
    printf '%s [%s]: ' "$prompt" "$default" > /dev/tty
    IFS= read -r value < /dev/tty || true
    printf '%s' "${value:-$default}"
  else
    printf '%s' "$default"
  fi
}

confirm_tty() {
  local prompt="$1"
  local default="$2"
  local answer
  answer="$(read_tty "$prompt" "$default")"
  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir) INSTALL_DIR="$2"; shift 2 ;;
      --repo-url) REPO_URL="$2"; shift 2 ;;
      --session) SESSION_NAME="$2"; shift 2 ;;
      --port) PORT="$2"; shift 2 ;;
      --yes) YES=1; shift ;;
      --force) FORCE=1; shift ;;
      --dangerously-skip-permissions) DANGEROUS=1; shift ;;
      --skip-service) SKIP_SERVICE=1; shift ;;
      --skip-health) SKIP_HEALTH=1; shift ;;
      --uninstall) UNINSTALL=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
}

normalize_inputs() {
  INSTALL_DIR="${INSTALL_DIR/#\~/$HOME}"
  [[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be numeric"
  [[ "$SESSION_NAME" =~ ^[A-Za-z0-9_.-]+$ ]] || die "--session must contain only letters, numbers, dot, underscore, or dash"
}

detect_platform() {
  if [[ -n "${CCC_PLATFORM_OVERRIDE:-}" ]]; then
    printf '%s' "$CCC_PLATFORM_OVERRIDE"
    return
  fi
  local kernel
  kernel="$(uname -s)"
  if [[ "$kernel" == "Darwin" ]]; then
    printf 'macos'
    return
  fi
  if [[ "$kernel" == "Linux" ]]; then
    if [[ -r /proc/version ]] && grep -qi microsoft /proc/version; then
      printf 'wsl2'
    else
      printf 'linux'
    fi
    return
  fi
  printf 'linux-unknown'
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required. Install it first and rerun this installer."
}

need_claude() {
  command -v claude >/dev/null 2>&1 || die "Claude Code CLI is required. Install it from the official docs first: https://docs.anthropic.com/en/docs/claude-code"
}

check_python() {
  python3 - <<'PY' || die "python3 3.11+ is required."
import sys
raise SystemExit(0 if sys.version_info >= (3, 11) else 1)
PY
}

preflight() {
  local platform="$1"
  info "Checking prerequisites"
  need_cmd git
  need_cmd curl
  need_cmd python3
  need_cmd tmux
  need_claude
  check_python

  if [[ "$platform" == "macos" ]]; then
    need_cmd sw_vers
    local ver major
    ver="$(sw_vers -productVersion)"
    major="${ver%%.*}"
    [[ "$major" =~ ^[0-9]+$ ]] && [[ "$major" -ge 14 ]] || die "macOS 14+ is required. Current version: $ver"
  elif [[ "$platform" == "linux-unknown" ]]; then
    warn "Unsupported Linux-like platform detected. Continuing as generic Linux."
  fi
}

collect_prompts() {
  INSTALL_DIR="$(read_tty "Install directory" "$INSTALL_DIR")"
  SESSION_NAME="$(read_tty "tmux session name" "$SESSION_NAME")"
  PORT="$(read_tty "server port" "$PORT")"
  if [[ "$YES" -ne 1 ]]; then
    if confirm_tty "Do you have Apple Developer APNs credentials now? (y/N)" "N"; then
      APNS_HAVE=1
      APNS_P8="$(read_tty "Path to AuthKey_XXXXXXXXXX.p8" "$APNS_P8")"
      APNS_TEAM_ID="$(read_tty "Apple Developer Team ID" "$APNS_TEAM_ID")"
      APNS_KEY_ID="$(read_tty "Apple Developer Key ID" "$APNS_KEY_ID")"
      APNS_BUNDLE_ID="$(read_tty "App bundle id" "$APNS_BUNDLE_ID")"
    fi
    if confirm_tty "Start Claude Code with --dangerously-skip-permissions? (y/N)" "N"; then
      DANGEROUS=1
    fi
  fi
  normalize_inputs
}

clone_or_reuse_repo() {
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    if [[ "$FORCE" -eq 0 ]]; then
      info "Existing install found at $INSTALL_DIR"
      echo "Run ccc-update to update it, or rerun install.sh with --force to refresh setup."
      exit 0
    fi
    info "Reusing existing checkout at $INSTALL_DIR"
    return
  fi
  if [[ -e "$INSTALL_DIR" ]]; then
    die "$INSTALL_DIR already exists but is not a git checkout. Move it aside or use a different --dir."
  fi
  info "Cloning $REPO_URL into $INSTALL_DIR"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone "$REPO_URL" "$INSTALL_DIR"
}

ensure_venv() {
  local server_dir="$INSTALL_DIR/apns-server"
  [[ -d "$server_dir" ]] || die "apns-server directory not found in $INSTALL_DIR"
  if [[ ! -d "$server_dir/.venv" ]]; then
    info "Creating Python venv"
    python3 -m venv "$server_dir/.venv"
  fi
  if [[ "${CCC_INSTALLER_SKIP_PIP:-0}" != "1" ]]; then
    info "Installing Python dependencies"
    "$server_dir/.venv/bin/python3" -m pip install --upgrade pip
    "$server_dir/.venv/bin/pip" install -r "$server_dir/requirements.txt"
  else
    info "Skipping pip install because CCC_INSTALLER_SKIP_PIP=1"
  fi
}

generate_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
  fi
}

write_config() {
  local server_dir="$INSTALL_DIR/apns-server"
  local config="$server_dir/config.toml"
  local example="$server_dir/config.example.toml"
  local secret token_path p8_path team_id key_id bundle_id
  [[ -f "$example" ]] || die "missing config.example.toml"
  if [[ -f "$config" && "$FORCE" -eq 0 ]]; then
    info "config.toml already exists; preserving user config"
    return
  fi
  secret="$(generate_secret)"
  token_path="$server_dir/tokens/active.json"
  p8_path=""
  team_id=""
  key_id=""
  bundle_id=""
  if [[ "$APNS_HAVE" -eq 1 ]]; then
    [[ -f "${APNS_P8/#\~/$HOME}" ]] || die "APNs .p8 file not found: $APNS_P8"
    mkdir -p "$server_dir/secrets"
    local p8_src p8_dst
    p8_src="${APNS_P8/#\~/$HOME}"
    p8_dst="$server_dir/secrets/AuthKey_${APNS_KEY_ID}.p8"
    cp "$p8_src" "$p8_dst"
    chmod 600 "$p8_dst"
    p8_path="$p8_dst"
    team_id="$APNS_TEAM_ID"
    key_id="$APNS_KEY_ID"
    bundle_id="$APNS_BUNDLE_ID"
  fi
  info "Writing apns-server/config.toml"
  python3 - "$example" "$config" "$p8_path" "$team_id" "$key_id" "$bundle_id" "$PORT" "$token_path" "$secret" "$SESSION_NAME" <<'PY'
import json
import pathlib
import sys

example, config, p8, team, key, bundle, port, token_path, secret, session = sys.argv[1:]
lines = pathlib.Path(example).read_text().splitlines()
out = []
for line in lines:
    stripped = line.strip()
    if stripped.startswith("p8_path ="):
        line = f"p8_path = {json.dumps(p8)}"
    elif stripped.startswith("team_id ="):
        line = f"team_id = {json.dumps(team)}"
    elif stripped.startswith("key_id ="):
        line = f"key_id = {json.dumps(key)}"
    elif stripped.startswith("bundle_id ="):
        line = f"bundle_id = {json.dumps(bundle)}"
    elif stripped.startswith("host ="):
        line = 'host = "0.0.0.0"'
    elif stripped.startswith("port ="):
        line = f"port = {int(port)}"
    elif stripped.startswith("token_store_path ="):
        line = f"token_store_path = {json.dumps(token_path)}"
    elif stripped.startswith("shared_secret ="):
        line = f"shared_secret = {json.dumps(secret)}"
    elif stripped.startswith("strict_auth ="):
        line = "strict_auth = true"
    elif stripped.startswith("allow_public_bind ="):
        line = "allow_public_bind = true"
    elif stripped.startswith("allow_remote_control ="):
        line = "allow_remote_control = true"
    elif stripped.startswith("# default_session =") or stripped.startswith("default_session ="):
        line = f"default_session = {json.dumps(session)}"
    out.append(line)
pathlib.Path(config).write_text("\n".join(out) + "\n")
PY
  chmod 600 "$config"
}

tmux_command() {
  if [[ "$DANGEROUS" -eq 1 ]]; then
    printf 'claude --dangerously-skip-permissions'
  else
    printf 'claude'
  fi
}

start_tmux_now() {
  local command_text
  command_text="$(tmux_command)"
  if tmux has-session -t "$SESSION_NAME" >/dev/null 2>&1; then
    info "tmux session $SESSION_NAME already exists"
  else
    info "Starting tmux session $SESSION_NAME"
    tmux new-session -d -s "$SESSION_NAME" "$command_text"
  fi
}

write_launch_agent() {
  local server_dir="$INSTALL_DIR/apns-server"
  local plist="$HOME/Library/LaunchAgents/$LABEL.plist"
  mkdir -p "$(dirname "$plist")"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$server_dir/.venv/bin/python3</string>
    <string>$server_dir/push.py</string>
    <string>--config</string>
    <string>$server_dir/config.toml</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$server_dir</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
    <key>Crashed</key>
    <true/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>$server_dir/server.log</string>
  <key>StandardErrorPath</key>
  <string>$server_dir/server.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>PYTHONUNBUFFERED</key>
    <string>1</string>
  </dict>
</dict>
</plist>
EOF
  info "Installing LaunchAgent $plist"
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$plist"
  launchctl enable "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  launchctl kickstart -k "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
}

write_systemd_units() {
  local systemd_dir="$HOME/.config/systemd/user"
  local server_dir="$INSTALL_DIR/apns-server"
  local command_text
  command_text="$(tmux_command)"
  mkdir -p "$systemd_dir"
  cat > "$systemd_dir/$SERVER_UNIT" <<EOF
[Unit]
Description=CcCompanion apns-server
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$server_dir
ExecStart=$server_dir/.venv/bin/python3 $server_dir/push.py --config $server_dir/config.toml
Restart=on-failure
RestartSec=3
StandardOutput=append:$server_dir/server.log
StandardError=append:$server_dir/server.err.log

[Install]
WantedBy=default.target
EOF
  cat > "$systemd_dir/$TMUX_UNIT" <<EOF
[Unit]
Description=CcCompanion Claude Code tmux session
After=network-online.target

[Service]
Type=forking
ExecStart=$(command -v tmux) new-session -d -s $SESSION_NAME $command_text
ExecStop=$(command -v tmux) kill-session -t $SESSION_NAME
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
  append_profile_fallback
  info "Installing user systemd services"
  if command -v loginctl >/dev/null 2>&1; then
    loginctl enable-linger "${USER:-$(id -un)}" >/dev/null 2>&1 || true
  fi
  if command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload; then
    systemctl --user enable "$SERVER_UNIT" "$TMUX_UNIT"
    systemctl --user restart "$TMUX_UNIT"
    systemctl --user restart "$SERVER_UNIT"
  else
    warn "systemd --user is unavailable. Falling back to shell-profile startup."
    start_tmux_now
    nohup "$server_dir/.venv/bin/python3" "$server_dir/push.py" --config "$server_dir/config.toml" >> "$server_dir/server.log" 2>> "$server_dir/server.err.log" &
  fi
}

append_profile_fallback() {
  local profile="$HOME/.profile"
  local server_dir="$INSTALL_DIR/apns-server"
  local command_text
  command_text="$(tmux_command)"
  mkdir -p "$(dirname "$profile")"
  if [[ -f "$profile" ]] && grep -Fq "$PROFILE_MARKER_BEGIN" "$profile"; then
    return
  fi
  cat >> "$profile" <<EOF

$PROFILE_MARKER_BEGIN
if command -v systemctl >/dev/null 2>&1 && systemctl --user status >/dev/null 2>&1; then
  systemctl --user start $SERVER_UNIT $TMUX_UNIT >/dev/null 2>&1 || true
else
  if command -v tmux >/dev/null 2>&1 && ! tmux has-session -t $SESSION_NAME >/dev/null 2>&1; then
    tmux new-session -d -s $SESSION_NAME "$command_text" || true
  fi
  if command -v pgrep >/dev/null 2>&1; then
    if ! pgrep -f "$server_dir/push.py --config $server_dir/config.toml" >/dev/null 2>&1; then
      nohup "$server_dir/.venv/bin/python3" "$server_dir/push.py" --config "$server_dir/config.toml" >> "$server_dir/server.log" 2>> "$server_dir/server.err.log" &
    fi
  else
    nohup "$server_dir/.venv/bin/python3" "$server_dir/push.py" --config "$server_dir/config.toml" >> "$server_dir/server.log" 2>> "$server_dir/server.err.log" &
  fi
fi
$PROFILE_MARKER_END
EOF
}

install_service() {
  local platform="$1"
  [[ "$SKIP_SERVICE" -eq 1 ]] && { info "Skipping service setup"; return; }
  case "$platform" in
    macos)
      start_tmux_now
      write_launch_agent
      ;;
    wsl2|linux|linux-unknown)
      write_systemd_units
      ;;
  esac
}

install_update_tool() {
  local src=""
  local dir
  dir="$(script_dir)"
  if [[ -f "$INSTALL_DIR/ccc-update" ]]; then
    src="$INSTALL_DIR/ccc-update"
  elif [[ -f "$dir/ccc-update" ]]; then
    src="$dir/ccc-update"
  fi
  mkdir -p "$INSTALL_DIR/bin"
  if [[ -n "$src" ]]; then
    cp "$src" "$INSTALL_DIR/bin/ccc-update"
  else
    cat > "$INSTALL_DIR/bin/ccc-update" <<'EOF'
#!/usr/bin/env bash
echo "ccc-update is missing from this checkout. Run git pull, then retry." >&2
exit 1
EOF
  fi
  chmod +x "$INSTALL_DIR/bin/ccc-update"
  if [[ -d /usr/local/bin && -w /usr/local/bin ]]; then
    ln -sf "$INSTALL_DIR/bin/ccc-update" /usr/local/bin/ccc-update
  fi
}

wait_health() {
  [[ "$SKIP_HEALTH" -eq 1 ]] && { info "Skipping health check"; return; }
  local url="http://127.0.0.1:$PORT/health"
  info "Waiting for $url"
  local attempts=20
  while [[ "$attempts" -gt 0 ]]; do
    if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
      curl -fsS --max-time 2 "$url" || true
      echo
      return
    fi
    sleep 1
    attempts=$((attempts - 1))
  done
  die "health check failed. See $INSTALL_DIR/apns-server/server.err.log"
}

first_ipv4_from_words() {
  awk '{for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {print $i; exit}}'
}

print_urls() {
  local platform="$1"
  local printed=0
  echo
  echo "iPhone setup"
  echo "------------"
  if [[ "$platform" == "macos" ]]; then
    local iface ip
    for iface in en0 en1 bridge100; do
      ip="$(ipconfig getifaddr "$iface" 2>/dev/null || true)"
      if [[ -n "$ip" ]]; then
        echo "Server URL: http://$ip:$PORT"
        printed=1
      fi
    done
  else
    local ip
    ip="$(hostname -I 2>/dev/null | first_ipv4_from_words || true)"
    if [[ -n "$ip" ]]; then
      echo "Server URL: http://$ip:$PORT"
      printed=1
    fi
  fi
  if command -v tailscale >/dev/null 2>&1; then
    local ts
    ts="$(tailscale ip -4 2>/dev/null | head -n 1 || true)"
    if [[ -n "$ts" ]]; then
      echo "Server URL: http://$ts:$PORT"
      printed=1
    fi
  fi
  [[ "$printed" -eq 1 ]] || echo "Server URL: http://<your-computer-ip>:$PORT"
  echo "Secret: $(python3 - "$INSTALL_DIR/apns-server/config.toml" <<'PY'
import re, sys, pathlib
t = pathlib.Path(sys.argv[1]).read_text()
m = re.search(r'^shared_secret = "([^"]+)"', t, re.M)
print(m.group(1) if m else "")
PY
)"
  echo "tmux session: $SESSION_NAME"
  echo
  echo "Next: install the iPhone TestFlight build, then enter one Server URL and the Secret above."
  echo "Network: use LAN, Tailscale (https://tailscale.com), or ZeroTier (https://www.zerotier.com). Do not expose port $PORT naked to the public internet."
  if [[ "$APNS_HAVE" -eq 0 ]]; then
    echo "APNs: not configured. Chat still works while the app is open; iOS uses polling + local notifications. Remote lock-screen push needs Apple Developer credentials later."
  fi
  if [[ "$platform" == "wsl2" ]]; then
    echo
    echo "WSL2 note: install Tailscale on Windows, then forward Windows port $PORT to WSL."
    echo "PowerShell admin portproxy sketch:"
    echo "  \$wslIp = (wsl hostname -I).Trim().Split(' ')[0]"
    echo "  netsh interface portproxy add v4tov4 listenport=$PORT listenaddress=0.0.0.0 connectaddress=\$wslIp connectport=$PORT"
    echo "  netsh advfirewall firewall add rule name=\"ccc-$PORT\" dir=in action=allow protocol=TCP localport=$PORT"
  fi
  echo
  echo "Update later: $INSTALL_DIR/bin/ccc-update"
}

uninstall_service() {
  local platform="$1"
  local config="$INSTALL_DIR/apns-server/config.toml"
  if [[ -f "$config" ]]; then
    SESSION_NAME="$(python3 - "$config" "$SESSION_NAME" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
fallback = sys.argv[2]
match = re.search(r'^default_session = "([^"]+)"', text, re.M)
print(match.group(1) if match else fallback)
PY
)"
  fi
  info "Removing auto-start service; preserving $INSTALL_DIR and data"
  case "$platform" in
    macos)
      launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
      rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
      ;;
    wsl2|linux|linux-unknown)
      if command -v systemctl >/dev/null 2>&1; then
        systemctl --user disable --now "$SERVER_UNIT" "$TMUX_UNIT" >/dev/null 2>&1 || true
        systemctl --user daemon-reload >/dev/null 2>&1 || true
      fi
      rm -f "$HOME/.config/systemd/user/$SERVER_UNIT" "$HOME/.config/systemd/user/$TMUX_UNIT"
      if [[ -f "$HOME/.profile" ]]; then
        python3 - "$HOME/.profile" "$PROFILE_MARKER_BEGIN" "$PROFILE_MARKER_END" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
begin, end = sys.argv[2], sys.argv[3]
text = path.read_text()
start = text.find(begin)
if start != -1:
    prefix = text[:start].rstrip()
    stop = text.find(end, start)
    suffix = text[stop + len(end):] if stop != -1 else ""
    path.write_text(prefix + "\n" + suffix.lstrip("\n"))
PY
      fi
      ;;
  esac
  if command -v tmux >/dev/null 2>&1 && tmux has-session -t "$SESSION_NAME" >/dev/null 2>&1; then
    if [[ "$YES" -eq 0 ]] && confirm_tty "Stop tmux session $SESSION_NAME now? This may interrupt running work. (y/N)" "N"; then
      tmux kill-session -t "$SESSION_NAME" || true
      echo "Stopped tmux session $SESSION_NAME."
    else
      echo "tmux session $SESSION_NAME was left running."
      echo "To stop it manually: tmux kill-session -t $SESSION_NAME"
    fi
  fi
  echo "Uninstalled auto-start. Preserved install directory, config, tokens, and conversation history in $INSTALL_DIR."
}

main() {
  parse_args "$@"
  normalize_inputs
  local platform
  platform="$(detect_platform)"
  if [[ "$UNINSTALL" -eq 1 ]]; then
    uninstall_service "$platform"
    return
  fi
  collect_prompts
  platform="$(detect_platform)"
  preflight "$platform"
  clone_or_reuse_repo
  ensure_venv
  write_config
  install_update_tool
  install_service "$platform"
  wait_health
  print_urls "$platform"
}

main "$@"
