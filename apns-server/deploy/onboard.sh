#!/usr/bin/env bash
# Opia APNs server onboarding
# 阿眠拿到 .p8 + 4 件后 一条命令完成 Step 2
#
# 用法:
#   ./onboard.sh --p8 ~/Downloads/AuthKey_ABC1234567.p8 \
#                --team-id DEF7654321 \
#                --key-id  ABC1234567 \
#                [--bundle-id com.starryfield.OpiaCompanion]
#
# 做的事:
#   1 validate 输入
#   2 cp .p8 -> secrets/
#   3 写 config.toml
#   4 venv + pip install (如缺)
#   5 cp launchd plist -> ~/Library/LaunchAgents
#   6 launchctl bootstrap (重装等价)
#   7 wait + curl /health verify
#   8 跑测试套件 sanity check

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS_DIR="$ROOT/secrets"
CONFIG_PATH="$ROOT/config.toml"
EXAMPLE_PATH="$ROOT/config.example.toml"
VENV_DIR="$ROOT/.venv"
PLIST_SRC="$ROOT/deploy/com.opia.apns-server.plist"
PLIST_DST="$HOME/Library/LaunchAgents/com.opia.apns-server.plist"
LABEL="com.opia.apns-server"
HEALTH_URL="http://127.0.0.1:8795/health"

P8=""
TEAM_ID=""
KEY_ID=""
BUNDLE_ID="com.starryfield.OpiaCompanion"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --p8) P8="$2"; shift 2;;
    --team-id) TEAM_ID="$2"; shift 2;;
    --key-id) KEY_ID="$2"; shift 2;;
    --bundle-id) BUNDLE_ID="$2"; shift 2;;
    -h|--help) sed -n '2,18p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

[[ -z "$P8" || -z "$TEAM_ID" || -z "$KEY_ID" ]] && {
  echo "缺参数 跑 $0 --help" >&2; exit 1;
}
[[ ! -f "$P8" ]] && { echo ".p8 文件不存在: $P8" >&2; exit 1; }
[[ ${#TEAM_ID} -ne 10 ]] && { echo "Team ID 必须 10 位 收到: $TEAM_ID" >&2; exit 1; }
[[ ${#KEY_ID} -ne 10 ]] && { echo "Key ID 必须 10 位 收到: $KEY_ID" >&2; exit 1; }

echo "==> Step 1/8 输入 ok"
echo "    Team ID:   $TEAM_ID"
echo "    Key ID:    $KEY_ID"
echo "    Bundle ID: $BUNDLE_ID"
echo "    .p8:       $P8"

mkdir -p "$SECRETS_DIR"
P8_DST="$SECRETS_DIR/AuthKey_${KEY_ID}.p8"
cp "$P8" "$P8_DST"
chmod 600 "$P8_DST"
echo "==> Step 2/8 .p8 复制到 $P8_DST"

cp "$EXAMPLE_PATH" "$CONFIG_PATH"
python3 - <<PY
import re, pathlib
p = pathlib.Path("$CONFIG_PATH")
t = p.read_text()
t = t.replace("AuthKey_XXXXXXXXXX.p8", "AuthKey_${KEY_ID}.p8")
t = re.sub(r'team_id = "[^"]+"', 'team_id = "${TEAM_ID}"', t)
t = re.sub(r'key_id = "[^"]+"', 'key_id = "${KEY_ID}"', t)
t = re.sub(r'bundle_id = "[^"]+"', 'bundle_id = "${BUNDLE_ID}"', t)
p.write_text(t)
PY
echo "==> Step 3/8 config.toml 写好"

if [[ ! -d "$VENV_DIR" ]]; then
  python3 -m venv "$VENV_DIR"
  echo "==> Step 4/8 venv 创建"
else
  echo "==> Step 4/8 venv 已存在 跳过"
fi
"$VENV_DIR/bin/pip" install -q -r "$ROOT/requirements.txt"
echo "==> Step 4/8 依赖装好"

mkdir -p "$HOME/Library/LaunchAgents"
cp "$PLIST_SRC" "$PLIST_DST"
echo "==> Step 5/8 plist 拷贝"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
launchctl enable "gui/$(id -u)/$LABEL" 2>/dev/null || true
echo "==> Step 6/8 launchd 装好"

echo -n "==> Step 7/8 等 server 起来"
for i in {1..15}; do
  sleep 1
  if curl -s -m 2 "$HEALTH_URL" >/dev/null 2>&1; then
    echo " ok"
    curl -s "$HEALTH_URL"
    echo
    break
  fi
  echo -n "."
  if [[ $i -eq 15 ]]; then
    echo " 失败"
    echo "    看 server.err.log: tail $ROOT/server.err.log" >&2
    exit 1
  fi
done

echo "==> Step 8/8 跑测试套件"
cd "$ROOT"
"$VENV_DIR/bin/python3" -m pytest tests/ -q || {
  echo "    测试有 fail 但 server 已经跑起来 — 你先用着 我后面看" >&2
}

echo
echo "==> 全部完成"
echo "    server: $HEALTH_URL"
echo "    日志:   tail -f $ROOT/server.log"
echo "    err:    tail -f $ROOT/server.err.log"
echo "    test push: ~/scripts/opia_push_to_phone.sh spoke '想你了' orange"
