#!/bin/bash
# CcCompanion Claude Code Stop hook
#
# Trigger: Claude Code 自动在每个 chain turn 结束时调一次. 这里读 transcript
# 抓最近这一 turn 的 assistant 文本, POST 给本地 apns-server /chat/append,
# server 再 push 到 iPhone.
#
# 配置方式 (一次性):
#   1. cp 这一份到 ~/.claude/hooks/ccc_stop_hook.sh
#   2. chmod +x ~/.claude/hooks/ccc_stop_hook.sh
#   3. 编辑 ~/.claude/settings.json 加 hook 引用 (注意 nested hooks array):
#      {
#        "hooks": {
#          "Stop": [
#            {
#              "matcher": "",
#              "hooks": [
#                {
#                  "type": "command",
#                  "command": "$HOME/.claude/hooks/ccc_stop_hook.sh"
#                }
#              ]
#            }
#          ]
#        }
#      }
#   4. 重启 Claude Code (退出 tmux session 重进, 让 hook config 生效)
#
# 验证 hook 跑通:
#   iPhone 端 ccc 发一条 "hi"; Mac 上 cc 回复后, 看
#   tail -f /tmp/ccc_stop_hook.log
#   应该看到 "posted to /chat/append ok"
#
# Env:
#   CCC_SERVER_URL  default http://127.0.0.1:8795
#   CCC_AUTH_TOKEN  shared_secret 跟 server config.toml 对齐 (写接口必须)

set -uo pipefail

SERVER_URL="${CCC_SERVER_URL:-http://127.0.0.1:8795}"
AUTH_TOKEN="${CCC_AUTH_TOKEN:-}"
# 兜底从 server 自动生成的 secret 文件读
if [ -z "$AUTH_TOKEN" ] && [ -f "$HOME/.ots/secret" ]; then
    AUTH_TOKEN=$(cat "$HOME/.ots/secret" 2>/dev/null)
fi

LOG_PATH="/tmp/ccc_stop_hook.log"
log() { echo "[$(date +%Y-%m-%d\ %H:%M:%S)] $*" >> "$LOG_PATH"; }

# Claude Code 通过 stdin 传 {session_id, transcript_path, cwd, hook_event_name,
# stop_hook_active, last_assistant_message?}.
# 新版 Claude Code 直接传 last_assistant_message; 没有时 fallback 反扫 transcript.
INPUT=$(cat 2>/dev/null || echo "{}")

# 一次性 parse 出 transcript_path 加 last_assistant_message
PARSED=$(echo "$INPUT" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read() or "{}")
    print(d.get("transcript_path") or "")
    print(d.get("last_assistant_message") or "")
except Exception:
    print("")
    print("")
' 2>/dev/null)
TRANSCRIPT_PATH=$(echo "$PARSED" | sed -n '1p')
DIRECT_LAST=$(echo "$PARSED" | sed -n '2,$p')

if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
    log "no transcript path (stdin=$INPUT)"
    exit 0
fi

# Prefer stdin last_assistant_message (新版 Claude Code 直接给), fallback transcript
if [ -n "$DIRECT_LAST" ]; then
    LAST_ASSISTANT="$DIRECT_LAST"
    log "using stdin last_assistant_message (chars=${#LAST_ASSISTANT})"
else
    # Claude Code transcript flush 慢 — 等 file size 稳定 (连续两次相等 或最长 ~3 秒)
    LAST_SIZE=-1
    STABLE_COUNT=0
    for i in 1 2 3 4 5 6 7 8 9 10; do
        sleep 0.3
        CUR_SIZE=$(stat -f '%z' "$TRANSCRIPT_PATH" 2>/dev/null \
                || stat -c '%s' "$TRANSCRIPT_PATH" 2>/dev/null \
                || echo "0")
        if [ "$CUR_SIZE" = "$LAST_SIZE" ]; then
            STABLE_COUNT=$((STABLE_COUNT + 1))
            [ "$STABLE_COUNT" -ge 2 ] && break
        else
            STABLE_COUNT=0
        fi
        LAST_SIZE=$CUR_SIZE
    done

    # transcript 是 JSONL 一行一条 message
    # 倒着读 抓自上次 user 以来的所有 assistant text part 然后 join
    # Linux 没 tail -r 用 tac
    REVERSE_CAT="tail -r"
    if ! command -v tail >/dev/null 2>&1 || ! tail -r /dev/null 2>/dev/null; then
        REVERSE_CAT="tac"
    fi
    LAST_ASSISTANT=$($REVERSE_CAT "$TRANSCRIPT_PATH" | python3 -c '
import json, sys
collected = []
for line in sys.stdin:
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    t = obj.get("type")
    if t == "user":
        break
    if t == "assistant":
        msg = obj.get("message", {})
        content = msg.get("content", [])
        text_parts = [
            c.get("text", "")
            for c in content
            if isinstance(c, dict) and c.get("type") == "text" and c.get("text")
        ]
        if text_parts:
            collected.append("\n".join(text_parts))
collected.reverse()
print("\n\n".join(collected))
' 2>/dev/null)
fi

if [ -z "$LAST_ASSISTANT" ]; then
    log "empty assistant text — skip"
    exit 0
fi

# POST 到 /chat/append
# Fix (VPS feedback 2026-06-24 #4 dedup): every stop-hook POST carries a unique client_msg_id
# so the server dedupes on the cmid key, not on content. Without it two identical short replies
# (e.g. two "Got it.") within the fallback window collided and the second was dropped. The id is
# generated ONCE here and reused across the retry loop below, so transient-error retries still
# dedupe to the same record while genuinely separate turns each get their own id. uuid4().hex is
# Linux/macOS portable — no dependency on `uuidgen` being installed.
PAYLOAD=$(ASSISTANT_TEXT="$LAST_ASSISTANT" TRANSCRIPT_PATH="$TRANSCRIPT_PATH" python3 -c '
import json, os, datetime, uuid, hashlib
ts = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
_tp = os.environ.get("TRANSCRIPT_PATH", "")
_sess = hashlib.sha1(_tp.encode("utf-8")).hexdigest()[:8] if _tp else "nosess"
client_msg_id = f"stop-hook-{_sess}-{uuid.uuid4().hex}"
print(json.dumps({
    "role": "assistant",
    "text": os.environ["ASSISTANT_TEXT"],
    "source": "ccc-stop-hook",
    "ts": ts,
    "client_msg_id": client_msg_id,
}))
')

# retry transient network errors (000/502/503/504), don't retry 401 (auth)
attempt=0
while [ $attempt -lt 3 ]; do
    HTTP_CODE=$(curl -s -o /tmp/ccc_stop_hook.curlout -w "%{http_code}" \
        -X POST "$SERVER_URL/chat/append" \
        -H "Content-Type: application/json" \
        -H "X-Auth-Token: $AUTH_TOKEN" \
        --data "$PAYLOAD" \
        --max-time 8 2>>"$LOG_PATH")
    case "$HTTP_CODE" in
        200) break ;;
        000|502|503|504)
            attempt=$((attempt + 1))
            log "POST retry $attempt http=$HTTP_CODE"
            sleep 1
            ;;
        401)
            log "POST 401 unauthorized — check CCC_AUTH_TOKEN or ~/.ots/secret matches server config.toml shared_secret"
            break
            ;;
        *)
            break
            ;;
    esac
done

if [ "$HTTP_CODE" = "200" ]; then
    log "posted to /chat/append ok (chars=${#LAST_ASSISTANT})"
else
    log "POST /chat/append failed http=$HTTP_CODE body=$(cat /tmp/ccc_stop_hook.curlout 2>/dev/null | head -c 200)"
fi

exit 0
