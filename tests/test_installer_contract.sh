#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file: $1"
}

assert_executable() {
  [[ -x "$1" ]] || fail "expected executable: $1"
}

assert_contains() {
  local file="$1"
  local needle="$2"
  grep -Fq "$needle" "$file" || fail "expected '$needle' in $file"
}

assert_not_contains() {
  local file="$1"
  local needle="$2"
  if grep -Fq "$needle" "$file"; then
    fail "did not expect '$needle' in $file"
  fi
}

config_value() {
  local file="$1"
  local key="$2"
  python3 - "$file" "$key" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
key = re.escape(sys.argv[2])
match = re.search(rf'^{key} = "([^"]*)"', text, re.M)
if not match:
    raise SystemExit(f"missing key: {sys.argv[2]}")
print(match.group(1))
PY
}

make_fakebin() {
  local dir="$1"
  mkdir -p "$dir"

  cat > "$dir/sw_vers" <<'SH'
#!/usr/bin/env bash
echo "15.5"
SH

  cat > "$dir/tmux" <<'SH'
#!/usr/bin/env bash
echo "tmux $*" >> "${CCC_FAKE_LOG:?}"
if [[ "${1:-}" == "-V" ]]; then
  echo "tmux 3.4"
  exit 0
fi
if [[ "${1:-}" == "has-session" ]]; then
  if [[ "${CCC_FAKE_TMUX_HAS_SESSION:-0}" == "1" ]]; then
    exit 0
  fi
  exit 1
fi
exit 0
SH

  cat > "$dir/claude" <<'SH'
#!/usr/bin/env bash
echo "claude $*" >> "${CCC_FAKE_LOG:?}"
echo "1.0.0"
SH

  cat > "$dir/launchctl" <<'SH'
#!/usr/bin/env bash
echo "launchctl $*" >> "${CCC_FAKE_LOG:?}"
exit 0
SH

  cat > "$dir/systemctl" <<'SH'
#!/usr/bin/env bash
echo "systemctl $*" >> "${CCC_FAKE_LOG:?}"
exit 0
SH

  cat > "$dir/loginctl" <<'SH'
#!/usr/bin/env bash
echo "loginctl $*" >> "${CCC_FAKE_LOG:?}"
exit 0
SH

  cat > "$dir/ipconfig" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "getifaddr" ]]; then
  echo "192.0.2.10"
fi
SH

  cat > "$dir/tailscale" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "ip" ]]; then
  echo "100.64.0.1"
fi
SH

  cat > "$dir/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "${CCC_FAKE_LOG:?}"
echo '{"ok": true}'
SH

  cat > "$dir/nohup" <<'SH'
#!/usr/bin/env bash
echo "nohup $*" >> "${CCC_FAKE_LOG:?}"
exit 0
SH

  chmod +x "$dir"/*
}

run_macos_install_contract() {
  local tmp home fakebin install_dir out log config plist
  tmp="$(mktemp -d)"
  home="$tmp/home"
  fakebin="$tmp/fakebin"
  install_dir="$tmp/CcCompanion"
  out="$tmp/install.out"
  log="$tmp/fake.log"
  mkdir -p "$home"
  : > "$log"
  make_fakebin "$fakebin"

  PATH="$fakebin:$PATH" \
  HOME="$home" \
  CCC_FAKE_LOG="$log" \
  CCC_PLATFORM_OVERRIDE="macos" \
  CCC_INSTALLER_SKIP_PIP="1" \
  bash "$ROOT/install.sh" \
    --repo-url "$ROOT" \
    --dir "$install_dir" \
    --port 18888 \
    --session testcc \
    --yes > "$out"

  config="$install_dir/apns-server/config.toml"
  plist="$home/Library/LaunchAgents/com.cccompanion.apns-server.plist"

  assert_file "$config"
  assert_contains "$config" 'host = "0.0.0.0"'
  assert_contains "$config" 'port = 18888'
  assert_contains "$config" 'strict_auth = true'
  assert_contains "$config" 'allow_public_bind = true'
  assert_contains "$config" 'allow_remote_control = true'
  assert_contains "$config" 'default_session = "testcc"'
  assert_contains "$config" 'p8_path = ""'
  assert_contains "$config" 'team_id = ""'
  assert_contains "$config" 'key_id = ""'
  assert_contains "$config" 'shared_secret = "'
  python3 - "$config" <<'PY'
import pathlib
import sys
import tomllib

path = pathlib.Path(sys.argv[1])
tomllib.loads(path.read_text())
count = sum(1 for line in path.read_text().splitlines() if line.startswith("default_session = "))
if count != 1:
    raise SystemExit(f"default_session should appear once, got {count}")
PY
  assert_file "$plist"
  assert_contains "$plist" "$install_dir/apns-server/.venv/bin/python3"
  assert_executable "$install_dir/bin/ccc-update"
  assert_contains "$out" "iPhone setup"
  assert_contains "$out" "http://192.0.2.10:18888"
  assert_contains "$out" "http://100.64.0.1:18888"
  assert_contains "$out" "Secret:"
  assert_contains "$log" "tmux new-session -d -s testcc claude"
  assert_not_contains "$log" "dangerously"

  PATH="$fakebin:$PATH" \
  HOME="$home" \
  CCC_FAKE_LOG="$log" \
  CCC_FAKE_TMUX_HAS_SESSION="1" \
  CCC_PLATFORM_OVERRIDE="macos" \
  bash "$ROOT/install.sh" --dir "$install_dir" --uninstall --yes > "$tmp/uninstall.out"

  [[ -d "$install_dir" ]] || fail "uninstall should preserve install dir"
  [[ -f "$config" ]] || fail "uninstall should preserve config/history"
  [[ ! -f "$plist" ]] || fail "uninstall should remove launch agent plist"
  assert_contains "$tmp/uninstall.out" "tmux session testcc was left running"
  assert_contains "$tmp/uninstall.out" "tmux kill-session -t testcc"
}

run_wsl2_contract() {
  local tmp home fakebin install_dir out log server_unit tmux_unit profile
  tmp="$(mktemp -d)"
  home="$tmp/home"
  fakebin="$tmp/fakebin"
  install_dir="$tmp/CcCompanion"
  out="$tmp/install.out"
  log="$tmp/fake.log"
  mkdir -p "$home"
  : > "$log"
  make_fakebin "$fakebin"

  PATH="$fakebin:$PATH" \
  HOME="$home" \
  CCC_FAKE_LOG="$log" \
  CCC_PLATFORM_OVERRIDE="wsl2" \
  CCC_INSTALLER_SKIP_PIP="1" \
  bash "$ROOT/install.sh" \
    --repo-url "$ROOT" \
    --dir "$install_dir" \
    --port 18999 \
    --session wincc \
    --yes \
    --dangerously-skip-permissions > "$out"

  server_unit="$home/.config/systemd/user/ccc-apns-server.service"
  tmux_unit="$home/.config/systemd/user/ccc-tmux.service"
  profile="$home/.profile"

  assert_file "$server_unit"
  assert_file "$tmux_unit"
  assert_contains "$server_unit" "$install_dir/apns-server"
  assert_contains "$tmux_unit" "claude --dangerously-skip-permissions"
  assert_contains "$install_dir/apns-server/config.toml" 'default_session = "wincc"'
  assert_contains "$out" "WSL2 note"
  assert_contains "$out" "portproxy"
  assert_file "$profile"
  assert_contains "$profile" "ccc-apns-server.service"
  assert_contains "$log" "systemctl --user enable ccc-apns-server.service ccc-tmux.service"
}

run_wsl2_no_systemd_contract() {
  local tmp home fakebin install_dir out log profile
  tmp="$(mktemp -d)"
  home="$tmp/home"
  fakebin="$tmp/fakebin"
  install_dir="$tmp/CcCompanion"
  out="$tmp/install.out"
  log="$tmp/fake.log"
  mkdir -p "$home"
  : > "$log"
  make_fakebin "$fakebin"
  rm -f "$fakebin/systemctl" "$fakebin/loginctl"

  PATH="$fakebin:$PATH" \
  HOME="$home" \
  CCC_FAKE_LOG="$log" \
  CCC_PLATFORM_OVERRIDE="wsl2" \
  CCC_INSTALLER_SKIP_PIP="1" \
  bash "$ROOT/install.sh" \
    --repo-url "$ROOT" \
    --dir "$install_dir" \
    --port 18998 \
    --session nosystemd \
    --yes \
    --skip-health > "$out"

  profile="$home/.profile"
  assert_file "$profile"
  assert_contains "$profile" "tmux has-session -t nosystemd"
  assert_contains "$profile" "tmux new-session -d -s nosystemd"
  assert_contains "$profile" "nohup \"$install_dir/apns-server/.venv/bin/python3\" \"$install_dir/apns-server/push.py\""
  assert_contains "$log" "nohup $install_dir/apns-server/.venv/bin/python3 $install_dir/apns-server/push.py"
}

run_existing_checkout_rerun_resumes_contract() {
  local tmp home fakebin install_dir log config
  tmp="$(mktemp -d)"
  home="$tmp/home"
  fakebin="$tmp/fakebin"
  install_dir="$tmp/CcCompanion"
  log="$tmp/fake.log"
  mkdir -p "$home"
  : > "$log"
  make_fakebin "$fakebin"
  git clone "$ROOT" "$install_dir" >/dev/null 2>&1

  PATH="$fakebin:$PATH" \
  HOME="$home" \
  CCC_FAKE_LOG="$log" \
  CCC_PLATFORM_OVERRIDE="macos" \
  CCC_INSTALLER_SKIP_PIP="1" \
  bash "$ROOT/install.sh" \
    --repo-url "$ROOT" \
    --dir "$install_dir" \
    --port 18796 \
    --session resumecc \
    --yes \
    --skip-service \
    --skip-health > "$tmp/rerun.out"

  config="$install_dir/apns-server/config.toml"
  assert_file "$config"
  assert_contains "$config" 'default_session = "resumecc"'
  assert_contains "$tmp/rerun.out" "Existing checkout found"
}

run_force_preserves_secret_contract() {
  local tmp home fakebin install_dir log config secret_before secret_after
  tmp="$(mktemp -d)"
  home="$tmp/home"
  fakebin="$tmp/fakebin"
  install_dir="$tmp/CcCompanion"
  log="$tmp/fake.log"
  mkdir -p "$home"
  : > "$log"
  make_fakebin "$fakebin"

  PATH="$fakebin:$PATH" \
  HOME="$home" \
  CCC_FAKE_LOG="$log" \
  CCC_PLATFORM_OVERRIDE="macos" \
  CCC_INSTALLER_SKIP_PIP="1" \
  bash "$ROOT/install.sh" \
    --repo-url "$ROOT" \
    --dir "$install_dir" \
    --port 18797 \
    --session force_a \
    --yes \
    --skip-service \
    --skip-health > /dev/null

  config="$install_dir/apns-server/config.toml"
  secret_before="$(config_value "$config" shared_secret)"

  PATH="$fakebin:$PATH" \
  HOME="$home" \
  CCC_FAKE_LOG="$log" \
  CCC_PLATFORM_OVERRIDE="macos" \
  CCC_INSTALLER_SKIP_PIP="1" \
  bash "$ROOT/install.sh" \
    --repo-url "$ROOT" \
    --dir "$install_dir" \
    --port 18798 \
    --session force_b \
    --yes \
    --force \
    --skip-service \
    --skip-health > "$tmp/force.out"

  secret_after="$(config_value "$config" shared_secret)"
  [[ "$secret_before" == "$secret_after" ]] || fail "--force should preserve existing shared_secret"
  assert_contains "$config" 'default_session = "force_b"'
  assert_contains "$tmp/force.out" "Preserving existing shared_secret"
}

run_destructive_path_guard_contract() {
  assert_contains "$ROOT/install.sh" "safe_rm_file()"
  assert_contains "$ROOT/install.sh" "safe_remove_launch_agent"
  assert_contains "$ROOT/install.sh" "safe_remove_systemd_unit"
  # shellcheck disable=SC2016
  assert_not_contains "$ROOT/install.sh" 'rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"'
  # shellcheck disable=SC2016
  assert_not_contains "$ROOT/install.sh" 'rm -f "$HOME/.config/systemd/user/$SERVER_UNIT" "$HOME/.config/systemd/user/$TMUX_UNIT"'
}

run_update_preserves_config_contract() {
  local tmp home fakebin install_dir log config before after out
  tmp="$(mktemp -d)"
  home="$tmp/home"
  fakebin="$tmp/fakebin"
  install_dir="$tmp/CcCompanion"
  log="$tmp/fake.log"
  mkdir -p "$home"
  : > "$log"
  make_fakebin "$fakebin"

  PATH="$fakebin:$PATH" \
  HOME="$home" \
  CCC_FAKE_LOG="$log" \
  CCC_PLATFORM_OVERRIDE="macos" \
  CCC_INSTALLER_SKIP_PIP="1" \
  bash "$ROOT/install.sh" \
    --repo-url "$ROOT" \
    --dir "$install_dir" \
    --port 18795 \
    --session updatecc \
    --yes > /dev/null

  config="$install_dir/apns-server/config.toml"
  echo '# user custom line' >> "$config"
  before="$(shasum "$config" | awk '{print $1}')"

  PATH="$fakebin:$PATH" \
  HOME="$home" \
  CCC_FAKE_LOG="$log" \
  CCC_PLATFORM_OVERRIDE="macos" \
  CCC_INSTALLER_SKIP_PIP="1" \
  bash "$install_dir/bin/ccc-update" --dir "$install_dir" --skip-service > "$tmp/update.out"

  after="$(shasum "$config" | awk '{print $1}')"
  [[ "$before" == "$after" ]] || fail "ccc-update changed config.toml"
  out="$tmp/update.out"
  assert_contains "$out" "config.toml is preserved"
  assert_contains "$out" "Recent changes"
}

run_macos_install_contract
run_wsl2_contract
run_wsl2_no_systemd_contract
run_existing_checkout_rerun_resumes_contract
run_force_preserves_secret_contract
run_destructive_path_guard_contract
run_update_preserves_config_contract
echo "installer contract tests passed"
