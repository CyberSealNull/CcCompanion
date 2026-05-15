"""
Cc APNs server - Live Activity push 主入口

听三个 endpoint
  POST /register-token    iPhone app 启动 Live Activity 后上报 push token
  POST /unregister-token  iPhone app 结束 Live Activity 上报
  POST /push              本机其他脚本 (bus_stop_hook 等) 触发 push 给所有 active iPhone
  GET  /health            健康检查

POST /push 触发 SPOKE / 状态切换 等
请求 body
{
  "event": "update" | "end",
  "state": "listening" | "thinking" | "spoken",
  "preview": "想你了",
  "color": "orange",
  "message_count": 5,
  "alert_title": "Cc" (optional),
  "alert_body": "想你了" (optional)
}

成功返回 200 + 每个 token 的 push 结果
失败 token 自动从 store 移除 (Apple 410 = 失效)

启动
  python3 push.py [--config config.toml] [--sandbox]

部署
  launchd plist 在 deploy/com.cccompanion.apns-server.plist
"""
from __future__ import annotations

import argparse
from collections import OrderedDict
import hashlib
import ipaddress
import json
import logging
import os
from datetime import datetime, timezone
import sys
import threading
import time
import tomllib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Sequence

from jwt_helper import APNsJWT
from apns_client import APNsClient, APNsResponse
from token_store import TokenStore
from device_token_store import DeviceTokenStore
from task_queue import TaskQueue
from chat_history import ChatHistory, EphemeralTaskBuffer
from diary_stream import DiaryStream
from group_chat import GroupChatStore
from calendar_store import CalendarStore, CATEGORIES, CATEGORY_LABELS
from rp_history import RPHistory, validate_sid as validate_rp_sid
from diary import Diary
from favorites import Favorites
from worklog import Worklog
from reminders import ReminderStore
from timeline import Timeline
from tts import TTS
from settings import Settings
from usage import UsageReader
import todos as todos_mod
from studyroom import StudyroomDB
import subprocess
import threading

try:
    import rp_session_manager
except ImportError:
    rp_session_manager = None


HERE = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = HERE / "config.toml"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("cc-apns-server")


def spawn_logged(
    args: Sequence[str],
    *,
    context: str,
    timeout: float = 10.0,
) -> subprocess.Popen[str]:
    """Start a background subprocess and log stderr, non-zero exits, and timeouts."""
    try:
        proc = subprocess.Popen(
            list(args),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
    except Exception:
        logger.exception("%s spawn failed", context)
        raise

    def _watch() -> None:
        try:
            _, stderr = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            _, stderr = proc.communicate()
            logger.warning(
                "%s timed out after %.1fs; killed pid=%s stderr=%s",
                context,
                timeout,
                proc.pid,
                (stderr or "").strip(),
            )
            return
        stderr_text = (stderr or "").strip()
        if proc.returncode:
            logger.warning(
                "%s exited rc=%s pid=%s stderr=%s",
                context,
                proc.returncode,
                proc.pid,
                stderr_text,
            )
        elif stderr_text:
            logger.info("%s stderr=%s", context, stderr_text)

    threading.Thread(
        target=_watch,
        daemon=True,
        name=f"spawn-watch:{context[:32]}",
    ).start()
    return proc


# P0-3: auto-generate and persist shared_secret if not configured
def _load_or_create_secret() -> str:
    """Load existing auto-generated secret or create one. Stored at ~/.ots/secret (mode 0600)."""
    secret_dir = Path.home() / ".ots"
    secret_file = secret_dir / "secret"
    try:
        secret_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        if secret_file.exists():
            s = secret_file.read_text().strip()
            if s:
                return s
        import secrets as _secrets
        new_secret = _secrets.token_hex(32)
        secret_file.write_text(new_secret)
        secret_file.chmod(0o600)
        logger.info("P0-3: auto-generated shared_secret written to %s", secret_file)
        logger.info("P0-3: SHARED SECRET: %s  ← copy to your OTS app onboarding", new_secret)
        return new_secret
    except Exception as e:
        logger.warning("P0-3: could not auto-generate secret: %s", e)
        return ""


WEB_CHAT_HTML = r"""<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Cc Chat</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { height: 100%; }
  body { background: #1E1E1E; color: #fff; font: 14px -apple-system, "PingFang SC", "Segoe UI", system-ui, sans-serif; display: flex; flex-direction: column; }
  header { padding: 10px 16px; background: #111; border-bottom: 1px solid #333; display: flex; align-items: center; gap: 8px; }
  header .dot { width: 8px; height: 8px; border-radius: 50%; background: #5cff7e; }
  header .title { font-weight: 600; }
  header .meta { color: #888; font-size: 12px; margin-left: auto; }
  #log { flex: 1; overflow-y: auto; padding: 16px; }
  .row { margin: 8px 0; max-width: 80%; line-height: 1.5; }
  .row.user { margin-left: auto; }
  .row .who { font-size: 11px; color: #888; margin-bottom: 2px; }
  .row.user .who { text-align: right; }
  .bubble { padding: 8px 12px; border-radius: 10px; word-wrap: break-word; white-space: pre-wrap; }
  .row.assistant .bubble { background: #2a2a2a; color: #fff; }
  .row.user .bubble { background: #d96d36; color: #fff; }
  .row .ts { font-size: 10px; color: #666; margin-top: 2px; }
  .row.user .ts { text-align: right; }
  footer { padding: 10px; background: #111; border-top: 1px solid #333; display: flex; gap: 8px; }
  textarea { flex: 1; background: #222; color: #fff; border: 1px solid #333; border-radius: 6px; padding: 8px; font: inherit; resize: none; min-height: 38px; max-height: 120px; }
  button { background: #d96d36; color: #fff; border: 0; border-radius: 6px; padding: 0 18px; font: inherit; cursor: pointer; }
  button:disabled { opacity: .4; cursor: default; }
  .empty { text-align: center; color: #666; padding: 40px; }
</style>
</head>
<body>
<header>
  <span class="dot" id="dot"></span>
  <span class="title">Cc · Web Chat</span>
  <span class="meta" id="meta">加载中...</span>
</header>
<main id="log"><div class="empty">连接中...</div></main>
<footer>
  <textarea id="input" placeholder="发消息给 Cc (Cmd/Ctrl + Enter 发送)" rows="1"></textarea>
  <button id="send">发送</button>
</footer>
<script>
  const log = document.getElementById('log');
  const meta = document.getElementById('meta');
  const dot = document.getElementById('dot');
  const input = document.getElementById('input');
  const sendBtn = document.getElementById('send');
  let lastTs = null;
  let seenKeys = new Set();
  let firstLoad = true;

  function fmtTime(ts) {
    if (!ts) return '';
    try {
      const d = new Date(ts);
      const pad = n => String(n).padStart(2, '0');
      return pad(d.getHours()) + ':' + pad(d.getMinutes());
    } catch (e) { return ts.slice(11, 16); }
  }

  function renderRecord(r) {
    const key = (r.ts || '') + '|' + (r.role || '') + '|' + (r.text || '').slice(0, 64);
    if (seenKeys.has(key)) return;
    seenKeys.add(key);
    const row = document.createElement('div');
    row.className = 'row ' + (r.role === 'user' ? 'user' : 'assistant');
    const who = document.createElement('div');
    who.className = 'who';
    who.textContent = r.role === 'user' ? '你' : 'Cc';
    const bubble = document.createElement('div');
    bubble.className = 'bubble';
    bubble.textContent = r.text || '';
    const ts = document.createElement('div');
    ts.className = 'ts';
    ts.textContent = fmtTime(r.ts);
    row.appendChild(who); row.appendChild(bubble); row.appendChild(ts);
    log.appendChild(row);
  }

  async function poll() {
    try {
      const url = lastTs ? '/chat/history?since=' + encodeURIComponent(lastTs) : '/chat/history?limit=200';
      const res = await fetch(url, { cache: 'no-store' });
      const data = await res.json();
      if (data.ok && Array.isArray(data.records)) {
        if (firstLoad) {
          log.innerHTML = '';
          firstLoad = false;
        }
        for (const r of data.records) {
          renderRecord(r);
          if (r.ts && (!lastTs || r.ts > lastTs)) lastTs = r.ts;
        }
        log.scrollTop = log.scrollHeight;
        meta.textContent = '在线 · ' + (lastTs ? fmtTime(lastTs) : '--');
        dot.style.background = '#5cff7e';
      }
    } catch (e) {
      meta.textContent = '断线 重试中';
      dot.style.background = '#ff5c5c';
    }
  }

  async function send() {
    const text = input.value.trim();
    if (!text) return;
    sendBtn.disabled = true;
    try {
      const res = await fetch('/chat/send', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text })
      });
      if (res.ok) {
        input.value = '';
        await poll();
      } else {
        alert('发送失败 ' + res.status);
      }
    } catch (e) {
      alert('网络出错 ' + e.message);
    } finally {
      sendBtn.disabled = false;
      input.focus();
    }
  }

  sendBtn.addEventListener('click', send);
  input.addEventListener('keydown', e => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      send();
    }
  });

  poll();
  setInterval(poll, 2000);
  input.focus();
</script>
</body>
</html>
"""


class ServerState:
    def __init__(self, config: dict[str, Any], sandbox_override: bool | None = None):
        apns_cfg = config["apns"]
        self.bundle_id: str = apns_cfg["bundle_id"]
        self.team_id: str = apns_cfg["team_id"]
        self.key_id: str = apns_cfg["key_id"]
        self.p8_path: str = apns_cfg["p8_path"]
        self.sandbox: bool = (
            sandbox_override
            if sandbox_override is not None
            else apns_cfg.get("sandbox", True)
        )
        self.live_activity_disabled: bool = bool(
            apns_cfg.get(
                "live_activity_disabled",
                os.environ.get("LIVE_ACTIVITY_DISABLED") == "1",
            )
        )

        server_cfg = config.get("server", {})
        self.host: str = server_cfg.get("host", "127.0.0.1")
        self.port: int = int(server_cfg.get("port", 8795))
        self.token_store_path: str = server_cfg.get(
            "token_store_path", str(HERE / "tokens" / "active.json")
        )
        # P0-3: auto-generate secret if not set
        raw_secret = server_cfg.get("shared_secret") or ""
        if not raw_secret:
            raw_secret = _load_or_create_secret()
        self.shared_secret: str | None = raw_secret or None
        # P0-1: strict_auth defaults to True (secure-by-default for CcCompanion community release)
        self.strict_auth: bool = bool(server_cfg.get("strict_auth", True))
        self.allow_public_bind: bool = bool(server_cfg.get("allow_public_bind", False))
        self.allow_remote_control: bool = bool(server_cfg.get("allow_remote_control", False))
        self.allowed_ips: list[str] = list(server_cfg.get("allowed_ips", []) or [])

        self.jwt = APNsJWT(
            p8_path=self.p8_path,
            key_id=self.key_id,
            team_id=self.team_id,
        )
        # primary client 跟 self.sandbox 配合 (默认是 config 里设的)
        self.client = APNsClient(
            bundle_id=self.bundle_id,
            jwt_provider=self.jwt,
            sandbox=self.sandbox,
            live_activity_disabled=self.live_activity_disabled,
        )
        # alt client 跟 primary 相反 当 BadDeviceToken 时 fallback 试这个
        # 解 5-1 BadDeviceToken 反复问题 — token 的 endpoint 不一定跟 server 配置一致
        # (例 TestFlight 通常 prod 但开发 build 是 sandbox 一台 device 在两种 build 间切会改 endpoint)
        self.client_alt = APNsClient(
            bundle_id=self.bundle_id,
            jwt_provider=self.jwt,
            sandbox=not self.sandbox,
            live_activity_disabled=self.live_activity_disabled,
        )
        self._primary_endpoint = "sandbox" if self.sandbox else "prod"
        self._alt_endpoint = "prod" if self.sandbox else "sandbox"

        self.tokens = TokenStore(self.token_store_path)

        # standard remote notification device tokens (非 Live Activity)
        device_tokens_path = Path(self.token_store_path).parent / "device_tokens.jsonl"
        self.device_tokens = DeviceTokenStore(device_tokens_path)
        # 通知推送 client 强制走 production (device token 的 endpoint 跟 Live Activity 独立)
        self.notification_client = APNsClient(
            bundle_id=self.bundle_id,
            jwt_provider=self.jwt,
            sandbox=False,
        )

        # task queue 持久化跟 token 同目录
        task_queue_path = Path(self.token_store_path).parent / "task_queue.json"
        self.tasks = TaskQueue(task_queue_path)

        # chat history 持久化跟 token 同目录
        chat_history_path = Path(self.token_store_path).parent / "chat_history.jsonl"
        self.chat = ChatHistory(chat_history_path)
        group_chat_path = Path(self.token_store_path).parent / "group_chat.jsonl"
        group_state_path = Path(self.token_store_path).parent / "group_state.json"
        self.group_chat = GroupChatStore(group_chat_path, group_state_path)
        calendar_path = Path(self.token_store_path).parent / "calendar_events.jsonl"
        self.calendar = CalendarStore(calendar_path)
        self.rp_history = RPHistory("/tmp")
        self.task_buffer = EphemeralTaskBuffer(capacity=100)
        # Handy-Clawd pet state (2026-05-08 用户 push)
        from pet_state import PetState, PetStateBus, PetBubbleBus, PetActivityBus
        pet_state_path = Path(self.token_store_path).parent / "pet_state.json"
        self.pet = PetState(pet_state_path)
        self.pet_bus = PetStateBus()
        self.pet_bubble_bus = PetBubbleBus()
        self.pet_activity_bus = PetActivityBus()
        # typing indicator 状态 (内存 不持久化)
        self.typing_state: dict[str, Any] = {"is_typing": False, "since": None}
        # 书房 v1 (2026-05-09) — vault-aware project dashboard. read-only db (indexer 写)
        studyroom_db_path = HERE / "state" / "studyroom.db"
        self.studyroom = StudyroomDB(studyroom_db_path)
        self.bus_send_path = server_cfg.get(
            "bus_send_path", str(Path.home() / "scripts" / "bus_send.py")
        )
        # 附件 (图片 / 文件) 存储目录
        attachments_dir = Path(self.token_store_path).expanduser().parent / "attachments"
        attachments_dir.mkdir(parents=True, exist_ok=True)
        self.attachments_dir = attachments_dir
        # 用户偏好 settings (TTS toggle 等)
        settings_path = Path(self.token_store_path).expanduser().parent / "settings.json"
        self.settings = Settings(settings_path)
        # 当前活跃 chain session (slash /switch 持久化)
        active_session_path = Path(self.token_store_path).expanduser().parent / "active_session.json"
        self.active_session_path = active_session_path
        self.active_session: str = "opia"  # default
        if active_session_path.exists():
            try:
                _as = json.loads(active_session_path.read_text())
                self.active_session = _as.get("active_sid", "opia")
            except Exception:
                pass
        self.diary = Diary(Path("~/Documents/星原/眠的小家/日记/").expanduser())
        # 2026-05-11 OTS Diary tab — chain↔用户 chat-style journaling stream.
        # Distinct from `self.diary` (vault markdown CRUD) and `self.chat`
        # (open-ended Cc chat). Per-day JSONL under apns-server/diary_chat/.
        diary_stream_dir = Path(self.token_store_path).expanduser().parent / "diary_chat"
        self.diary_stream = DiaryStream(diary_stream_dir)
        self.favorites = Favorites(
            jsonl_path=Path(self.token_store_path).expanduser().parent / "favorites.jsonl",
            vault_path=Path("~/Documents/星原/眠的小家/收藏夹/").expanduser(),
        )
        self.usage = UsageReader()
        self.worklog = Worklog()
        self.timeline = Timeline(self.diary, self.chat, self.tasks, self.worklog)
        # 五子棋 client_msg_id 去重缓存 (内存 LRU 100 条)
        self.gomoku_msg_cache: OrderedDict[str, dict] = OrderedDict()
        # 定时 reminder 队列
        reminders_path = Path(self.token_store_path).parent / "reminders.jsonl"
        self.reminders = ReminderStore(reminders_path)
        # 服务器启动时间 (unix timestamp) — 用于 uptime 计算
        self.started_at: float = time.time()
        # 完整 config 引用 (anthropic dashboard url 等)
        self.config: dict[str, Any] = config

        logger.info(
            "loaded bundle_id=%s sandbox=%s store=%s tokens=%d tasks_active=%s",
            self.bundle_id,
            self.sandbox,
            self.token_store_path,
            len(self.tokens.all_active()),
            self.tasks.snapshot()["active"]["title"] if self.tasks.snapshot()["active"] else None,
        )

    def shutdown(self):
        self.client.close()


# ---------- helpers ----------


def _state_to_payload(body: dict[str, Any]) -> dict[str, Any]:
    """body -> APNs content-state 字段名跟 swift 端 ActivityAttributes.ContentState 对齐

    必须填 ContentState 所有 non-optional 字段否则 Swift Codable decode 失败
    ActivityKit 静默丢弃 update widget 不刷新.

    ContentState non-optional: status / unreadCount
    ContentState optional: lastMessagePreview / sourceChannel / lastUpdate
    """
    cs: dict[str, Any] = {
        # non-optional 默认值
        "status": "idle",
        "unreadCount": 0,
    }

    state = body.get("state")
    if state:
        # client 兼容: "spoken" -> "spoke" (旧 script alias)
        cs["status"] = "spoke" if state == "spoken" else state
    if "preview" in body:
        cs["lastMessagePreview"] = str(body["preview"])[:200]
    if "channel" in body:
        cs["sourceChannel"] = str(body["channel"])
    if "unread" in body:
        cs["unreadCount"] = int(body["unread"])
    elif "message_count" in body:
        cs["unreadCount"] = int(body["message_count"])

    # 任务进度字段 (A+C 模式)
    if "task_label" in body:
        cs["taskLabel"] = str(body["task_label"])[:12]
    if "task_title" in body:
        cs["taskTitle"] = str(body["task_title"])[:50]
    if "task_progress" in body:
        cs["taskProgress"] = float(body["task_progress"])
    if "task_current" in body:
        cs["taskCurrent"] = int(body["task_current"])
    if "task_total" in body:
        cs["taskTotal"] = int(body["task_total"])
    if "task_step" in body:
        cs["taskStep"] = str(body["task_step"])[:80]

    if "completed_titles" in body:
        cs["completedTitles"] = [str(t)[:30] for t in body["completed_titles"]][:5]

    return cs


def load_config(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise FileNotFoundError(
            f"config not found at {path}\n"
            f"copy config.example.toml -> config.toml + 填入 .p8 / Team ID / Key ID"
        )
    return tomllib.loads(path.read_text())


def cleanup_loop(state: ServerState, interval: float = 1800):
    """每 30 min cleanup stale tokens"""
    while True:
        try:
            time.sleep(interval)
            n = state.tokens.cleanup_stale()
            if n:
                logger.info("cleanup removed %d stale tokens", n)
        except Exception:
            logger.exception("cleanup loop error")


def _persist_active_session(state: "ServerState") -> None:
    """Write active_session.json for persistence across server restarts."""
    try:
        from datetime import datetime as _dt
        data = {"active_sid": state.active_session, "updated_at": _dt.now().isoformat(timespec="seconds")}
        state.active_session_path.write_text(json.dumps(data))
    except Exception as e:
        logger.warning("persist_active_session failed: %s", e)
