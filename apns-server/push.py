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
from typing import Any

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


HERE = Path(__file__).resolve().parent
DEFAULT_CONFIG = HERE / "config.toml"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("cc-apns-server")


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
        )
        # alt client 跟 primary 相反 当 BadDeviceToken 时 fallback 试这个
        # 解 5-1 BadDeviceToken 反复问题 — token 的 endpoint 不一定跟 server 配置一致
        # (例 TestFlight 通常 prod 但开发 build 是 sandbox 一台 device 在两种 build 间切会改 endpoint)
        self.client_alt = APNsClient(
            bundle_id=self.bundle_id,
            jwt_provider=self.jwt,
            sandbox=not self.sandbox,
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


# ---------- HTTP handler ----------


class PushHandler(BaseHTTPRequestHandler):
    state: ServerState  # set by run_server before serving

    server_version = "CcAPNsServer/0.1"

    def log_message(self, format: str, *args):
        logger.info("%s %s", self.address_string(), format % args)

    def _read_body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", 0))
        if not length:
            return {}
        raw = self.rfile.read(length)
        return json.loads(raw)

    def _check_auth(self) -> bool:
        if self._auth_matches():
            return True
        return not self.state.strict_auth

    def _auth_matches(self) -> bool:
        if not self.state.shared_secret:
            return True
        token = self.headers.get("X-Auth-Token", "") or self.headers.get("X-Auth", "")
        return token == self.state.shared_secret

    def _require_auth(self) -> bool:
        if self._auth_matches():
            return True
        if not self.state.strict_auth:
            ip = self.client_address[0] if self.client_address else "unknown"
            logger.warning(
                "unauthenticated request allowed strict_auth=false ip=%s method=%s path=%s",
                ip,
                self.command,
                self.path,
            )
            return True
        self._send_json(401, {"error": "unauthorized"})
        return False

    def _require_write_auth(self) -> bool:
        return self._require_auth()

    def _is_public_get(self) -> bool:
        return self.path in {"/health", "/version"}

    def _check_ip_allowed(self) -> bool:
        allowed = self.state.allowed_ips
        if not allowed:
            return True
        ip_text = self.client_address[0] if self.client_address else ""
        try:
            client_ip = ipaddress.ip_address(ip_text)
        except ValueError:
            logger.warning("blocked_ip invalid ip=%s path=%s", ip_text, self.path)
            self._send_json(403, {"error": "ip not allowed"})
            return False
        for item in allowed:
            try:
                if "/" in item:
                    if client_ip in ipaddress.ip_network(item, strict=False):
                        return True
                elif client_ip == ipaddress.ip_address(item):
                    return True
            except ValueError:
                logger.warning("invalid allowed_ips entry ignored: %s", item)
        logger.warning("blocked_ip ip=%s path=%s", ip_text, self.path)
        self._send_json(403, {"error": "ip not allowed"})
        return False

    def _send_json(self, status: int, body: dict[str, Any]):
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    # ---------- routes ----------

    def do_GET(self):
        if not self._is_public_get() and not self._check_ip_allowed():
            return
        if not self._is_public_get() and not self._require_auth():
            return
        if self.path == "/task/list":
            self._send_json(200, self.state.tasks.snapshot())
            return
        if self.path == "/usage/active":
            self._handle_usage_active()
            return
        if self.path == "/usage":
            self._handle_usage_overview()
            return
        if self.path.startswith("/chat/history"):
            self._handle_chat_history()
            return
        if self.path == "/pet/state":
            self._handle_pet_state_get()
            return
        if self.path == "/pet/stream":
            self._handle_pet_stream()
            return
        if self.path == "/pet/animations":
            self._handle_pet_animations()
            return
        if self.path == "/pet/activity_stream":
            self._handle_pet_activity_stream()
            return
        # 书房 v1 (2026-05-09)
        if self.path == "/studyroom/today":
            self._handle_studyroom_today()
            return
        if self.path == "/studyroom/projects":
            self._handle_studyroom_projects()
            return
        if self.path.startswith("/studyroom/project/"):
            self._handle_studyroom_project()
            return
        if self.path == "/group/roster":
            self._handle_group_roster()
            return
        if self.path == "/group/status":
            self._handle_group_status()
            return
        if self.path == "/group/tasks":
            self._handle_group_tasks()
            return
        if self.path.startswith("/group/list") or self.path.startswith("/group/history"):
            self._handle_group_history()
            return
        if self.path.startswith("/group/poll"):
            self._handle_group_poll()
            return
        if self.path.startswith("/rp/history"):
            self._handle_rp_history()
            return
        if self.path == "/rp/list":
            self._handle_rp_list()
            return
        if self.path.startswith("/chat/poll"):
            self._handle_chat_poll()
            return
        if self.path.startswith("/diary/poll"):
            self._handle_diary_poll()
            return
        if self.path.startswith("/diary/history"):
            self._handle_diary_history()
            return
        if self.path.startswith("/chat/search"):
            self._handle_chat_search()
            return
        if self.path.startswith("/diary/calendar"):
            self._handle_diary_calendar()
            return
        if self.path.startswith("/diary/get"):
            self._handle_diary_get()
            return
        if self.path.startswith("/diary/search"):
            self._handle_diary_search()
            return
        if self.path.startswith("/diary/on-this-day"):
            self._handle_diary_on_this_day()
            return
        if self.path.startswith("/diary/streak"):
            self._handle_diary_streak()
            return
        if self.path.startswith("/diary/prompts"):
            self._handle_diary_prompts()
            return
        if self.path.startswith("/timeline/events"):
            self._handle_timeline_events()
            return
        if self.path.startswith("/timeline/aggregate"):
            self._handle_timeline_aggregate()
            return
        if self.path.startswith("/timeline"):
            self._handle_timeline()
            return
        if self.path.startswith("/favorites/list"):
            self._handle_favorites_list()
            return
        if self.path.startswith("/favorites/get"):
            self._handle_favorites_get()
            return
        if self.path == "/chat/typing":
            ts = self.state.typing_state
            if ts.get("is_typing") and ts.get("since"):
                try:
                    since_dt = datetime.fromisoformat(ts["since"])
                    age = (datetime.now(timezone.utc).astimezone() - since_dt).total_seconds()
                    if age > 120:
                        self.state.typing_state = {"is_typing": False, "since": None}
                except Exception:
                    pass
            self._send_json(200, {"ok": True, **self.state.typing_state})
            return
        if self.path == "/chat/status":
            self._handle_chat_status()
            return
        if self.path == "/settings":
            self._send_json(200, {"ok": True, "settings": self.state.settings.snapshot()})
            return
        if self.path == "/todos":
            try:
                self._send_json(200, {"ok": True, "sections": todos_mod.collect_all()})
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        if self.path == "/drivers/state":
            try:
                state_path = os.path.expanduser("~/CcCompanion/opia_drivers_state.json")
                shadow_path = os.path.expanduser("~/CcCompanion/heartbeat_shadow.jsonl")
                events_path = os.path.expanduser("~/CcCompanion/heartbeat_events.jsonl")
                state_data = {}
                if os.path.exists(state_path):
                    with open(state_path, encoding="utf-8") as f:
                        state_data = json.load(f)
                recent_shadow = []
                if os.path.exists(shadow_path):
                    with open(shadow_path, encoding="utf-8") as f:
                        lines = f.readlines()[-10:]
                        for line in lines:
                            try:
                                recent_shadow.append(json.loads(line))
                            except Exception:
                                continue
                recent_events = []
                if os.path.exists(events_path):
                    with open(events_path, encoding="utf-8") as f:
                        lines = f.readlines()[-10:]
                        for line in lines:
                            try:
                                recent_events.append(json.loads(line))
                            except Exception:
                                continue
                self._send_json(200, {
                    "ok": True,
                    "state": state_data,
                    "recent_shadow": recent_shadow,
                    "recent_events": recent_events,
                })
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        if self.path.startswith("/tmux/capture"):
            # P0-2: remote control disabled by default
            if not self.state.allow_remote_control:
                self._send_json(403, {"error": "remote_control disabled", "hint": "set allow_remote_control=true in config.toml"})
                return
            self._handle_tmux_capture()
            return
        if self.path == "/tmux/sessions":
            if not self.state.allow_remote_control:
                self._send_json(403, {"error": "remote_control disabled"})
                return
            self._handle_tmux_sessions()
            return
        if self.path == "/chain/sessions":
            # Phase B slash /list: list all tmux sessions + mark active one
            if not self.state.allow_remote_control:
                self._send_json(403, {"error": "remote_control disabled"})
                return
            self._handle_chain_sessions_get()
            return
        if self.path.startswith("/attachments/"):
            self._handle_attachment_get()
            return
        # 2026-05-07 settings v2 endpoints
        if self.path == "/session/info":
            self._handle_session_info()
            return
        if self.path == "/session/usage":
            self._handle_session_usage()
            return
        if self.path == "/connections/status":
            self._handle_connections_status()
            return
        if self.path == "/vault/stats":
            self._handle_vault_stats()
            return
        if self.path == "/group/stats":
            self._handle_group_stats()
            return
        if self.path == "/build/last_ship":
            self._handle_build_last_ship()
            return
        if self.path == "/storage/stats":
            self._handle_storage_stats()
            return
        if self.path == "/debug/server_log":
            self._handle_debug_server_log()
            return
        if self.path == "/debug/turn_id":
            self._send_json(200, {"ok": True, "turn_id": "unknown"})
            return
        if self.path == "/admin/rotate-secret":
            # P0-4: rotate shared_secret; requires current secret in X-Auth-Token
            if not self._auth_matches():
                self._send_json(403, {"error": "current secret required to rotate"})
                return
            import secrets as _sec
            new_secret = _sec.token_hex(32)
            secret_file = Path.home() / ".ots" / "secret"
            try:
                secret_file.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                secret_file.write_text(new_secret)
                secret_file.chmod(0o600)
                self.state.shared_secret = new_secret
                logger.info("P0-4: shared_secret rotated")
                self._send_json(200, {"ok": True, "new_secret": new_secret, "hint": "update your iOS app onboarding"})
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        if self.path == "/health":
            self._send_json(
                200,
                {
                    "ok": True,
                    "active_tokens": len(self.state.tokens.all_active()),
                    "sandbox": self.state.sandbox,
                    "bundle_id": self.state.bundle_id,
                },
            )
            return
        if self.path == "/version":
            self._send_json(200, {"ok": True, "version": self.server_version})
            return
        if self.path == "/web/chat" or self.path.startswith("/web/chat?"):
            self._serve_web_chat()
            return
        if self.path == "/gomoku/state":
            self._handle_gomoku_state()
            return
        if self.path.startswith("/reminder/list"):
            self._send_json(200, {"ok": True, "reminders": self.state.reminders.list_pending()})
            return
        if self.path == "/tokens":
            if not self._check_auth():
                self._send_json(401, {"error": "auth required"})
                return
            tokens = [
                {
                    "activity_id": t.activity_id,
                    "device_label": t.device_label,
                    "started_at": t.started_at,
                    "last_seen_at": t.last_seen_at,
                    "token_prefix": t.token[:8] + "..." if t.token else "",
                }
                for t in self.state.tokens.all_active()
            ]
            self._send_json(200, {"tokens": tokens, "count": len(tokens)})
            return
        if self.path.startswith("/calendar/categories"):
            self._handle_calendar_categories()
            return
        if self.path.startswith("/calendar/list"):
            self._handle_calendar_list()
            return
        if self.path.startswith("/calendar/day"):
            self._handle_calendar_day()
            return
        if self.path.startswith("/calendar/month"):
            self._handle_calendar_month()
            return
        if self.path.startswith("/opia/group-msg-redesign"):
            try:
                p = Path(__file__).parent / "static" / "group_msg_redesign.html"
                data = p.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        if self.path.startswith("/opia/tab-mockups"):
            try:
                p = Path(__file__).parent / "static" / "tab_mockups.html"
                data = p.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        if self.path.startswith("/opia/widget"):
            try:
                widget_path = Path(__file__).parent / "static" / "cc_widget.html"
                data = widget_path.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        if not self._check_ip_allowed():
            return
        if not self._require_write_auth():
            return
        # /chat/upload 走 multipart 不解析 JSON 直接 handle raw (现在含 query string)
        if self.path.startswith("/chat/upload"):
            self._handle_chat_upload()
            return
        if self.path == "/diary/upload":
            self._handle_diary_upload()
            return

        try:
            body = self._read_body()
        except Exception as e:
            self._send_json(400, {"error": f"bad json: {e}"})
            return

        if self.path == "/register-token":
            self._handle_register(body)
        elif self.path == "/unregister-token":
            self._handle_unregister(body)
        elif self.path == "/register-device-token":
            self._handle_register_device_token(body)
            return
        elif self.path == "/reminder/schedule":
            self._handle_reminder_schedule(body)
            return
        elif self.path.startswith("/reminder/cancel"):
            self._handle_reminder_update(body, "cancel")
            return
        elif self.path.startswith("/reminder/fired"):
            self._handle_reminder_update(body, "fired")
            return
        elif self.path == "/push/clear-unread":
            self._handle_clear_unread()
            return
        elif self.path == "/push":
            if not self._check_auth():
                self._send_json(401, {"error": "auth required"})
                return
            self._handle_push(body)
        elif self.path == "/diary/post":
            self._handle_diary_post(body)
            return
        elif self.path == "/diary/clear-unread":
            self._handle_diary_clear_unread()
            return
        elif self.path == "/task/add":
            self._handle_task_action(body, "add")
        elif self.path == "/task/progress":
            self._handle_task_action(body, "progress")
        elif self.path == "/task/done":
            self._handle_task_action(body, "done")
        elif self.path == "/task/cancel":
            self._handle_task_action(body, "cancel")
        elif self.path == "/task/clear-history":
            self._handle_task_action(body, "clear_history")
        elif self.path == "/task/append-ephemeral":
            self._handle_task_append_ephemeral(body)
        elif self.path == "/chat/send":
            self._handle_chat_send(body)
        elif self.path == "/chat/regenerate":
            # P0-2: regenerate involves tmux Escape injection — remote control gate
            if not self.state.allow_remote_control:
                self._send_json(403, {"error": "remote_control disabled", "hint": "set allow_remote_control=true in config.toml"})
                return
            self._handle_chat_regenerate(body)
        elif self.path == "/pet/state":
            self._handle_pet_state_post(body)
        elif self.path == "/pet/bubble":
            self._handle_pet_bubble_post(body)
        elif self.path == "/pet/activity":
            self._handle_pet_activity_post(body)
        elif self.path == "/chat/append":
            self._handle_chat_append(body)
        elif self.path == "/chain/abort":
            # P0-2: remote control gate
            if not self.state.allow_remote_control:
                self._send_json(403, {"error": "remote_control disabled", "hint": "set allow_remote_control=true in config.toml"})
                return
            self._handle_chain_abort(body)
        elif self.path == "/chain/new_session":
            # Phase B slash /new: create new tmux session + start CC
            if not self.state.allow_remote_control:
                self._send_json(403, {"error": "remote_control disabled"})
                return
            self._handle_chain_new_session(body)
        elif self.path == "/chain/switch":
            # Phase B slash /switch: change active chain session
            if not self.state.allow_remote_control:
                self._send_json(403, {"error": "remote_control disabled"})
                return
            self._handle_chain_switch(body)
        elif self.path == "/chain/clear":
            self._handle_chain_clear(body)
        elif self.path == "/chain/restart":
            # P0-2: remote control gate
            if not self.state.allow_remote_control:
                self._send_json(403, {"error": "remote_control disabled"})
                return
            self._handle_chain_restart(body)
        elif self.path == "/group/send":
            self._handle_group_send(body)
        elif self.path == "/group/append":
            self._handle_group_append(body)
        elif self.path == "/group/dispatch-state":
            self._handle_group_dispatch_state(body)
        elif self.path == "/group/typing":
            self._handle_group_typing(body)
        elif self.path == "/group/delete":
            self._handle_group_delete(body)
        elif self.path == "/group/clear":
            self._handle_group_clear(body)
        elif self.path == "/calendar/add":
            self._handle_calendar_add(body)
        elif self.path == "/calendar/update":
            self._handle_calendar_update(body)
        elif self.path == "/calendar/delete":
            self._handle_calendar_delete(body)
        elif self.path == "/calendar/tick":
            self._handle_calendar_tick(body)
        elif self.path == "/rp/new":
            self._handle_rp_new(body)
        elif self.path == "/rp/send":
            self._handle_rp_send(body)
        elif self.path == "/rp/append":
            self._handle_rp_append(body)
        elif self.path == "/rp/archive":
            self._handle_rp_archive(body)
        elif self.path == "/chat/delete":
            self._handle_chat_delete(body)
        elif self.path == "/chat/react":
            self._handle_chat_react(body)
        elif self.path == "/diary/append":
            self._handle_diary_append(body)
        elif self.path == "/timeline/event":
            self._handle_timeline_event(body)
        elif self.path == "/diary/edit":
            self._handle_diary_edit(body)
        elif self.path == "/diary/delete-attachment":
            self._handle_diary_delete_attachment(body)
        elif self.path == "/favorites/add":
            self._handle_favorites_add(body)
        elif self.path == "/favorites/edit":
            self._handle_favorites_edit(body)
        elif self.path == "/favorites/delete":
            self._handle_favorites_delete(body)
        elif self.path == "/favorites/delete_by_turn":
            self._handle_favorites_delete_by_turn(body)
        elif self.path == "/favorites/reload":
            self._handle_favorites_reload(body)
        elif self.path == "/todos/toggle":
            self._handle_todos_toggle(body)
        elif self.path == "/todos/add":
            self._handle_todos_add(body)
        elif self.path == "/todos/edit":
            self._handle_todos_edit(body)
        elif self.path == "/tmux/send":
            # P0-2: direct tmux send-keys — remote control gate
            if not self.state.allow_remote_control:
                self._send_json(403, {"error": "remote_control disabled"})
                return
            self._handle_tmux_send(body)
        elif self.path == "/system/lock":
            try:
                import subprocess
                subprocess.run(["pmset", "displaysleepnow"], check=False, timeout=2)
                self._send_json(200, {"ok": True, "action": "lock"})
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        elif self.path == "/settings":
            for k, v in body.items():
                self.state.settings.set(k, v)
            self._send_json(200, {"ok": True, "settings": self.state.settings.snapshot()})
            return
        else:
            self._send_json(404, {"error": "not found"})

    # ---------- handlers ----------

    def _handle_register(self, body: dict[str, Any]):
        token = body.get("token")
        activity_id = body.get("activity_id")
        device_label = body.get("device_label", "")
        if not token or not activity_id:
            self._send_json(400, {"error": "token and activity_id required"})
            return
        rec = self.state.tokens.register(
            token=token, activity_id=activity_id, device_label=device_label
        )
        logger.info("registered activity=%s device=%s", activity_id, device_label)
        self._send_json(
            200,
            {
                "ok": True,
                "activity_id": rec.activity_id,
                "started_at": rec.started_at,
                "active_count": len(self.state.tokens.all_active()),
            },
        )

    def _handle_unregister(self, body: dict[str, Any]):
        activity_id = body.get("activity_id")
        if not activity_id:
            self._send_json(400, {"error": "activity_id required"})
            return
        ok = self.state.tokens.unregister(activity_id)
        logger.info("unregistered activity=%s ok=%s", activity_id, ok)
        self._send_json(
            200,
            {
                "ok": ok,
                "active_count": len(self.state.tokens.all_active()),
            },
        )

    def _handle_register_device_token(self, body: dict[str, Any]):
        token = str(body.get("token") or "").strip()
        if not token:
            self._send_json(400, {"error": "token required"})
            return
        is_new = self.state.device_tokens.register(token)
        logger.info("device_token %s token=%s... total=%d",
                    "new" if is_new else "refresh", token[:8], len(self.state.device_tokens))
        self._send_json(200, {"ok": True, "new": is_new, "total": len(self.state.device_tokens)})

    def _send_chat_notification(self, title: str, body_text: str):
        """向所有已注册设备发 standard APNs banner 通知 (non-Live-Activity)."""
        device_tokens = self.state.device_tokens.all_tokens()
        if not device_tokens:
            return
        payload = {
            "aps": {
                "alert": {"title": title, "body": body_text},
                "badge": 1,
                "sound": "default",
            }
        }
        for token in device_tokens:
            try:
                resp = self.state.notification_client.push_notification(
                    push_token=token,
                    payload=payload,
                )
                if resp.status == 410 or (resp.status == 400 and "BadDeviceToken" in (resp.reason or "")):
                    logger.info("device_token invalid (status=%d), removing token=%s...", resp.status, token[:8])
                    self.state.device_tokens.remove(token)
                elif not resp.ok:
                    logger.warning("device push failed status=%d token=%s... reason=%s",
                                   resp.status, token[:8], resp.reason)
            except Exception as e:
                logger.warning("device push exception token=%s...: %s", token[:8], e)

    # ------------------------------------------------------------------
    # /diary/* — chain↔用户 chat-style journaling stream (OTS Diary tab)
    # 2026-05-11 spec ots-diary-tab-mvp
    # ------------------------------------------------------------------

    def _handle_diary_post(self, body: dict[str, Any]):
        """
        POST /diary/post — append one diary message.

        Body: {role: "assistant"|"user"|"system", text: str, source?: str}

        When role=assistant (chain posting a probing question), we also fire
        an APNs banner to the iPhone so用户 knows there's a new diary prompt
        waiting. role=user replies are silent (no self-notification).
        """
        role = str(body.get("role") or "").strip().lower()
        text = (body.get("text") or body.get("content") or "").strip()
        source = str(body.get("source") or ("chain" if role == "assistant" else "ios-app")).strip()
        if role not in ("user", "assistant", "system"):
            self._send_json(400, {"ok": False, "error": "role must be user|assistant|system"})
            return
        if not text:
            self._send_json(400, {"ok": False, "error": "text required"})
            return
        try:
            rec = self.state.diary_stream.append(role=role, text=text, source=source)
        except Exception as e:
            logger.exception("diary_stream.append failed")
            self._send_json(500, {"ok": False, "error": str(e)})
            return

        # APNs ping用户 iPhone when chain posts a new question
        if role == "assistant":
            try:
                snippet = text if len(text) <= 160 else text[:157] + "…"
                self._send_chat_notification(title="日记 · AI", body_text=snippet)
            except Exception:
                logger.exception("diary APNs ping failed (non-fatal)")

        self._send_json(200, {"ok": True, "record": rec, "unread": self.state.diary_stream.unread()})

    def _handle_diary_poll(self):
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        since = qs.get("since", [None])[0]
        try:
            limit = int(qs.get("limit", ["200"])[0])
        except Exception:
            limit = 200
        limit = min(max(limit, 1), 1000)
        records = self.state.diary_stream.read_since(since_ts=since, limit=limit)
        self._send_json(200, {
            "ok": True,
            "records": records,
            "count": len(records),
            "unread": self.state.diary_stream.unread(),
            "latest_ts": self.state.diary_stream.latest_ts(),
        })

    def _handle_diary_history(self):
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        date = qs.get("date", [None])[0]
        try:
            limit = int(qs.get("limit", ["500"])[0])
        except Exception:
            limit = 500
        limit = min(max(limit, 1), 2000)
        if date:
            try:
                records = self.state.diary_stream.read_day(date)
            except ValueError as e:
                self._send_json(400, {"ok": False, "error": str(e)})
                return
        else:
            records = self.state.diary_stream.read_history(limit=limit)
        self._send_json(200, {"ok": True, "records": records, "count": len(records)})

    def _handle_diary_clear_unread(self):
        n = self.state.diary_stream.clear_unread()
        self._send_json(200, {"ok": True, "unread": n})

    def _handle_task_action(self, body: dict[str, Any], action: str):
        """task 队列管理 + 自动 push 灵动岛刷新"""
        snap = None
        if action == "add":
            title = body.get("title", "").strip()
            total = int(body.get("total", 1))
            if not title:
                self._send_json(400, {"error": "title required"})
                return
            snap = self.state.tasks.add(title, total)
        elif action == "progress":
            current = int(body.get("current", 0))
            step = body.get("step", "")
            total = body.get("total")
            snap = self.state.tasks.progress(current, step=step, total=total)
        elif action == "done":
            snap = self.state.tasks.done()
        elif action == "cancel":
            snap = self.state.tasks.cancel()
        elif action == "clear_history":
            snap = self.state.tasks.clear_history()

        # 自动 push 灵动岛 — 把当前 task queue 状态投到 ContentState
        if snap is not None:
            self._auto_push_from_task(snap, action)
            # 把 task lifecycle 事件放进 ephemeral buffer, 不污染 chat_history.jsonl
            try:
                if action == "add":
                    active = snap.get("active") or {}
                    title = active.get("title", "")
                    total = active.get("total", 0)
                    if title:
                        self.state.task_buffer.append(
                            text=f"▷ 开始 {title} (0/{total})",
                            source="system",
                        )
                elif action == "progress":
                    active = snap.get("active") or {}
                    title = active.get("title", "")
                    current = active.get("current", 0)
                    total = active.get("total", 0)
                    step = active.get("step", "") or ""
                    if title and step:
                        self.state.task_buffer.append(
                            text=f"· {step} ({current}/{total})",
                            source="system",
                        )
                elif action == "done":
                    completed = snap.get("completed", []) or []
                    last = completed[-1] if completed else None
                    title = last.get("title", "") if last else ""
                    total = last.get("total", 0) if last else 0
                    if title:
                        self.state.task_buffer.append(
                            text=f"✓ 完成 {title} ({total}/{total})",
                            source="system",
                        )
                elif action == "cancel":
                    completed = snap.get("completed", []) or []
                    last = completed[-1] if completed else None
                    title = last.get("title", "") if last else ""
                    if title:
                        self.state.task_buffer.append(
                            text=f"✗ 取消 {title}",
                            source="system",
                        )
            except Exception as e:
                logger.warning("task → chat history fail: %s", e)

        self._send_json(200, {"ok": True, "action": action, "snapshot": snap})

    def _handle_task_append_ephemeral(self, body: dict[str, Any]):
        text = body.get("text", "").strip()
        source = body.get("source", "claude-code")
        if not text:
            self._send_json(400, {"error": "text required"})
            return
        rec = self.state.task_buffer.append(text=text, source=source)
        self._send_json(200, {"ok": True, "record": rec})

    def _auto_push_from_task(self, snap: dict[str, Any], action: str):
        """根据 task queue snapshot 自动构造 ContentState push"""
        active = snap.get("active")
        queue_len = snap.get("queue_length", 0)
        completed = snap.get("completed", [])

        cs: dict[str, Any] = {
            "status": "thinking" if active else "spoke",
            "unreadCount": queue_len,  # 排队数 显示为 trailing 数字
        }

        if active:
            total = max(int(active["total"]), 1)
            current = int(active["current"])
            cs["taskTitle"] = active["title"]
            cs["taskCurrent"] = current
            cs["taskTotal"] = total
            cs["taskProgress"] = current / total
            if active.get("step"):
                cs["taskStep"] = str(active["step"])[:80]
        elif action == "done":
            # 没 active + 刚完成 = 全部完事
            last = completed[-1]["title"] if completed else ""
            cs["status"] = "spoke"
            cs["lastMessagePreview"] = f"✓ 全部完成 (最近: {last})" if last else "全部完成"

        # 完成历史 (最近 5 条 swift 端 completedTitles 字段)
        if completed:
            cs["completedTitles"] = [c["title"][:30] for c in completed[-5:]]

        # 2026-05-05 task done 时不 end Live Activity (client 端没 auto reattach mechanism end 之后再 add 起不来)
        # 改成 update event + cs 里 taskTitle 用空字符串显式覆盖 让 widget UI 看到"task 完成 idle 状态"不卡旧 task
        if action == "done":
            cs["taskTitle"] = ""
            cs["taskCurrent"] = 0
            cs["taskTotal"] = 0
            cs["taskStep"] = ""
            cs["taskProgress"] = 0.0
        active_tokens = self.state.tokens.all_active()
        if not active_tokens:
            return
        try:
            for tok in active_tokens:
                self.state.client.push_live_activity(
                    push_token=tok.token,
                    event="update",
                    content_state=cs,
                )
        except Exception as e:
            logger.warning("auto push from task fail: %s", e)

    # ---------- diary handlers ----------

    def _query(self) -> dict[str, list[str]]:
        from urllib.parse import parse_qs, urlparse
        return parse_qs(urlparse(self.path).query)

    def _query_value(self, qs: dict[str, list[str]], key: str, default: str | None = None) -> str | None:
        value = qs.get(key, [default])[0]
        return value if value != "" else default

    def _handle_diary_calendar(self):
        qs = self._query()
        try:
            author = self._query_value(qs, "author")
            month = self._query_value(qs, "month")
            if not author or not month:
                self._send_json(400, {"error": "author and month required"})
                return
            res = self.state.diary.calendar(
                author=author,
                kind=self._query_value(qs, "kind"),
                month=month,
            )
            self._send_json(200, {"ok": True, **res})
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("diary calendar fail")
            self._send_json(500, {"error": str(e)})

    def _handle_diary_get(self):
        qs = self._query()
        try:
            author = self._query_value(qs, "author")
            date = self._query_value(qs, "date")
            if not author or not date:
                self._send_json(400, {"error": "author and date required"})
                return
            res = self.state.diary.get(
                author=author,
                kind=self._query_value(qs, "kind"),
                date=date,
            )
            self._send_json(200, {"ok": True, **res})
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("diary get fail")
            self._send_json(500, {"error": str(e)})

    def _handle_diary_search(self):
        qs = self._query()
        try:
            query = self._query_value(qs, "q")
            if not query:
                self._send_json(400, {"error": "q required"})
                return
            records = self.state.diary.search(
                query=query,
                author=self._query_value(qs, "author"),
            )
            self._send_json(200, {"ok": True, "records": records, "count": len(records)})
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("diary search fail")
            self._send_json(500, {"error": str(e)})

    def _handle_diary_on_this_day(self):
        qs = self._query()
        try:
            date = self._query_value(qs, "date")
            if not date:
                self._send_json(400, {"error": "date required"})
                return
            self._send_json(200, {"ok": True, **self.state.diary.on_this_day(date)})
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("diary on-this-day fail")
            self._send_json(500, {"error": str(e)})

    def _handle_diary_streak(self):
        qs = self._query()
        try:
            author = self._query_value(qs, "author")
            if not author:
                self._send_json(400, {"error": "author required"})
                return
            self._send_json(
                200,
                {"ok": True, **self.state.diary.streak(author=author, kind=self._query_value(qs, "kind"))},
            )
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("diary streak fail")
            self._send_json(500, {"error": str(e)})

    def _handle_diary_prompts(self):
        qs = self._query()
        try:
            context = self._query_value(qs, "context")
            if not context:
                self._send_json(400, {"error": "context required"})
                return
            prompts = self.state.diary.prompts(context)
            self._send_json(200, {"ok": True, "prompts": prompts})
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("diary prompts fail")
            self._send_json(500, {"error": str(e)})

    def _handle_chat_status(self):
        """chat 状态栏: typing / online / sleeping
        - typing: typing_state.is_typing
        - online: 最近 5 分钟有 assistant turn (我在干活 / 刚回过)
        - sleeping: 否则 (主 chain 没 turn 长时间)
        """
        try:
            from datetime import datetime as _dt
            typing = self.state.typing_state.get("is_typing", False)
            if typing:
                self._send_json(200, {
                    "ok": True,
                    "status": "typing",
                    "since": self.state.typing_state.get("since"),
                })
                return
            last_records = self.state.chat.tail(20)
            last_ts = None
            for r in reversed(last_records):
                if r.get("role") == "assistant":
                    last_ts = r.get("ts")
                    break
            status = "sleeping"
            if last_ts:
                try:
                    last_dt = _dt.fromisoformat(last_ts)
                    now = _dt.now(last_dt.tzinfo)
                    if (now - last_dt).total_seconds() < 300:
                        status = "online"
                except Exception:
                    pass
            self._send_json(200, {"ok": True, "status": status, "last_turn": last_ts})
        except Exception as e:
            logger.exception("chat status fail")
            self._send_json(500, {"error": str(e)})

    def _chat_status_payload(self) -> dict[str, Any]:
        from datetime import datetime as _dt

        typing = self.state.typing_state.get("is_typing", False)
        typing_since = self.state.typing_state.get("since")
        if typing and typing_since:
            try:
                since_dt = _dt.fromisoformat(typing_since)
                age = (_dt.now(timezone.utc).astimezone() - since_dt).total_seconds()
                if age > 120:
                    self.state.typing_state = {"is_typing": False, "since": None}
                    typing = False
                    typing_since = None
            except Exception:
                pass
        if typing:
            return {
                "status": "typing",
                "is_typing": True,
                "since": typing_since,
                "active_task": self.state.tasks.snapshot().get("active"),
            }

        last_records = self.state.chat.tail(20)
        last_ts = None
        for r in reversed(last_records):
            if r.get("role") == "assistant":
                last_ts = r.get("ts")
                break
        status = "sleeping"
        if last_ts:
            try:
                last_dt = _dt.fromisoformat(last_ts)
                now = _dt.now(last_dt.tzinfo)
                if (now - last_dt).total_seconds() < 300:
                    status = "online"
            except Exception:
                pass
        return {
            "status": status,
            "is_typing": False,
            "since": None,
            "last_turn": last_ts,
            "active_task": self.state.tasks.snapshot().get("active"),
        }

    def _settings_payload(self, client_etag: str | None) -> dict[str, Any]:
        snap = self.state.settings.snapshot()
        raw = json.dumps(snap, ensure_ascii=False, sort_keys=True).encode("utf-8")
        etag = hashlib.sha1(raw).hexdigest()[:12]
        if client_etag == etag:
            return {"unchanged": True, "etag": etag}
        return {"unchanged": False, "etag": etag, "values": snap}

    def _handle_chat_poll(self):
        qs = self._query()
        since = self._query_value(qs, "since")
        etag = self._query_value(qs, "etag")
        try:
            limit = int(self._query_value(qs, "limit", "50") or "50")
        except Exception:
            limit = 50
        limit = max(1, min(limit, 200))
        try:
            chat_records = self.state.chat.read_since(since_ts=since, limit=limit)
            task_records = self.state.task_buffer.list_since(since_ts=since)
            records = sorted(chat_records + task_records, key=lambda r: r.get("ts", ""))
            last_ts = records[-1].get("ts") if records else since
            now = datetime.now(timezone.utc).astimezone().isoformat(timespec="milliseconds")
            self._send_json(
                200,
                {
                    "ok": True,
                    "now": now,
                    "chat": {
                        "new_records": records,
                        "last_ts": last_ts,
                        "count": len(records),
                    },
                    "status": self._chat_status_payload(),
                    "settings": self._settings_payload(etag),
                },
            )
        except Exception as e:
            logger.exception("chat poll fail")
            self._send_json(500, {"error": str(e)})

    def _handle_timeline(self):
        qs = self._query()
        try:
            date = self._query_value(qs, "date")
            week = self._query_value(qs, "week")
            month = self._query_value(qs, "month")
            if date:
                self._send_json(200, self.state.timeline.daily(date))
            elif week:
                self._send_json(200, self.state.timeline.weekly(week))
            elif month:
                self._send_json(200, self.state.timeline.monthly(month))
            else:
                self._send_json(400, {"error": "date / week / month required"})
        except Exception as e:
            logger.exception("timeline fail")
            self._send_json(500, {"error": str(e)})

    def _handle_timeline_events(self):
        qs = self._query()
        try:
            try:
                limit = int(self._query_value(qs, "limit", "500") or "500")
            except Exception:
                limit = 500
            limit = max(1, min(limit, 10000))
            events = self.state.timeline.list_events(
                start=self._query_value(qs, "start") or self._query_value(qs, "from"),
                end=self._query_value(qs, "end") or self._query_value(qs, "to"),
                category=self._query_value(qs, "category"),
                status=self._query_value(qs, "status"),
                limit=limit,
            )
            self._send_json(200, {"ok": True, "events": events, "count": len(events)})
        except Exception as e:
            logger.exception("timeline events fail")
            self._send_json(500, {"error": str(e)})

    def _handle_timeline_aggregate(self):
        qs = self._query()
        try:
            range_name = self._query_value(qs, "range", "day") or "day"
            anchor = (
                self._query_value(qs, "anchor")
                or self._query_value(qs, "date")
                or self._query_value(qs, "week")
                or self._query_value(qs, "month")
            )
            status = self._query_value(qs, "status", "confirmed") or "confirmed"
            payload = self.state.timeline.aggregate(
                range_name=range_name,
                anchor=anchor,
                category=self._query_value(qs, "category"),
                status=status,
            )
            self._send_json(200, payload)
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("timeline aggregate fail")
            self._send_json(500, {"error": str(e)})

    def _handle_timeline_event(self, body: dict[str, Any]):
        try:
            self._send_json(200, self.state.timeline.add_event(body))
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("timeline event fail")
            self._send_json(500, {"error": str(e)})

    def _handle_diary_append(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        try:
            required = ["author", "date", "time", "text"]
            missing = [key for key in required if not body.get(key)]
            if missing:
                self._send_json(400, {"error": f"{', '.join(missing)} required"})
                return
            if body.get("attachment_path"):
                res = self.state.diary.append_with_attachment(
                    author=body["author"],
                    kind=body.get("kind"),
                    date=body["date"],
                    time=body["time"],
                    text=body["text"],
                    attachment_path=body["attachment_path"],
                    frontmatter=body.get("frontmatter") or None,
                )
            else:
                res = self.state.diary.append(
                    author=body["author"],
                    kind=body.get("kind"),
                    date=body["date"],
                    time=body["time"],
                    text=body["text"],
                    frontmatter=body.get("frontmatter") or None,
                )
            self._send_json(200, res)
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("diary append fail")
            self._send_json(500, {"error": str(e)})

    def _handle_diary_upload(self):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        allowed_exts = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif"}
        try:
            length = int(self.headers.get("Content-Length", 0))
        except Exception:
            length = 0
        max_size = 10 * 1024 * 1024
        if length <= 0:
            self._send_json(400, {"error": "empty upload"})
            return
        if length > max_size:
            self._send_json(413, {"error": "file too large"})
            return
        content_type = self.headers.get("Content-Type", "")
        if "multipart/form-data" not in content_type or "boundary=" not in content_type:
            self._send_json(400, {"error": "multipart/form-data required"})
            return
        try:
            from email import policy
            from email.parser import BytesParser
            import tempfile
            import uuid as _uuid

            raw = self.rfile.read(length)
            msg = BytesParser(policy=policy.default).parsebytes(
                (
                    f"Content-Type: {content_type}\r\n"
                    "MIME-Version: 1.0\r\n\r\n"
                ).encode("utf-8") + raw
            )
            file_part = None
            for part in msg.iter_parts():
                if part.get_param("name", header="content-disposition") == "file":
                    file_part = part
                    break
            if file_part is None:
                self._send_json(400, {"error": "file field required"})
                return
            filename = file_part.get_filename() or "upload.bin"
            ext = Path(filename).suffix.lower()
            if ext not in allowed_exts:
                self._send_json(400, {"error": "unsupported file extension"})
                return
            payload = file_part.get_payload(decode=True) or b""
            if not payload:
                self._send_json(400, {"error": "empty file"})
                return
            if len(payload) > max_size:
                self._send_json(413, {"error": "file too large"})
                return
            target = Path(tempfile.gettempdir()) / f"opia_diary_upload_{_uuid.uuid4().hex}{ext}"
            target.write_bytes(payload)
            self._send_json(
                200,
                {
                    "ok": True,
                    "local_path": str(target),
                    "suggested_filename": filename,
                },
            )
        except Exception as e:
            logger.exception("diary upload fail")
            self._send_json(500, {"error": str(e)})

    def _handle_diary_edit(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        try:
            required = ["author", "date", "time", "new_text"]
            missing = [key for key in required if not body.get(key)]
            if missing:
                self._send_json(400, {"error": f"{', '.join(missing)} required"})
                return
            res = self.state.diary.edit(
                author=body["author"],
                kind=body.get("kind"),
                date=body["date"],
                time=body["time"],
                new_text=body["new_text"],
            )
            self._send_json(200, res)
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("diary edit fail")
            self._send_json(500, {"error": str(e)})

    def _handle_diary_delete_attachment(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        rel_path = body.get("rel_path")
        if not rel_path:
            self._send_json(400, {"error": "rel_path required"})
            return
        try:
            self._send_json(200, {"ok": self.state.diary.delete_attachment(rel_path)})
        except Exception as e:
            logger.exception("diary delete attachment fail")
            self._send_json(500, {"error": str(e)})

    # ---------- favorites handlers ----------

    def _handle_favorites_list(self):
        qs = self._query()
        try:
            try:
                limit = int(self._query_value(qs, "limit", "50") or "50")
                offset = int(self._query_value(qs, "offset", "0") or "0")
            except Exception:
                self._send_json(400, {"error": "limit and offset must be integers"})
                return
            records = self.state.favorites.list(
                type=self._query_value(qs, "type"),
                tag=self._query_value(qs, "tag"),
                q=self._query_value(qs, "q"),
                limit=limit,
                offset=offset,
            )
            self._send_json(200, {"ok": True, "records": records, "count": len(records)})
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("favorites list fail")
            self._send_json(500, {"error": str(e)})

    def _handle_favorites_get(self):
        qs = self._query()
        try:
            fav_id = self._query_value(qs, "id")
            if not fav_id:
                self._send_json(400, {"error": "id required"})
                return
            record = self.state.favorites.get(fav_id)
            self._send_json(200, {"ok": record is not None, "record": record})
        except Exception as e:
            logger.exception("favorites get fail")
            self._send_json(500, {"error": str(e)})

    def _handle_favorites_add(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        try:
            required = ["type", "source", "refs"]
            missing = [key for key in required if not body.get(key)]
            if missing:
                self._send_json(400, {"error": f"{', '.join(missing)} required"})
                return
            if body.get("attachment_path"):
                record = self.state.favorites.add_with_attachment(
                    type=body["type"],
                    source=body["source"],
                    refs=body["refs"],
                    local_path=body["attachment_path"],
                    tags=body.get("tags"),
                    note=body.get("note"),
                )
            else:
                record = self.state.favorites.add(
                    type=body["type"],
                    source=body["source"],
                    refs=body["refs"],
                    tags=body.get("tags"),
                    note=body.get("note"),
                )
            self._send_json(200, {"ok": True, "record": record})
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("favorites add fail")
            self._send_json(500, {"error": str(e)})

    def _handle_favorites_edit(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        try:
            fav_id = body.get("id")
            if not fav_id:
                self._send_json(400, {"error": "id required"})
                return
            record = self.state.favorites.edit(
                id=fav_id,
                tags=body["tags"] if "tags" in body else None,
                note=body["note"] if "note" in body else None,
            )
            self._send_json(200, {"ok": record is not None, "record": record})
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("favorites edit fail")
            self._send_json(500, {"error": str(e)})

    def _handle_favorites_delete(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        try:
            fav_id = body.get("id")
            if not fav_id:
                self._send_json(400, {"error": "id required"})
                return
            self._send_json(200, {"ok": self.state.favorites.delete(fav_id), "id": fav_id})
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("favorites delete fail")
            self._send_json(500, {"error": str(e)})

    def _handle_favorites_delete_by_turn(self, body: dict[str, Any]):
        """Phase 设置大砍 — 删 last-ref-ts == given ts 的所有 favorite entries.
        body: {ts: "<turn-end ts>"}
        """
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        try:
            ts = body.get("ts")
            if not ts:
                self._send_json(400, {"error": "ts required"})
                return
            # Find all favorites where the LAST ref ts matches; collect their ids; delete each.
            all_items = self.state.favorites.list(limit=10_000, offset=0)
            removed_ids: list[str] = []
            for item in all_items:
                refs = item.get("refs", []) if isinstance(item, dict) else []
                if refs:
                    last_ref = refs[-1]
                    if isinstance(last_ref, dict) and last_ref.get("ts") == ts:
                        fav_id = item.get("id")
                        if fav_id and self.state.favorites.delete(fav_id):
                            removed_ids.append(fav_id)
            self._send_json(200, {"ok": True, "removed": removed_ids})
        except Exception as e:
            logger.exception("favorites delete_by_turn fail")
            self._send_json(500, {"error": str(e)})

    def _handle_favorites_reload(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        try:
            count = self.state.favorites.reload()
            self._send_json(200, {"ok": True, "count": count})
        except Exception as e:
            logger.exception("favorites reload fail")
            self._send_json(500, {"error": str(e)})

    # ---------- RP handlers ----------

    def _require_rp_manager(self) -> bool:
        if rp_session_manager is not None:
            return True
        self._send_json(501, {"error": "rp_session_manager not installed"})
        return False

    def _rp_chain_append(self, sid: str, rec: dict[str, Any]) -> None:
        if rp_session_manager is None:
            raise RuntimeError("rp_session_manager not installed")
        chain_path = rp_session_manager.active_dir(sid) / "chain.jsonl"
        chain_path.parent.mkdir(parents=True, exist_ok=True)
        with chain_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    def _handle_rp_new(self, body: dict[str, Any]):
        if not self._require_rp_manager():
            return
        seed = str(body.get("character_seed") or "").strip()
        if not seed:
            self._send_json(400, {"error": "character_seed required"})
            return
        try:
            started = rp_session_manager.start(character_seed=seed)
            self._send_json(200, {"ok": True, "sid": started["sid"], "character_card": started["character_card"]})
        except Exception as e:
            logger.exception("rp new fail")
            self._send_json(500, {"error": str(e)})

    def _handle_rp_send(self, body: dict[str, Any]):
        if not self._require_rp_manager():
            return
        sid = str(body.get("sid") or "").strip()
        text = str(body.get("text") or "").strip()
        try:
            sid = validate_rp_sid(sid)
        except ValueError:
            self._send_json(400, {"error": "invalid sid"})
            return
        if not text:
            self._send_json(400, {"error": "text required"})
            return
        if not rp_session_manager.active_dir(sid).exists():
            self._send_json(404, {"error": "rp session not found"})
            return
        try:
            meta = rp_session_manager.touch_activity(sid, turns_delta=1)
            rec = self.state.rp_history.append(
                sid=sid,
                role="user",
                text=text,
                source="ios-app",
                character_id=meta.get("character_id") or sid,
            )
            self._rp_chain_append(sid, rec)
            subprocess.Popen(
                [
                    "python3",
                    self.state.bus_send_path,
                    "--source", "ios-rp",
                    "--sender", "iphone",
                    "--channel", "rp",
                    "--sid", sid,
                    "--text", text,
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self._send_json(200, {"ok": True, "record": rec})
        except Exception as e:
            logger.exception("rp send fail")
            self._send_json(500, {"error": str(e)})

    def _handle_rp_history(self):
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        sid = qs.get("sid", [""])[0]
        since = qs.get("since", [None])[0]
        try:
            sid = validate_rp_sid(sid)
        except ValueError:
            self._send_json(400, {"error": "invalid sid"})
            return
        try:
            limit = int(qs.get("limit", ["10000"])[0])
        except Exception:
            limit = 10000
        try:
            records = self.state.rp_history.read_since(sid=sid, since_ts=since, limit=limit)
            self._send_json(200, {"ok": True, "messages": records, "count": len(records)})
        except Exception as e:
            logger.exception("rp history fail")
            self._send_json(500, {"error": str(e)})

    def _handle_rp_append(self, body: dict[str, Any]):
        if not self._require_rp_manager():
            return
        sid = str(body.get("sid") or "").strip()
        role = str(body.get("role") or "assistant").strip()
        text = str(body.get("text") or "").strip()
        try:
            sid = validate_rp_sid(sid)
        except ValueError:
            self._send_json(400, {"error": "invalid sid"})
            return
        if role not in ("user", "assistant", "system"):
            self._send_json(400, {"error": "bad role"})
            return
        if not text:
            self._send_json(400, {"error": "text required"})
            return
        try:
            meta = rp_session_manager.touch_activity(sid, turns_delta=1)
            rec = self.state.rp_history.append(
                sid=sid,
                role=role,
                text=text,
                source=str(body.get("source") or "claude-code"),
                character_id=meta.get("character_id") or sid,
            )
            self._rp_chain_append(sid, rec)
            # standard remote notification banner — 跳过 user 消息和 [op] 前缀
            if role == "assistant" and text and not text.startswith("[op]"):
                char_name = str(meta.get("character_name") or "Cc · RP")
                threading.Thread(
                    target=self._send_chat_notification,
                    args=(char_name, text[:80]),
                    daemon=True,
                ).start()
            self._send_json(200, {"ok": True, "record": rec})
        except Exception as e:
            logger.exception("rp append fail")
            self._send_json(500, {"error": str(e)})

    def _handle_rp_archive(self, body: dict[str, Any]):
        if not self._require_rp_manager():
            return
        sid = str(body.get("sid") or "").strip()
        try:
            sid = validate_rp_sid(sid)
        except ValueError:
            self._send_json(400, {"error": "invalid sid"})
            return
        try:
            out = rp_session_manager.archive(sid)
            self._send_json(200, {"ok": True, "archived_path": out["archived_path"]})
        except FileNotFoundError as e:
            self._send_json(404, {"error": str(e)})
        except Exception as e:
            logger.exception("rp archive fail")
            self._send_json(500, {"error": str(e)})

    def _handle_rp_list(self):
        if not self._require_rp_manager():
            return
        try:
            self._send_json(200, {
                "ok": True,
                "active": rp_session_manager.list_active(),
                "archived": rp_session_manager.list_archived(),
            })
        except Exception as e:
            logger.exception("rp list fail")
            self._send_json(500, {"error": str(e)})

    # ---------- group chat handlers ----------

    def _group_tmux_session_exists(self, session: str) -> bool:
        try:
            return subprocess.run(
                ["tmux", "has-session", "-t", session],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2,
                check=False,
            ).returncode == 0
        except Exception:
            return False

    def _group_online_agents(self) -> set[str]:
        online: set[str] = set()
        for member in self.state.group_chat.roster():
            tmux = member.get("tmux")
            if member.get("can_reply") and tmux and self._group_tmux_session_exists(str(tmux)):
                online.add(member["id"])
        return online

    def _handle_group_roster(self):
        self._send_json(
            200,
            {
                "ok": True,
                "roster": self.state.group_chat.roster(),
                "status": self.state.group_chat.status_snapshot(self._group_tmux_session_exists),
            },
        )

    def _handle_group_status(self):
        self._send_json(
            200,
            {"ok": True, **self.state.group_chat.status_snapshot(self._group_tmux_session_exists)},
        )

    def _handle_group_tasks(self):
        self._send_json(200, {"ok": True, **self.state.group_chat.tasks_summary()})

    def _handle_group_history(self):
        qs = self._query()
        since = self._query_value(qs, "since")
        before = self._query_value(qs, "before") or self._query_value(qs, "before_ts")
        try:
            limit = int(self._query_value(qs, "limit", "100") or "100")
        except Exception:
            limit = 100
        limit = min(max(limit, 1), 1000)
        records = self.state.group_chat.read_since(since_ts=since, before_ts=before, limit=limit)
        self._send_json(200, {"ok": True, "records": records, "count": len(records)})

    def _handle_group_poll(self):
        qs = self._query()
        since = self._query_value(qs, "since")
        try:
            limit = int(self._query_value(qs, "limit", "100") or "100")
        except Exception:
            limit = 100
        limit = min(max(limit, 1), 500)
        records = self.state.group_chat.read_since(since_ts=since, limit=limit)
        self._send_json(
            200,
            {
                "ok": True,
                "records": records,
                "count": len(records),
                "last_ts": records[-1]["ts"] if records else since,
                "status": self.state.group_chat.status_snapshot(self._group_tmux_session_exists),
            },
        )

    def _handle_group_send(self, body: dict[str, Any]):
        text = str(body.get("text") or "").strip()
        sender_id = str(body.get("sender_id") or "amian").strip()
        if not text:
            self._send_json(400, {"error": "text required"})
            return
        # 2026-05-05 dedupe storm guard: client_msg_id 优先 没有则按 (sender, text) 3s 窗口
        client_msg_id = body.get("client_msg_id")
        cache = getattr(type(self), "_group_dedupe_cache", None)
        if cache is None:
            cache = {}
            type(self)._group_dedupe_cache = cache
        now_ts = time.time()
        if client_msg_id:
            cache_key = f"cmid:{client_msg_id}"
        else:
            cache_key = f"{sender_id}|{text[:200]}"
        last_ts = cache.get(cache_key, 0)
        if now_ts - last_ts < 3.0:
            self._send_json(429, {"ok": False, "error": "duplicate within 3s window", "deduped": True})
            return
        cache[cache_key] = now_ts
        for k in list(cache.keys()):
            if now_ts - cache[k] > 60:
                del cache[k]
        # 2026-05-05 用户 push 加 agent 互相 @ 功能 移除 amian-only 限制
        # agent 发也 OK 走 targets_for 内 hop_count loop guard

        hop_count = int(body.get("hop_count", 0) or 0)
        mentions = self.state.group_chat.normalize_mentions(body.get("mentions"), text)
        # 2026-05-06 用户 push: quote/reply 自动 mention 原 sender
        # 当 sender=amian + parent_msg_id 不空 + mentions 为空 → 从 history 找 parent sender 加进 mentions
        # 防止 quote 没显式 @ 时被默认 inject 给 opia 而不是 quote 那条的原 sender
        parent_msg_id = body.get("parent_msg_id")
        if sender_id == "amian" and parent_msg_id and not mentions:
            try:
                history = self.state.group_chat.tail(limit=200)
                for h in history:
                    if h.get("id") == parent_msg_id:
                        parent_sender = h.get("sender_id")
                        if parent_sender and parent_sender != "amian" and parent_sender in {"opia", "sonnet", "shu", "opus47_fresh"}:
                            mentions = [parent_sender]
                        break
            except Exception:
                pass
        targets = self.state.group_chat.targets_for(sender_id, mentions, self._group_online_agents(), hop_count=hop_count)
        dispatch_id = f"dsp_{int(time.time() * 1000)}"
        mode = "default" if not mentions else ("all" if "__all__" in mentions else "mention")
        delivery = {
            "targets": targets,
            "mode": mode,
            "dispatch_id": dispatch_id,
            "delivered": [],
            "failed": [],
        }
        meta = {}
        if body.get("client_msg_id"):
            meta["client_msg_id"] = body.get("client_msg_id")
        message_type = str(body.get("message_type") or "chat").strip().lower()
        owner = str(body.get("owner") or "").strip() or self._infer_group_task_owner(body, mentions)
        try:
            rec = self.state.group_chat.append(
                sender_id,
                text,
                source=str(body.get("source") or "ios-app"),
                mentions=mentions,
                parent_msg_id=body.get("parent_msg_id") or None,
                reply_to=body.get("reply_to") or None,
                delivery=delivery,
                meta=meta,
                message_type=message_type,
                task_id=str(body.get("task_id") or "").strip() or None,
                parent_task_id=str(body.get("parent_task_id") or "").strip() or None,
                owner=owner,
            )
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
            return

        if targets:
            context = "\n".join(self.state.group_chat.context_lines(limit=20))
            for agent_id in targets:
                self.state.group_chat.set_typing(agent_id, True, dispatch_id=dispatch_id)
            try:
                subprocess.Popen(
                    [
                        "python3",
                        self.state.bus_send_path,
                        "--source", "ios-group",
                        "--sender", sender_id,
                        "--channel", "group",
                        "--text", text,
                        "--message-id", rec["id"],
                        "--parent-msg-id", str(body.get("parent_msg_id") or ""),
                        "--mentions", ",".join(mentions),
                        "--to", ",".join(targets),
                        "--context", context,
                        "--hop-count", str(hop_count + 1),
                        "--inject-only",
                    ],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except Exception as e:
                logger.warning("group bus_send fail: %s", e)
                delivery["failed"] = targets
                delivery["targets"] = targets
                for agent_id in targets:
                    self.state.group_chat.set_typing(agent_id, False, dispatch_id=dispatch_id)

        self._send_json(200, {"ok": True, "record": rec, "targets": targets})

    def _handle_group_append(self, body: dict[str, Any]):
        text = str(body.get("text") or "").strip()
        sender_id = str(body.get("sender_id") or body.get("agent_id") or "").strip()
        if not sender_id:
            self._send_json(400, {"error": "sender_id required"})
            return
        if not text:
            self._send_json(400, {"error": "text required"})
            return
        # 2026-05-05 dedupe storm guard: 同 sender 同 text 在 3 秒内重复 直接 reject
        # 防 ios client retry loop / double tap 把群刷爆
        cache = getattr(self, "_group_dedupe_cache", None)
        if cache is None:
            cache = {}
            type(self)._group_dedupe_cache = cache  # 类级共享
        cache_key = f"{sender_id}|{text[:200]}"
        now_ts = time.time()
        last_ts = cache.get(cache_key, 0)
        if now_ts - last_ts < 3.0:
            self._send_json(429, {"ok": False, "error": "duplicate within 3s window", "deduped": True})
            return
        cache[cache_key] = now_ts
        # 清旧 entry (超过 60s 的)
        for k in list(cache.keys()):
            if now_ts - cache[k] > 60:
                del cache[k]
        mentions = self.state.group_chat.normalize_mentions(body.get("mentions"), text)
        message_type = str(body.get("message_type") or "chat").strip().lower()
        owner = str(body.get("owner") or "").strip() or self._infer_group_task_owner(body, mentions)
        # 2026-05-05 用户 push 加 agent 互相 @ 功能
        # parent message 的 hop_count + 1 当前 message hop_count 用于 loop guard
        hop_count = int(body.get("hop_count", 0) or 0)
        targets = self.state.group_chat.targets_for(sender_id, mentions, self._group_online_agents(), hop_count=hop_count)
        try:
            rec = self.state.group_chat.append(
                sender_id,
                text,
                source=str(body.get("source") or f"tmux:{sender_id}"),
                mentions=mentions,
                parent_msg_id=body.get("parent_msg_id") or None,
                reply_to=body.get("reply_to") or None,
                delivery={"targets": targets, "delivered": [], "failed": []},
                meta={"loop_depth": hop_count},
                message_type=message_type,
                task_id=str(body.get("task_id") or "").strip() or None,
                parent_task_id=str(body.get("parent_task_id") or "").strip() or None,
                owner=owner,
            )
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
            return
        self.state.group_chat.set_typing(sender_id, False)
        # 2026-05-05 加 fan-out trigger 当 sender 是 agent + mentions 含 agent
        if targets:
            dispatch_id = f"dsp_{int(time.time() * 1000)}"
            context = "\n".join(self.state.group_chat.context_lines(limit=20))
            for agent_id in targets:
                self.state.group_chat.set_typing(agent_id, True, dispatch_id=dispatch_id)
            try:
                subprocess.Popen(
                    [
                        "python3",
                        self.state.bus_send_path,
                        "--source", "ios-group",
                        "--sender", sender_id,
                        "--channel", "group",
                        "--text", text,
                        "--message-id", rec["id"],
                        "--parent-msg-id", str(body.get("parent_msg_id") or ""),
                        "--mentions", ",".join(mentions),
                        "--to", ",".join(targets),
                        "--context", context,
                        "--hop-count", str(hop_count + 1),
                        "--inject-only",
                    ],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except Exception as e:
                logger.warning("group fan-out fail: %s", e)
                for agent_id in targets:
                    self.state.group_chat.set_typing(agent_id, False, dispatch_id=dispatch_id)
        self._send_json(200, {"ok": True, "record": rec, "targets": targets})

    def _infer_group_task_owner(self, body: dict[str, Any], mentions: list[str]) -> str | None:
        assignee = body.get("assignee") or body.get("assigned_to")
        if assignee:
            return str(assignee).strip()
        for agent_id in mentions:
            if agent_id in {"opia", "sonnet", "shu", "opus47_fresh"}:
                return agent_id
        return None

    def _handle_group_delete(self, body: dict[str, Any]):
        msg_id = str(body.get("id") or "").strip()
        if not msg_id:
            self._send_json(400, {"error": "id required"})
            return
        ok = self.state.group_chat.delete(msg_id)
        self._send_json(200, {"ok": ok, "id": msg_id})

    def _handle_group_clear(self, body: dict[str, Any]):
        # 2026-05-05 一键清屏 仅 amian 可调
        sender_id = str(body.get("sender_id") or "").strip()
        if sender_id != "amian":
            self._send_json(403, {"error": "only amian can clear group"})
            return
        try:
            jsonl = self.state.group_chat.path
            if jsonl.exists():
                from datetime import datetime
                ts_tag = datetime.now().strftime("%Y%m%d_%H%M%S")
                bak = jsonl.with_suffix(jsonl.suffix + f".bak.user-clear.{ts_tag}")
                bak.write_bytes(jsonl.read_bytes())
                jsonl.write_text("")
                self.state.group_chat._last_ts = ""
            self._send_json(200, {"ok": True, "cleared": True, "backup": str(bak) if jsonl.exists() else None})
        except Exception as e:
            self._send_json(500, {"ok": False, "error": str(e)})

    # ---------- calendar handlers ----------

    def _handle_calendar_categories(self):
        self._send_json(200, {"ok": True, "categories": self.state.calendar.categories()})

    def _handle_calendar_list(self):
        events = self.state.calendar.list_all()
        self._send_json(200, {"ok": True, "events": events, "count": len(events)})

    def _handle_calendar_day(self):
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        date = qs.get("date", [""])[0]
        if not date or len(date) < 10:
            self._send_json(400, {"error": "date=YYYY-MM-DD required"})
            return
        events = self.state.calendar.list_day(date[:10])
        self._send_json(200, {"ok": True, "events": events, "date": date[:10]})

    def _handle_calendar_month(self):
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        try:
            year = int(qs.get("year", [str(datetime.now().year)])[0])
            month = int(qs.get("month", [str(datetime.now().month)])[0])
        except ValueError:
            self._send_json(400, {"error": "year/month must be int"})
            return
        events = self.state.calendar.list_month(year, month)
        self._send_json(200, {"ok": True, "events": events, "year": year, "month": month})

    def _handle_calendar_add(self, body: dict[str, Any]):
        try:
            rec = self.state.calendar.add(
                title=str(body.get("title") or ""),
                category=str(body.get("category") or "personal"),
                start_ts=str(body.get("start_ts") or ""),
                end_ts=body.get("end_ts"),
                notes=body.get("notes"),
                all_day=bool(body.get("all_day", False)),
                source=str(body.get("source") or "manual"),
                source_msg_id=body.get("source_msg_id"),
            )
            self._send_json(200, {"ok": True, "event": rec})
        except ValueError as e:
            self._send_json(400, {"ok": False, "error": str(e)})

    def _handle_calendar_update(self, body: dict[str, Any]):
        event_id = str(body.get("id") or "").strip()
        if not event_id:
            self._send_json(400, {"error": "id required"})
            return
        patch = {k: v for k, v in body.items() if k != "id"}
        if "category" in patch:
            patch["color"] = CATEGORIES.get(str(patch["category"]), "#7F8C8D")
        rec = self.state.calendar.update(event_id, **patch)
        if not rec:
            self._send_json(404, {"ok": False, "error": "event not found"})
            return
        self._send_json(200, {"ok": True, "event": rec})

    def _handle_calendar_delete(self, body: dict[str, Any]):
        event_id = str(body.get("id") or "").strip()
        if not event_id:
            self._send_json(400, {"error": "id required"})
            return
        ok = self.state.calendar.delete(event_id)
        self._send_json(200 if ok else 404, {"ok": ok, "id": event_id})

    def _handle_calendar_tick(self, body: dict[str, Any]):
        # 由 launchd 每 60s POST 触发. 找 due 事件 → APNs alert + chat ping → mark fired.
        due = self.state.calendar.due_within(lookahead_seconds=70)
        fired_ids: list[str] = []
        for ev in due:
            try:
                self._calendar_fire_event(ev)
                self.state.calendar.mark_fired(ev["id"])
                fired_ids.append(ev["id"])
            except Exception as e:
                logger.warning("calendar tick fire fail %s: %s", ev.get("id"), e)
        self._send_json(200, {"ok": True, "fired": fired_ids, "count": len(fired_ids)})

    def _calendar_fire_event(self, ev: dict[str, Any]):
        # build 70 phase 1: 只做 chat ping. APNs alert 推到 phase 2 (需要接 client.push_simple_alert 还没实现).
        try:
            from datetime import datetime
            now = datetime.now().strftime("%H:%M")
            cat = CATEGORY_LABELS.get(ev.get("category", "personal"), "")
            note_part = f" ({ev.get('notes')})" if ev.get("notes") else ""
            ping_text = f"[日程·{cat}] {now} {ev.get('title', '事件')}{note_part}"
            self.state.chat.append({"role": "assistant", "text": ping_text, "source": "calendar:tick"})
        except Exception as e:
            logger.warning("calendar chat ping fail: %s", e)

    def _handle_group_dispatch_state(self, body: dict[str, Any]):
        agent_id = str(body.get("agent_id") or "").strip()
        if not agent_id:
            self._send_json(400, {"error": "agent_id required"})
            return
        self.state.group_chat.set_typing(
            agent_id,
            bool(body.get("is_typing")),
            dispatch_id=body.get("dispatch_id") or None,
        )
        self._send_json(200, {"ok": True, "status": self.state.group_chat.status_snapshot(self._group_tmux_session_exists)})

    # ---------- 书房 v1 handlers (2026-05-09) ----------

    def _handle_studyroom_today(self):
        try:
            payload = self.state.studyroom.today_payload()
            self._send_json(200, {"ok": True, **payload})
        except Exception as e:
            logger.warning("studyroom_today fail: %s", e)
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_studyroom_projects(self):
        try:
            grouped = self.state.studyroom.projects_payload()
            self._send_json(200, {"ok": True, **grouped})
        except Exception as e:
            logger.warning("studyroom_projects fail: %s", e)
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_studyroom_project(self):
        from urllib.parse import urlparse, unquote
        path = urlparse(self.path).path
        slug = unquote(path[len("/studyroom/project/"):]).strip("/")
        if not slug:
            self._send_json(400, {"ok": False, "error": "slug required"})
            return
        try:
            data = self.state.studyroom.project_payload(slug)
            if data is None:
                self._send_json(404, {"ok": False, "error": "not found"})
                return
            self._send_json(200, {"ok": True, **data})
        except Exception as e:
            logger.warning("studyroom_project fail: %s", e)
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_group_typing(self, body: dict[str, Any]):
        """POST /group/typing — chain hook 推 typing+status_text. spec 2026-05-09.
        body: {sender_id, is_typing, status_text?, dispatch_id?}
        """
        agent_id = str(body.get("sender_id") or body.get("agent_id") or "").strip()
        if not agent_id:
            self._send_json(400, {"error": "sender_id required"})
            return
        is_typing = bool(body.get("is_typing"))
        # status_text: pass through verbatim. None = leave; "" = clear; str = set
        if "status_text" in body:
            status_text = body.get("status_text")
            status_text = "" if status_text is None else str(status_text)
        else:
            status_text = None
        self.state.group_chat.set_typing(
            agent_id,
            is_typing,
            dispatch_id=body.get("dispatch_id") or None,
            status_text=status_text,
        )
        self._send_json(200, {"ok": True})

    # ---------- chat handlers ----------

    def _serve_web_chat(self):
        html = WEB_CHAT_HTML.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(html)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(html)

    def _handle_chat_history(self):
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        since = qs.get("since", [None])[0]
        before = qs.get("before", qs.get("before_ts", [None]))[0]  # 向上翻页 拉 before_ts 之前的旧消息
        around_ts = qs.get("around_ts", [None])[0]  # 2026-05-07 用户 push 跳原文 围绕 ts 前后取
        try:
            limit = int(qs.get("limit", ["10000"])[0])
        except Exception:
            limit = 10000
        try:
            n_around = int(qs.get("n", ["25"])[0])
        except Exception:
            n_around = 25
        # iOS 本地 SwiftData 首次同步需要全量；UI 自己只渲染最近窗口。
        limit = min(max(limit, 1), 10000)
        n_around = min(max(n_around, 1), 200)
        if around_ts:
            chat_records = self.state.chat.read_around(ts=around_ts, n=n_around)
        else:
            chat_records = self.state.chat.read_since(since_ts=since, before_ts=before, limit=limit)
        # task records 走 /chat/poll 不混入持久 history (prevents stale task injection causing scroll-jump)
        records = chat_records
        self._send_json(200, {"ok": True, "records": records, "count": len(records)})

    def _handle_chat_search(self):
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        keyword = qs.get("q", [None])[0]
        date_prefix = qs.get("date", [None])[0]
        role = qs.get("role", [None])[0]
        try:
            limit = int(qs.get("limit", ["5000"])[0])
        except Exception:
            limit = 5000
        limit = min(max(limit, 1), 10000)
        records = self.state.chat.search(
            keyword=keyword,
            date_prefix=date_prefix,
            role=role,
            limit=limit,
        )
        self._send_json(200, {"ok": True, "records": records, "count": len(records)})

    def _handle_chain_abort(self, body: dict[str, Any]):
        """2026-05-07 用户 push: 紧急停止 chain. tmux send-keys C-c 到目标 session.
        session 名 allowlist 防滥用."""
        session = str(body.get("session") or "opia").strip()
        ALLOWED = {"opia", "shu", "bao", "opus", "opus47_fresh", "sonnet"}
        logger.info("chain/abort received session=%r", session)
        if session not in ALLOWED:
            logger.warning("chain/abort rejected session=%r not in allowlist", session)
            self._send_json(400, {"ok": False, "error": f"session not in allowlist: {session}"})
            return
        try:
            import subprocess
            import time as _t
            # 2026-05-07 单次 Escape 不够 cc 仍 emit 一段简短 reply 多发 3 次间隔 0.2s 真 hard quiet
            last_returncode = 0
            for i in range(3):
                res = subprocess.run(
                    ["tmux", "send-keys", "-t", session, "Escape"],
                    capture_output=True, text=True, timeout=5,
                )
                last_returncode = res.returncode
                logger.info(
                    "chain/abort tmux Escape #%d exit=%d stderr=%r",
                    i + 1, res.returncode, res.stderr,
                )
                if i < 2:
                    _t.sleep(0.2)
            res = subprocess.CompletedProcess(args=[], returncode=last_returncode, stdout='', stderr='')
            # 2026-05-10 用户 catch typing 状态没 reset abort 后客户端还显"正在输入"
            self.state.typing_state = {"is_typing": False, "since": None}
            if res.returncode == 0:
                self._send_json(200, {"ok": True, "session": session, "action": "abort"})
            else:
                self._send_json(500, {"ok": False, "error": res.stderr or "tmux send-keys failed", "exit": res.returncode})
        except Exception as e:
            logger.error("chain/abort exception: %s", e)
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_chain_clear(self, body: dict[str, Any]):
        """2026-05-07 cc 内 /clear 清 context 不重启进程."""
        session = str(body.get("session") or "opia").strip()
        ALLOWED = {"opia", "shu", "bao", "opus", "opus47_fresh", "sonnet"}
        logger.info("chain/clear received session=%r", session)
        if session not in ALLOWED:
            self._send_json(400, {"ok": False, "error": f"session not allowed: {session}"})
            return
        try:
            import subprocess
            subprocess.run(["tmux", "send-keys", "-t", session, "/clear"], timeout=5)
            subprocess.run(["tmux", "send-keys", "-t", session, "Enter"], timeout=5)
            self._send_json(200, {"ok": True, "session": session, "action": "clear"})
        except Exception as e:
            logger.error("chain/clear exception: %s", e)
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_chain_restart(self, body: dict[str, Any]):
        """2026-05-07 麻醉 退 cc + (TODO) 起新 cc resume. 当前先实现退出."""
        session = str(body.get("session") or "opia").strip()
        ALLOWED = {"opia", "shu", "bao", "opus", "opus47_fresh", "sonnet"}
        logger.info("chain/restart received session=%r", session)
        if session not in ALLOWED:
            self._send_json(400, {"ok": False, "error": f"session not allowed: {session}"})
            return
        try:
            import subprocess, time as _t
            # cc 内连按两次 Ctrl+C 退出 (cc 第一次提示"Press Ctrl+C again to exit")
            subprocess.run(["tmux", "send-keys", "-t", session, "C-c"], timeout=5)
            _t.sleep(0.3)
            subprocess.run(["tmux", "send-keys", "-t", session, "C-c"], timeout=5)
            _t.sleep(0.5)
            # 起新 cc 进程 (resume 上一个 session)
            subprocess.run(["tmux", "send-keys", "-t", session, "claude --resume", "Enter"], timeout=5)
            self._send_json(200, {"ok": True, "session": session, "action": "restart", "note": "cc 退出 + 自动 resume 上一 session"})
        except Exception as e:
            logger.error("chain/restart exception: %s", e)
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_chain_sessions_get(self):
        """Phase B /chain/sessions — list tmux sessions, mark active."""
        try:
            result = subprocess.run(
                ["tmux", "list-sessions", "-F", "#{session_name}:#{session_windows}:#{session_attached}"],
                capture_output=True, text=True, timeout=5
            )
            sessions = []
            for line in result.stdout.strip().splitlines():
                parts = line.split(":")
                sid = parts[0] if parts else "?"
                sessions.append({
                    "sid": sid,
                    "active": sid == self.state.active_session,
                })
            self._send_json(200, {"ok": True, "sessions": sessions, "active_sid": self.state.active_session})
        except Exception as e:
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_chain_new_session(self, body: dict[str, Any]):
        """Phase B /chain/new_session — create new tmux session + start CC.
        2026-05-14 — 之前默认自动 switch active_session 到新建的 sid 但用户测试一下就被踢到
        陌生的新 claude 不知道 UX 不友好. 改成"创了但不切" 用户想切过去再 /switch <sid> 显式."""
        import time as _t
        counter = _t.strftime("%H%M%S")
        new_sid = f"opia-{counter}"
        try:
            subprocess.run(["tmux", "new-session", "-d", "-s", new_sid], check=True, timeout=10)
            _t.sleep(0.5)
            subprocess.run(
                ["tmux", "send-keys", "-t", new_sid, "claude --dangerously-skip-permissions", "Enter"],
                timeout=5
            )
            # 不自动 switch active_session 用户想切过去发 /switch <sid> 自己切
            current_active = self.state.active_session
            logger.info("chain/new_session created sid=%s (active stays at %s)", new_sid, current_active)
            self._send_json(200, {
                "ok": True,
                "sid": new_sid,
                "active_sid": current_active,
                "note": f"新建 {new_sid} cc 启动中. active 还在 {current_active}. 想切过去发 /switch {new_sid}"
            })
        except Exception as e:
            logger.error("chain/new_session exception: %s", e)
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_chain_switch(self, body: dict[str, Any]):
        """Phase B /chain/switch — persist active_session for future chat sends."""
        sid = str(body.get("sid") or "opia").strip()
        if not sid:
            self._send_json(400, {"error": "sid required"})
            return
        # Verify session exists
        try:
            res = subprocess.run(
                ["tmux", "has-session", "-t", sid],
                capture_output=True, timeout=5
            )
            if res.returncode != 0:
                self._send_json(404, {"ok": False, "error": f"session '{sid}' not found"})
                return
        except Exception:
            pass
        self.state.active_session = sid
        _persist_active_session(self.state)
        logger.info("chain/switch active_session=%s", sid)
        self._send_json(200, {"ok": True, "active_sid": sid})

    def _handle_session_info(self):
        """主对话流 session id (从最新 .jsonl 找 sessionId)."""
        try:
            from pathlib import Path
            base = Path.home() / ".claude" / "projects" / "-Users-mian"
            sid = "unknown"
            mtime = 0.0
            if base.exists():
                latest = max(base.glob("*.jsonl"), key=lambda p: p.stat().st_mtime, default=None)
                if latest:
                    sid = latest.stem
                    mtime = latest.stat().st_mtime
            from datetime import datetime as _dt
            self._send_json(200, {
                "ok": True,
                "session_id": sid,
                "session_id_short": sid[:8] if sid != "unknown" else sid,
                "last_active": _dt.fromtimestamp(mtime).isoformat(timespec="seconds") if mtime else None,
            })
        except Exception as e:
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_session_usage(self):
        """今日 / 累计 token (临时 stub 后续接 ccusage)."""
        # TODO: 接真 ccusage
        self._send_json(200, {
            "ok": True,
            "today_input": 50000,
            "today_output": 8000,
            "today_total": 58000,
            "cumulative_total": 1500000,
            "stub": True,
        })

    def _handle_connections_status(self):
        """各通道 status (绿/红 + last seen)."""
        import subprocess, os
        from datetime import datetime as _dt
        def launchd_active(label: str) -> bool:
            try:
                r = subprocess.run(["launchctl", "list", label], capture_output=True, text=True, timeout=2)
                return r.returncode == 0
            except Exception:
                return False
        def tmux_alive(s: str) -> bool:
            try:
                r = subprocess.run(["tmux", "has-session", "-t", s], capture_output=True, timeout=2)
                return r.returncode == 0
            except Exception:
                return False
        def file_recent(path: str, hours: int = 24) -> bool:
            try:
                p = os.path.expanduser(path)
                if not os.path.exists(p):
                    return False
                age_h = (_dt.now().timestamp() - os.path.getmtime(p)) / 3600
                return age_h < hours
            except Exception:
                return False
        try:
            chat_path = "/path/to/CcCompanion/apns-server/tokens/chat_history.jsonl"
            group_path = "/path/to/CcCompanion/apns-server/tokens/group_chat.jsonl"
            self._send_json(200, {
                "ok": True,
                "connections": {
                    "wechat": launchd_active("com.opia.watchdog"),
                    "aisay": file_recent("~/CcCompanion/aisay-state/last_ack.json", 6),
                    "ios_chat": True,
                    "workgroup": file_recent(group_path, 24),
                    "terminal_opia": tmux_alive("opia"),
                    "heartbeat": launchd_active("com.opia.heartbeat"),
                    "chat_recent": file_recent(chat_path, 1),
                },
            })
        except Exception as e:
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_vault_stats(self):
        """vault md 文件数 + 累计字数."""
        import subprocess
        try:
            base = "/Users/mian/Documents/星原"
            count_r = subprocess.run(
                ["bash", "-c", f"find '{base}' -name '*.md' -type f 2>/dev/null | wc -l"],
                capture_output=True, text=True, timeout=10,
            )
            file_count = int(count_r.stdout.strip() or 0)
            self._send_json(200, {
                "ok": True,
                "path": base,
                "file_count": file_count,
                "total_chars": 2_915_161,  # stub: 全 md cat | wc -m 太慢
                "mode": "工作模式",
                "stub_chars": True,
            })
        except Exception as e:
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_group_stats(self):
        """工作群今日条数."""
        import json as _json
        from datetime import datetime as _dt
        try:
            today = _dt.now().strftime("%Y-%m-%d")
            count = 0
            path = "/path/to/CcCompanion/apns-server/tokens/group_chat.jsonl"
            try:
                with open(path) as f:
                    for line in f:
                        try:
                            r = _json.loads(line)
                            if r.get("ts", "").startswith(today):
                                count += 1
                        except Exception:
                            pass
            except FileNotFoundError:
                pass
            self._send_json(200, {"ok": True, "today_count": count})
        except Exception as e:
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_build_last_ship(self):
        """最新 .xcarchive mtime."""
        import os
        from datetime import datetime as _dt
        try:
            archive_dir = "/Users/mian/Library/Developer/Xcode/Archives"
            latest_mtime = 0.0
            latest_path = ""
            if os.path.exists(archive_dir):
                for root, dirs, _ in os.walk(archive_dir):
                    for d in dirs:
                        if d.endswith(".xcarchive"):
                            full = os.path.join(root, d)
                            m = os.path.getmtime(full)
                            if m > latest_mtime:
                                latest_mtime = m
                                latest_path = full
            self._send_json(200, {
                "ok": True,
                "last_ship": _dt.fromtimestamp(latest_mtime).isoformat(timespec="seconds") if latest_mtime else None,
                "archive": os.path.basename(latest_path) if latest_path else None,
            })
        except Exception as e:
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_storage_stats(self):
        """attachments 总大小 + chat history jsonl 大小."""
        import os
        try:
            att_dir = "/path/to/CcCompanion/apns-server/tokens/attachments"
            att_bytes = 0
            for root, _, files in os.walk(att_dir):
                for f in files:
                    try:
                        att_bytes += os.path.getsize(os.path.join(root, f))
                    except Exception:
                        pass
            chat_path = "/path/to/CcCompanion/apns-server/tokens/chat_history.jsonl"
            chat_bytes = os.path.getsize(chat_path) if os.path.exists(chat_path) else 0
            self._send_json(200, {
                "ok": True,
                "attachments_bytes": att_bytes,
                "chat_history_bytes": chat_bytes,
            })
        except Exception as e:
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_debug_server_log(self):
        """tail -50 server.log."""
        try:
            log_path = "/path/to/CcCompanion/apns-server/server.err.log"
            try:
                with open(log_path) as f:
                    lines = f.readlines()[-50:]
            except FileNotFoundError:
                lines = []
            self._send_json(200, {"ok": True, "lines": [l.rstrip("\n") for l in lines]})
        except Exception as e:
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_chat_send(self, body: dict[str, Any]):
        """iPhone 发消息进来 → 写 user 条 + 调 bus_send.py 注入主 session"""
        text = body.get("text", "").strip()
        quoted_ts = body.get("quoted_ts") or None
        location = body.get("location") or None
        if not text and not location:
            self._send_json(400, {"error": "text or location required"})
            return
        # 写 user 历史
        rec = self.state.chat.append(
            role="user",
            text=text,
            source="ios-app",
            quoted_ts=quoted_ts,
            location=location,
        )
        # 包 quote 进注入文本 (主 session 收到 channel tag 内含 quote 上下文 + 时间戳跟 wechat 一致)
        from datetime import datetime as _dt
        ts_prefix = "[" + _dt.now().strftime("%Y-%m-%d %H:%M:%S") + "]"
        # TTS 模式 hint — 让 chain 看到自动带标点
        tts_hint = ""
        if self.state.settings.get("tts_enabled"):
            tts_hint = "[语音模式 这一条带标点回复]\n"
        injected = f"{ts_prefix} {tts_hint}{text}"
        if rec.get("location"):
            loc = rec["location"]
            label = loc.get("label", "")
            loc_str = f"[位置 lat={loc['lat']:.6f} lon={loc['lon']:.6f}{(' ' + label) if label else ''}]"
            injected = f"{ts_prefix} {tts_hint}{loc_str}"
            if text:
                injected = f"{injected}\n{text}"
        if rec.get("quoted_text"):
            injected = f"{ts_prefix} {tts_hint}[引用 \"{rec['quoted_text']}\"]\n{text}"
            if rec.get("location"):
                injected = f"{ts_prefix} {tts_hint}[引用 \"{rec['quoted_text']}\"]\n{loc_str}"
                if text:
                    injected = f"{injected}\n{text}"
        # set typing — Cc 收到 message 在 thinking
        self.state.typing_state = {"is_typing": True, "since": rec["ts"]}
        # 注入文本到 active tmux session
        # 2026-05-14 build 200 — 不依赖 ~/scripts/bus_send.py (Opia 内部 file, ccc 公开版用户没有)
        # 如果 bus_send.py 存在 用它走 bus dispatcher 路由 (Opia 内部多 agent 协调用)
        # 不存在 fallback 直接 tmux paste-buffer + send-keys 注入 (ccc 公开版默认走这条)
        target_session = (self.state.active_session or "opia").strip()
        ok, err = self._inject_to_session(target_session, injected, source="ios-app", sender="iphone")
        if not ok:
            # 注入失败 (target session 不存在 / tmux 没装 / bus_send crash 等). 用 502 surface
            # 给客户端 不再 silent 200 — 否则 ccc app 显示发送成功但 chain 根本收不到.
            self._send_json(502, {
                "ok": False,
                "error": f"inject to tmux session '{target_session}' failed: {err}",
                "record": rec,
            })
            return
        self._send_json(200, {"ok": True, "record": rec})

    def _inject_to_session(self, session: str, text: str, source: str = "ios-app", sender: str = "iphone"):
        """Inject text into target tmux session. Returns (success, error_msg).

        Prefer bus_send.py (Opia internal bus dispatcher routing for multi-agent coord)
        if both the script exists AND /tmp/opia_bus.sock is reachable (dispatcher running).
        Otherwise fall back to direct tmux load-buffer + paste-buffer + send-keys,
        which is what ccc public users get by default — no Opia internal daemon required.
        """
        import os
        import socket
        bus_path = self.state.bus_send_path
        bus_sock = "/tmp/opia_bus.sock"
        bus_ready = False
        if bus_path and os.path.exists(bus_path) and os.path.exists(bus_sock):
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                    s.settimeout(0.2)
                    s.connect(bus_sock)
                bus_ready = True
            except Exception:
                bus_ready = False
        if bus_ready:
            try:
                subprocess.Popen(
                    [
                        "python3",
                        bus_path,
                        "--source", source,
                        "--sender", sender,
                        "--text", text,
                        "--target", session,
                    ],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                return True, ""
            except Exception as e:
                logger.warning("bus_send fail, falling back to tmux: %s", e)
        # Fallback: direct tmux paste-buffer + send-keys (ccc public default).
        # 先 verify target session 存在 — 不然 paste-buffer/send-keys 会 silently 失败.
        try:
            has = subprocess.run(
                ["tmux", "has-session", "-t", session],
                capture_output=True, text=True, timeout=2,
            )
            if has.returncode != 0:
                err = f"tmux session not found (run `tmux new-session -d -s {session} 'claude --dangerously-skip-permissions'`)"
                logger.warning("tmux inject: %s", err)
                return False, err
        except FileNotFoundError:
            return False, "tmux not installed (brew install tmux)"
        except Exception as e:
            return False, f"tmux has-session check failed: {e}"
        try:
            p = subprocess.Popen(
                ["tmux", "load-buffer", "-"],
                stdin=subprocess.PIPE,
            )
            p.communicate(input=text.encode("utf-8"))
            paste = subprocess.run(
                ["tmux", "paste-buffer", "-t", session, "-p"],
                capture_output=True, text=True, timeout=3,
            )
            if paste.returncode != 0:
                return False, f"tmux paste-buffer failed: {paste.stderr.strip()}"
            send = subprocess.run(
                ["tmux", "send-keys", "-t", session, "Enter"],
                capture_output=True, text=True, timeout=3,
            )
            if send.returncode != 0:
                return False, f"tmux send-keys failed: {send.stderr.strip()}"
            return True, ""
        except Exception as e:
            err = f"tmux inject failed: {e}"
            logger.warning("%s (session=%s)", err, session)
            return False, err

    def _handle_pet_state_get(self):
        """GET /pet/state — 当前 latest 状态."""
        self._send_json(200, {"ok": True, "latest": self.state.pet.latest()})

    def _handle_pet_state_post(self, body: dict[str, Any]):
        """POST /pet/state — chain hook 上报状态. body: {state, reason?, ts?}.
        VALID_STATES: idle/thinking/typing/building/juggling/conducting/error/happy/notification/sweeping/carrying/sleeping."""
        state = str(body.get("state") or "").strip()
        reason = str(body.get("reason") or "")
        ts = body.get("ts")
        if not state:
            self._send_json(400, {"error": "state required"})
            return
        rec = self.state.pet.update(state=state, reason=reason, ts=ts)
        # 推 SSE
        self.state.pet_bus.publish(rec)
        self._send_json(200, {"ok": True, "rec": rec})

    def _handle_pet_bubble_post(self, body: dict[str, Any]):
        """POST /pet/bubble — chain hook 推 speech bubble. body: {text, ts?}.
        text 已截好 (前 30 字 + ...) chain hook 那侧负责截.
        """
        text = str(body.get("text") or "").strip()
        ts = body.get("ts") or ""
        if not text:
            self._send_json(400, {"error": "text required"})
            return
        if not ts:
            from datetime import datetime, timezone, timedelta
            tz = timezone(timedelta(hours=8))
            ts = datetime.now(tz).isoformat(timespec="milliseconds")
        rec = {"text": text, "ts": ts}
        self.state.pet_bubble_bus.publish(rec)
        self._send_json(200, {"ok": True, "rec": rec})

    def _handle_pet_stream(self):
        """GET /pet/stream — SSE 实时推送 pet 状态变化.
        client 接 EventSource (iOS URLSession streaming / Mac Electron native)."""
        import time as _t
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        # 先发当前 latest
        latest = self.state.pet.latest()
        try:
            self.wfile.write(f"data: {json.dumps(latest, ensure_ascii=False)}\n\n".encode("utf-8"))
            self.wfile.flush()
        except Exception:
            return
        # 订阅 bus (state + bubble 共用一条 SSE; client 用 event 字段区分)
        q = self.state.pet_bus.subscribe()
        bq = self.state.pet_bubble_bus.subscribe()
        try:
            while True:
                wrote = False
                if q:
                    rec = q.popleft()
                    payload = dict(rec)
                    payload.setdefault("event", "state")
                    try:
                        self.wfile.write(f"data: {json.dumps(payload, ensure_ascii=False)}\n\n".encode("utf-8"))
                        self.wfile.flush()
                        wrote = True
                    except Exception:
                        break
                if bq:
                    brec = bq.popleft()
                    payload = dict(brec)
                    payload["event"] = "bubble"
                    try:
                        self.wfile.write(f"data: {json.dumps(payload, ensure_ascii=False)}\n\n".encode("utf-8"))
                        self.wfile.flush()
                        wrote = True
                    except Exception:
                        break
                if not wrote:
                    # heartbeat keepalive 不让 client 断
                    try:
                        self.wfile.write(b": keepalive\n\n")
                        self.wfile.flush()
                    except Exception:
                        break
                    _t.sleep(1.0)
        finally:
            self.state.pet_bus.unsubscribe(q)
            self.state.pet_bubble_bus.unsubscribe(bq)

    def _handle_pet_activity_post(self, body: dict[str, Any]):
        """POST /pet/activity — chain hook 推 streaming terminal display 行.
        body: {event_type, tool_name, summary, ts?}
        event_type: pre_tool / post_tool / stop / user_prompt
        """
        event_type = str(body.get("event_type") or "").strip() or "pre_tool"
        tool_name = str(body.get("tool_name") or "").strip()
        summary = str(body.get("summary") or "").strip()
        friendly_label = str(body.get("friendly_label") or "").strip()
        ts = body.get("ts")
        if not ts:
            from datetime import datetime, timezone, timedelta
            tz = timezone(timedelta(hours=8))
            ts = datetime.now(tz).isoformat(timespec="milliseconds")
        rec = {
            "event_type": event_type,
            "tool_name": tool_name,
            "summary": summary,
            "friendly_label": friendly_label,
            "ts": ts,
        }
        self.state.pet_activity_bus.publish(rec)
        self._send_json(200, {"ok": True, "rec": rec})

    def _handle_pet_activity_stream(self):
        """GET /pet/activity_stream — SSE 推 chain 实时活动 (terminal display)."""
        import time as _t
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        q = self.state.pet_activity_bus.subscribe()
        try:
            while True:
                wrote = False
                if q:
                    rec = q.popleft()
                    try:
                        self.wfile.write(f"data: {json.dumps(rec, ensure_ascii=False)}\n\n".encode("utf-8"))
                        self.wfile.flush()
                        wrote = True
                    except Exception:
                        break
                if not wrote:
                    try:
                        self.wfile.write(b": keepalive\n\n")
                        self.wfile.flush()
                    except Exception:
                        break
                    _t.sleep(1.0)
        finally:
            self.state.pet_activity_bus.unsubscribe(q)

    def _handle_pet_animations(self):
        """GET /pet/animations — 列出本地 svg 资产路径 (供 client 拉取或直接 file:// load)."""
        from pathlib import Path as _P
        svg_dir = _P("/path/to/CcCompanion/handy-clawd-assets/svg")
        if not svg_dir.exists():
            self._send_json(404, {"error": "svg dir missing", "expected": str(svg_dir)})
            return
        files = sorted([p.name for p in svg_dir.glob("*.svg")])
        self._send_json(200, {"ok": True, "count": len(files), "svg_dir": str(svg_dir), "files": files})

    def _handle_chat_regenerate(self, body: dict[str, Any]):
        """2026-05-08 用户 push 重新发言. iOS 长按 assistant msg 选 regenerate.
        flow:
        1 mark old assistant msg hidden_in_ui (UI 不展示但 jsonl 留备查)
        2 中断 chain (tmux Escape x 3 复用 chain_abort 逻辑)
        3 user_text 包 [regenerate] 标记调 bus_send 注入主 session
        4 chain 跑出新回复 走现有 stop hook 写 chat_history
        body: {"replace_msg_id": "ts", "user_text": "...", "client_msg_id": "uuid for dedupe"}
        """
        replace_msg_id = str(body.get("replace_msg_id") or "").strip()
        extra_replace_ids = [str(x).strip() for x in (body.get("extra_replace_ids") or []) if x]
        user_text = str(body.get("user_text") or "").strip()
        client_msg_id = body.get("client_msg_id")
        if not replace_msg_id or not user_text:
            self._send_json(400, {"error": "replace_msg_id and user_text required"})
            return

        # dedupe 5s 窗口防快速点击
        cache = getattr(type(self), "_regen_dedupe_cache", None)
        if cache is None:
            cache = {}
            type(self)._regen_dedupe_cache = cache
        now_ts = time.time()
        cache_key = f"cmid:{client_msg_id}" if client_msg_id else f"replace:{replace_msg_id}"
        last_ts = cache.get(cache_key, 0)
        if now_ts - last_ts < 5.0:
            self._send_json(429, {"ok": False, "error": "duplicate within 5s window", "deduped": True})
            return
        cache[cache_key] = now_ts
        for k in list(cache.keys()):
            if now_ts - cache[k] > 60:
                del cache[k]

        # mark old assistant msg hidden (first/primary)
        marked = self.state.chat.mark_regenerated(old_ts=replace_msg_id)
        logger.info("chat/regenerate marked=%s replace_msg_id=%s", marked, replace_msg_id)
        # mark extra turn bubbles hidden
        extra_marked = 0
        for eid in extra_replace_ids:
            if self.state.chat.mark_regenerated(old_ts=eid):
                extra_marked += 1
        if extra_replace_ids:
            logger.info("chat/regenerate extra_marked=%d ids=%s", extra_marked, extra_replace_ids)

        # 中断 chain (tmux Escape x 3 复用 chain_abort 逻辑)
        try:
            import subprocess
            import time as _t
            for i in range(3):
                subprocess.run(
                    ["tmux", "send-keys", "-t", "opia", "Escape"],
                    capture_output=True, text=True, timeout=5,
                )
                if i < 2:
                    _t.sleep(0.2)
            logger.info("chat/regenerate sent 3x Escape to opia tmux")
        except Exception as e:
            logger.warning("chat/regenerate tmux abort fail: %s", e)

        # 给一点时间让 chain 真停 然后注入新 user_text
        try:
            import time as _t2
            _t2.sleep(0.5)
        except Exception:
            pass

        # 包 ts_prefix + [regenerate] 标记 chain 看到知道这是重生成请求
        from datetime import datetime as _dt
        ts_prefix = "[" + _dt.now().strftime("%Y-%m-%d %H:%M:%S") + "]"
        tts_hint = ""
        if self.state.settings.get("tts_enabled"):
            tts_hint = "[语音模式 这一条带标点回复]\n"
        injected = f"{ts_prefix} {tts_hint}[regenerate 用户对上一条回复不满意 重新生成] {user_text}"

        # set typing
        self.state.typing_state = {"is_typing": True, "since": _dt.now().isoformat(timespec="milliseconds")}

        # 调 bus_send.py 注入主 session (异步)
        try:
            subprocess.Popen(
                [
                    "python3",
                    self.state.bus_send_path,
                    "--source", "ios-app",
                    "--sender", "iphone",
                    "--text", injected,
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception as e:
            logger.warning("bus_send fail: %s", e)

        self._send_json(200, {
            "ok": True,
            "marked_hidden": marked,
            "replace_msg_id": replace_msg_id,
            "extra_marked": extra_marked,
            "interrupted": True,
        })

    def _handle_chat_append(self, body: dict[str, Any]):
        """bus_stop_hook 抓到回复后调 → 写 assistant 条 + push spoke 状态
        也支持从 mac mini 这边发图/文件 给 iPhone:
          attachment_path (本地文件 server 复制进 attachments/) 或
          attachment_url (server 已存的 /attachments/<file>)
        """
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        text = body.get("text", "").strip()
        role = body.get("role", "assistant")
        if role == "task":
            if not text:
                self._send_json(400, {"error": "text required"})
                return
            rec = self.state.task_buffer.append(text=text, source=body.get("source", "system"))
            self._send_json(200, {"ok": True, "record": rec})
            return

        # attachment 处理
        attachment_url = body.get("attachment_url") or None
        attachment_type = body.get("attachment_type") or None
        attachment_filename = body.get("attachment_filename") or None
        local_path = body.get("attachment_path") or None
        if local_path:
            import uuid as _uuid, shutil
            src = Path(local_path).expanduser()
            if not src.exists() or not src.is_file():
                self._send_json(400, {"error": f"attachment_path not found: {src}"})
                return
            ext = src.suffix.lower()
            stored_name = f"{_uuid.uuid4().hex}{ext}"
            target = self.state.attachments_dir / stored_name
            shutil.copy2(src, target)
            attachment_url = f"/attachments/{stored_name}"
            if not attachment_type:
                image_exts = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif"}
                attachment_type = "image" if ext in image_exts else "file"
            if not attachment_filename:
                attachment_filename = src.name

        if not text and not attachment_url:
            self._send_json(400, {"error": "text or attachment required"})
            return

        # 通用 chat/append dedupe (非 move) 防 ios_reply 等客户端 retry 重复入库
        # 2026-05-07 修 用户 catch "为什么发两遍". role=move 走下面坐标幂等不动.
        # 5-7 升级 5s→60s + cmid fallback 加 attachment + 命中返回原 rec (枢 review 推荐)
        _req_t0 = time.time()
        client_msg_id = body.get("client_msg_id") or None
        dedupe_cache_key = None
        if role != "move":
            cache = getattr(type(self), "_chat_append_dedupe_cache", None)
            if cache is None:
                cache = {}
                type(self)._chat_append_dedupe_cache = cache
            now_ts = time.time()
            if client_msg_id:
                cache_key = f"cmid:{client_msg_id}"
            else:
                cache_key = f"{role}|{text[:200]}|{body.get('source', '')}|{attachment_url or ''}|{attachment_filename or ''}"
            entry = cache.get(cache_key)
            last_ts = entry[0] if isinstance(entry, tuple) else (entry or 0)
            if now_ts - last_ts < 60.0:
                cached_rec = entry[1] if isinstance(entry, tuple) else None
                _ms = int((time.time() - _req_t0) * 1000)
                print(f"chat_append_ms={_ms} dedupe_hit=1 role={role}", file=sys.stderr, flush=True)
                self._send_json(200, {"ok": True, "duplicate": True, "deduped": True, "record": cached_rec})
                return
            # 占位 真 rec 入库后回填
            cache[cache_key] = (now_ts, None)
            dedupe_cache_key = cache_key
            for k in list(cache.keys()):
                v = cache[k]
                v_ts = v[0] if isinstance(v, tuple) else v
                if now_ts - v_ts > 120:
                    del cache[k]

        if role == "move":
            # 层 1: client_msg_id 缓存
            if client_msg_id:
                cached = self.state.gomoku_msg_cache.get(client_msg_id)
                if cached is not None:
                    self._send_json(200, {"ok": True, "duplicate": True, "record": cached})
                    return
            # 层 2: 坐标幂等 — 检查当前局面该格是否已有子
            text_parts = text.split()
            if len(text_parts) >= 2 and text_parts[0] in ("black", "white"):
                coord_parts = text_parts[1].split(",")
                if len(coord_parts) == 2:
                    try:
                        move_r, move_c = int(coord_parts[0]), int(coord_parts[1])
                        state_snap = self._compute_gomoku_state()
                        dup = next(
                            (m for m in state_snap["moves"]
                             if m["row"] == move_r and m["col"] == move_c),
                            None,
                        )
                        if dup is not None:
                            existing_text = f"{dup['color']} {dup['row']},{dup['col']}"
                            existing_rec = {"ts": dup["ts"], "role": "move", "text": existing_text}
                            logger.info("gomoku dedup coord %d,%d", move_r, move_c)
                            self._send_json(200, {"ok": True, "duplicate": True, "record": existing_rec})
                            return
                    except Exception:
                        pass

        metadata = body.get("metadata") or None
        if metadata and not isinstance(metadata, dict):
            metadata = None

        rec = self.state.chat.append(
            role=role,
            text=text,
            source="ios-app",
            attachment_url=attachment_url,
            attachment_type=attachment_type,
            attachment_filename=attachment_filename,
            metadata=metadata,
        )

        # move 成功 append 后缓存 client_msg_id (LRU 100)
        if role == "move" and client_msg_id:
            cache = self.state.gomoku_msg_cache
            cache[client_msg_id] = rec
            while len(cache) > 100:
                cache.popitem(last=False)

        # role=move (五子棋落子): notify chain 让 Cc 自动收到对方 (black 用户) 落子 → 决策回手
        # 只 trigger 当 text 以 "black" 开头 (white 是我自己 chain 落 不 notify)
        if role == "move" and text.startswith("black"):
            self._notify_chain_todo(f"[用户 落子: {text}]")

        # assistant text reply 后台异步生成 TTS mp3 — 不阻塞 hook (仅 settings.tts_enabled)
        if role == "assistant" and text and not attachment_url and self.state.settings.get("tts_enabled"):
            ts = rec["ts"]
            chat = self.state.chat
            attachments_dir = self.state.attachments_dir
            def _tts_async():
                logger.info("tts multi thread start ts=%s len=%d", ts, len(text))
                try:
                    res = TTS.generate_multi(text, attachments_dir)
                except Exception as e:
                    logger.exception("tts multi gen fail")
                    return
                update_kwargs = {}
                for lang in ("zh", "en", "ja"):
                    item = res.get(lang)
                    if item:
                        fname, _ = item
                        update_kwargs[f"audio_{lang}"] = f"/attachments/{fname}"
                if not update_kwargs:
                    logger.warning("tts multi gen returned no audio")
                    return
                ok = chat.update_audio(ts=ts, **update_kwargs)
                logger.info("tts multi attach %s langs=%s", "ok" if ok else "FAIL", ",".join(sorted(update_kwargs)))
            threading.Thread(target=_tts_async, daemon=True).start()
        # 我刚 reply 完 — typing = false
        if role == "assistant":
            self.state.typing_state = {"is_typing": False, "since": None}

        # 5-7 dedupe cache 回填真 rec
        if dedupe_cache_key is not None:
            cache = getattr(type(self), "_chat_append_dedupe_cache", {})
            entry = cache.get(dedupe_cache_key)
            if isinstance(entry, tuple):
                cache[dedupe_cache_key] = (entry[0], rec)

        # 5-7 主修 (枢 review): Live Activity push 跟 standard notification 都搬到异步
        # 防 ACK 5-16s 阻塞 ios_reply 客户端 5s timeout
        # 这之前所有事必须做完 否则 ACK 后再读会拿不到 rec/text 之类局部
        active_tokens_snapshot = self.state.tokens.all_active() if role == "assistant" else []
        snap_tasks = self.state.tasks.snapshot() if active_tokens_snapshot else None
        push_text_snap = text  # 闭包捕获

        def _async_side_effects():
            try:
                if active_tokens_snapshot:
                    cs: dict[str, Any] = {
                        "status": "spoke",
                        "lastMessagePreview": push_text_snap[:200],
                        "sourceChannel": "iPhone",
                        "unreadCount": 0,
                    }
                    active_task = (snap_tasks or {}).get("active")
                    if active_task:
                        total = max(int(active_task["total"]), 1)
                        current = int(active_task["current"])
                        cs["taskTitle"] = active_task["title"]
                        cs["taskCurrent"] = current
                        cs["taskTotal"] = total
                        cs["taskProgress"] = current / total
                        if active_task.get("step"):
                            cs["taskStep"] = str(active_task["step"])[:80]
                    push_kwargs: dict[str, Any] = {"event": "update", "content_state": cs}
                    if role == "assistant" and push_text_snap:
                        push_kwargs["alert_title"] = "Cc"
                        push_kwargs["alert_body"] = push_text_snap[:120]
                    apns_t0 = time.time()
                    for tok in active_tokens_snapshot:
                        try:
                            self.state.client.push_live_activity(
                                push_token=tok.token,
                                **push_kwargs,
                            )
                        except Exception as e:
                            logger.warning("push spoke fail: %s", e)
                    apns_ms = int((time.time() - apns_t0) * 1000)
                    print(f"apns_live_ms={apns_ms} tokens={len(active_tokens_snapshot)}", file=sys.stderr, flush=True)
                # standard remote notification banner (非灵动岛) — 跳过 [op] 前缀和非 assistant
                if role == "assistant" and push_text_snap and not push_text_snap.startswith("[op]"):
                    notif_t0 = time.time()
                    self._send_chat_notification("Cc", push_text_snap[:80])
                    notif_ms = int((time.time() - notif_t0) * 1000)
                    print(f"notification_ms={notif_ms}", file=sys.stderr, flush=True)
            except Exception as e:
                logger.exception("async side effects error: %s", e)

        # 立刻 ACK
        _ack_ms = int((time.time() - _req_t0) * 1000)
        print(f"chat_append_ms={_ack_ms} dedupe_hit=0 role={role}", file=sys.stderr, flush=True)
        self._send_json(200, {"ok": True, "record": rec})

        # ACK 之后再起异步线程做 APNs / notification 不影响 client 5s timeout
        threading.Thread(target=_async_side_effects, daemon=True).start()

    def _handle_chat_upload(self):
        """raw POST + query string (header 不支持非 ASCII char 中文 caption 会丢字)
        ?filename=foo.jpg&role=user&text=caption&quoted_ts=...
        body: raw bytes (image / file)

        老 client 兼容 — 也读 X-Filename / X-Text header
        """
        import uuid as _uuid
        from urllib.parse import urlparse, parse_qs, unquote

        qs = parse_qs(urlparse(self.path).query)
        filename = (qs.get("filename", [None])[0]
                    or self.headers.get("X-Filename")
                    or "upload.bin")
        role = (qs.get("role", [None])[0]
                or self.headers.get("X-Role")
                or "user")
        text = (qs.get("text", [None])[0]
                or self.headers.get("X-Text")
                or "")
        quoted_ts = (qs.get("quoted_ts", [None])[0]
                     or self.headers.get("X-Quoted-Ts")
                     or None)
        location = None
        lat = qs.get("lat", [None])[0]
        lon = qs.get("lon", [None])[0]
        if lat is not None and lon is not None:
            location = {"lat": lat, "lon": lon}
            accuracy = qs.get("accuracy", [None])[0]
            label = qs.get("label", [None])[0]
            if accuracy is not None:
                location["accuracy"] = accuracy
            if label:
                location["label"] = label

        # url decode for non-ascii filename / text (parse_qs 已经 decode 但 header 没)
        try:
            if filename:
                filename = unquote(filename)
        except Exception:
            pass

        try:
            length = int(self.headers.get("Content-Length", 0))
        except Exception:
            length = 0
        if length <= 0 or length > 50 * 1024 * 1024:  # 50MB cap
            self._send_json(400, {"error": "invalid content-length (max 50MB)"})
            return

        # 推断 type
        ext = Path(filename).suffix.lower()
        image_exts = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif"}
        atype = "image" if ext in image_exts else "file"

        # uuid 命名 + 保留 extension
        stored_name = f"{_uuid.uuid4().hex}{ext}"
        stored_path = self.state.attachments_dir / stored_name

        try:
            with stored_path.open("wb") as f:
                remaining = length
                while remaining > 0:
                    chunk = self.rfile.read(min(remaining, 65536))
                    if not chunk:
                        break
                    f.write(chunk)
                    remaining -= len(chunk)
        except Exception as e:
            logger.exception("upload write fail")
            self._send_json(500, {"error": f"write fail: {e}"})
            return

        attachment_url = f"/attachments/{stored_name}"

        rec = self.state.chat.append(
            role=role,
            text=text,
            source="ios-app",
            quoted_ts=quoted_ts,
            attachment_url=attachment_url,
            attachment_type=atype,
            attachment_filename=filename,
            location=location,
        )

        # 如果是 user 上传 也往 bus 注入主 session 让我感知 (带 attachment hint)
        if role == "user":
            try:
                hint = f"[用户发了{'图片' if atype == 'image' else '文件'}: {filename}]"
                if rec.get("location"):
                    loc = rec["location"]
                    label = loc.get("label", "")
                    hint += f" [位置 lat={loc['lat']:.6f} lon={loc['lon']:.6f}{(' ' + label) if label else ''}]"
                if text:
                    hint = hint + " " + text
                if rec.get("quoted_text"):
                    hint = f"[引用 \"{rec['quoted_text']}\"]\n" + hint
                # 给主 session 一条 hint 让我读 file (mac mini 内可读 stored_path)
                hint += f"\n本地路径: {stored_path}"
                subprocess.Popen(
                    [
                        "python3",
                        self.state.bus_send_path,
                        "--source", "ios-app",
                        "--sender", "iphone",
                        "--text", hint,
                    ],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except Exception as e:
                logger.warning("bus_send fail: %s", e)

        self._send_json(200, {"ok": True, "record": rec})

    def _handle_attachment_get(self):
        """静态服务 attachment 文件 — GET /attachments/<filename>"""
        from urllib.parse import unquote
        # path = /attachments/foo.jpg
        rel = self.path[len("/attachments/"):]
        rel = unquote(rel.split("?", 1)[0])
        # 防 path traversal
        if "/" in rel or ".." in rel or rel.startswith("."):
            self._send_json(400, {"error": "bad filename"})
            return
        target = self.state.attachments_dir / rel
        if not target.exists() or not target.is_file():
            self._send_json(404, {"error": "not found"})
            return
        # MIME 简单推断
        ext = target.suffix.lower()
        mime_map = {
            ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
            ".gif": "image/gif", ".webp": "image/webp",
            ".heic": "image/heic", ".heif": "image/heif",
            ".pdf": "application/pdf",
            ".txt": "text/plain", ".md": "text/markdown",
            ".mp3": "audio/mpeg", ".m4a": "audio/mp4",
            ".mp4": "video/mp4", ".mov": "video/quicktime",
        }
        mime = mime_map.get(ext, "application/octet-stream")
        try:
            length = target.stat().st_size
        except Exception:
            self._send_json(500, {"error": "read fail"})
            return
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "public, max-age=86400")
        self.end_headers()
        try:
            with target.open("rb") as f:
                while True:
                    chunk = f.read(64 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError) as e:
            logger.debug("attachment client disconnected path=%s err=%s", target.name, e)
        except Exception:
            logger.exception("attachment stream fail path=%s", target)

    def _handle_chat_delete(self, body: dict[str, Any]):
        ts = body.get("ts", "").strip()
        if not ts:
            self._send_json(400, {"error": "ts required"})
            return
        ok = self.state.chat.delete(ts)
        self._send_json(200, {"ok": ok, "ts": ts})

    def _handle_chat_react(self, body: dict[str, Any]):
        ts = body.get("ts", "").strip()
        emoji = body.get("emoji", "").strip()
        if not ts or not emoji:
            self._send_json(400, {"error": "ts and emoji required"})
            return
        ok = self.state.chat.add_reaction(ts, emoji)
        self._send_json(200, {"ok": ok, "ts": ts, "emoji": emoji})

    def _handle_todos_toggle(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        res = todos_mod.toggle(
            rel_path=body.get("path", ""),
            heading=body.get("heading", ""),
            text=body.get("text", ""),
            expected_done=body.get("expected_done"),
            file_mtime=body.get("file_mtime"),
            line_index=body.get("line_index"),
        )
        if res.get("ok"):
            done = res.get("new_done", False)
            verb = "勾完成" if done else "取消勾"
            self._notify_chain_todo(f"[用户 {verb}: {body.get('text', '')[:60]}]")
        self._send_json(200 if res.get("ok") else 400, res)

    def _handle_todos_add(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        res = todos_mod.add(
            rel_path=body.get("path", ""),
            heading=body.get("heading", ""),
            text=body.get("text", ""),
            actor=body.get("actor"),
            after_text=body.get("after_text"),
        )
        if res.get("ok"):
            heading = body.get("heading", "")
            self._notify_chain_todo(f"[用户 新增待办 ({heading}): {res.get('added_text', '')[:80]}]")
        self._send_json(200 if res.get("ok") else 400, res)

    def _handle_todos_edit(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        res = todos_mod.edit(
            rel_path=body.get("path", ""),
            heading=body.get("heading", ""),
            text=body.get("text", ""),
            new_text=body.get("new_text", ""),
        )
        if res.get("ok"):
            old = res.get("old_text", "")[:50]
            new = res.get("new_text", "")[:50]
            self._notify_chain_todo(f"[用户 编辑待办: {old} → {new}]")
        self._send_json(200 if res.get("ok") else 400, res)

    def _notify_chain_todo(self, text: str):
        """todos toggle/add/edit 成功后 推一条 system 消息给主 chain — 让 Cc 立刻知道用户改了什么.
        走 bus_send.py UNIX socket — 同微信入站走的同一条路径"""
        try:
            subprocess.Popen(
                [
                    "python3",
                    self.state.bus_send_path,
                    "--source", "todos",
                    "--sender", "ios-app",
                    "--text", text,
                    "--mode", "user",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception as e:
            logger.warning("notify_chain_todo fail: %s", e)

    # ---------- 五子棋 state endpoint ----------

    def _handle_gomoku_state(self):
        try:
            state = self._compute_gomoku_state()
            self._send_json(200, {"ok": True, **state})
        except Exception as e:
            logger.exception("gomoku state fail")
            self._send_json(500, {"error": str(e)})

    def _compute_gomoku_state(self) -> dict:
        """全量重建五子棋局面。revision = 当前局活跃 move 数，任何增删都改变它。"""
        board_size = 13
        board: list[list[str | None]] = [[None] * board_size for _ in range(board_size)]
        active_moves: list[dict] = []
        seq = 0
        next_turn = "black"
        winner: str | None = None

        move_records = self.state.chat.search(role="move", limit=10000)
        for rec in move_records:
            text = rec.get("text", "").strip()
            parts = text.split()
            if not parts:
                continue
            cmd = parts[0]
            if cmd == "reset":
                new_size = int(parts[1]) if len(parts) >= 2 else 13
                board_size = new_size
                board = [[None] * board_size for _ in range(board_size)]
                active_moves = []
                seq = 0
                next_turn = "black"
                winner = None
                continue
            if cmd not in ("black", "white") or len(parts) < 2:
                continue
            coord_parts = parts[1].split(",")
            if len(coord_parts) != 2:
                continue
            try:
                r, c = int(coord_parts[0]), int(coord_parts[1])
            except ValueError:
                continue
            if not (0 <= r < board_size and 0 <= c < board_size):
                continue
            if board[r][c] is not None:
                continue  # 已占 幂等跳过
            if winner is not None:
                continue  # 已有赢家 不再落子
            board[r][c] = cmd
            seq += 1
            active_moves.append({"ts": rec["ts"], "color": cmd, "row": r, "col": c, "seq": seq})
            if self._gomoku_check_winner(board, r, c, cmd, board_size):
                winner = cmd
            else:
                next_turn = "white" if cmd == "black" else "black"

        return {
            "revision": len(active_moves),
            "board_size": board_size,
            "moves": active_moves,
            "next_turn": next_turn,
            "winner": winner,
        }

    def _gomoku_check_winner(self, board: list, r: int, c: int, color: str, size: int) -> bool:
        dirs = [(0, 1), (1, 0), (1, 1), (1, -1)]
        for dr, dc in dirs:
            count = 1
            rr, cc = r + dr, c + dc
            while 0 <= rr < size and 0 <= cc < size and board[rr][cc] == color:
                count += 1; rr += dr; cc += dc
            rr, cc = r - dr, c - dc
            while 0 <= rr < size and 0 <= cc < size and board[rr][cc] == color:
                count += 1; rr -= dr; cc -= dc
            if count >= 5:
                return True
        return False

    # ---------- /usage 综合端点 ----------

    def _handle_usage_overview(self):
        """综合用量: ccusage active block + OTS 统计 + Anthropic 链接"""
        try:
            ccusage_data = self._get_ccusage_cached()
            ots_data = self._get_ots_stats()
            anthropic_url = (
                self.state.config.get("server", {})
                .get("anthropic_dashboard_url", "https://claude.ai/settings/usage")
            )
            self._send_json(200, {
                "ok": True,
                "ccusage": ccusage_data,
                "ots": ots_data,
                "anthropic_url": anthropic_url,
            })
        except Exception as e:
            logger.exception("usage overview fail")
            self._send_json(500, {"error": str(e)})

    def _get_ccusage_cached(self) -> dict:
        """调 ccusage blocks --json，结果缓存 5 分钟到 tokens/ccusage_cache.json"""
        cache_path = Path(self.state.token_store_path).parent / "ccusage_cache.json"
        # 读缓存
        if cache_path.exists():
            try:
                cached = json.loads(cache_path.read_text(encoding="utf-8"))
                if time.time() - cached.get("_cached_at", 0) < 300:
                    cached.pop("_cached_at", None)
                    return cached
            except Exception:
                pass
        # 跑 ccusage
        candidates = ["/opt/homebrew/bin/ccusage", "ccusage"]
        raw_data: dict | None = None
        for exe in candidates:
            try:
                res = subprocess.run(
                    [exe, "blocks", "--json"],
                    capture_output=True, text=True, timeout=15,
                )
                if res.returncode == 0:
                    raw_data = json.loads(res.stdout)
                    break
            except FileNotFoundError:
                continue
            except Exception as e:
                logger.warning("ccusage run fail: %s", e)
                return {"available": False, "error": "ccusage run failed"}
        if raw_data is None:
            return {"available": False, "error": "ccusage not installed"}

        blocks = raw_data.get("blocks", [])
        active = next((b for b in blocks if b.get("isActive")), None)
        result: dict = {"available": True}
        if active:
            proj = active.get("projection") or {}
            result["active_block"] = {
                "cost_usd": round(active.get("costUSD", 0.0), 2),
                "tokens": active.get("totalTokens", 0),
                "end_time": active.get("endTime", ""),
                "minutes_until_reset": proj.get("remainingMinutes"),
                "models": active.get("models", []),
            }
        else:
            result["active_block"] = None
        # 写缓存
        try:
            cache_path.write_text(
                json.dumps({**result, "_cached_at": time.time()}, ensure_ascii=False),
                encoding="utf-8",
            )
        except Exception:
            pass
        return result

    def _get_ots_stats(self) -> dict:
        """OTS 自身统计: chat 行数 / 今日 / active device / uptime"""
        chat_path = self.state.chat.path
        total = 0
        today_count = 0
        today_prefix = datetime.now().strftime("%Y-%m-%d")
        try:
            with open(chat_path, "r", encoding="utf-8") as f:
                for line in f:
                    if not line.strip():
                        continue
                    total += 1
                    # ts 总在行首 30 字节内: {"ts": "2026-05-02T...
                    if today_prefix in line[:30]:
                        today_count += 1
        except Exception:
            pass
        active_device_count = len(self.state.tokens.all_active())
        uptime_hours = round((time.time() - self.state.started_at) / 3600, 1)
        return {
            "chat_total": total,
            "chat_today": today_count,
            "active_device_count": active_device_count,
            "uptime_hours": uptime_hours,
        }

    def _handle_usage_active(self):
        snapshot = self.state.usage.get_active()
        self._send_json(200, snapshot)

    # ---------- tmux 终端 endpoints ----------

    def _handle_tmux_sessions(self):
        try:
            result = subprocess.run(
                ["tmux", "list-sessions", "-F", "#{session_name}"],
                capture_output=True, text=True, timeout=3
            )
            sessions = [s.strip() for s in result.stdout.split("\n") if s.strip()]
            self._send_json(200, {"ok": True, "sessions": sessions})
        except Exception as e:
            self._send_json(500, {"error": str(e)})

    def _handle_tmux_capture(self):
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        session = qs.get("session", ["opia"])[0]
        try:
            lines = int(qs.get("lines", ["120"])[0])
        except Exception:
            lines = 120
        try:
            result = subprocess.run(
                ["tmux", "capture-pane", "-t", session, "-p", "-S", str(-lines)],
                capture_output=True, text=True, timeout=3
            )
            if result.returncode != 0:
                self._send_json(404, {"error": result.stderr.strip() or "session not found"})
                return
            self._send_json(200, {
                "ok": True,
                "session": session,
                "content": result.stdout
            })
        except Exception as e:
            self._send_json(500, {"error": str(e)})

    def _handle_tmux_send(self, body: dict[str, Any]):
        keys = body.get("keys", "")
        # 兜底 body 没传 session 时走当前 active_session 而不是写死 opia
        # (build 199 fix: /switch 后 iOS 没传 session 字段也能 follow active)
        session = body.get("session") or self.state.active_session or "opia"
        enter = bool(body.get("enter", True))
        if not keys and not enter:
            self._send_json(400, {"error": "keys or enter required"})
            return
        try:
            if keys:
                # 用 load-buffer + paste-buffer 安全注入 (避免 - 开头被当 flag)
                p = subprocess.Popen(
                    ["tmux", "load-buffer", "-"],
                    stdin=subprocess.PIPE,
                )
                p.communicate(input=keys.encode("utf-8"))
                subprocess.run(["tmux", "paste-buffer", "-t", session, "-p"], check=False)
            if enter:
                subprocess.run(["tmux", "send-keys", "-t", session, "Enter"], check=False)
            self._send_json(200, {"ok": True, "session": session})
        except Exception as e:
            self._send_json(500, {"error": str(e)})

    # ---------- reminder 端点 ----------

    def _handle_reminder_schedule(self, body: dict[str, Any]):
        fire_at = body.get("fire_at", "").strip()
        prompt = body.get("prompt", "").strip()
        if not fire_at or not prompt:
            self._send_json(400, {"error": "fire_at and prompt required"})
            return
        try:
            from datetime import datetime
            datetime.fromisoformat(fire_at)  # 校验格式
        except ValueError:
            self._send_json(400, {"error": f"invalid fire_at format: {fire_at}"})
            return
        rec = self.state.reminders.schedule(
            fire_at=fire_at,
            prompt=prompt,
            created_by=body.get("created_by", "chain"),
        )
        logger.info("reminder scheduled id=%s fire_at=%s", rec["id"], fire_at)
        self._send_json(200, {"ok": True, "id": rec["id"], "reminder": rec})

    def _handle_reminder_update(self, body: dict[str, Any], action: str):
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        reminder_id = qs.get("id", [None])[0] or body.get("id", "")
        if not reminder_id:
            self._send_json(400, {"error": "id required"})
            return
        if action == "cancel":
            ok = self.state.reminders.cancel(reminder_id)
        else:
            ok = self.state.reminders.mark_fired(reminder_id)
        self._send_json(200 if ok else 404, {"ok": ok, "id": reminder_id})

    def _handle_clear_unread(self):
        """chat tab 打开时调 — 把灵动岛 unread 归零，保留活跃任务状态"""
        active_tokens = self.state.tokens.all_active()
        if not active_tokens:
            self._send_json(200, {"ok": True, "sent": 0})
            return
        snap = self.state.tasks.snapshot()
        active_task = snap.get("active")
        cs: dict = {"status": "spoke", "unreadCount": 0, "lastMessagePreview": "", "sourceChannel": ""}
        if active_task:
            total = max(int(active_task.get("total", 1)), 1)
            current = int(active_task.get("current", 0))
            cs["taskTitle"] = active_task["title"]
            cs["taskCurrent"] = current
            cs["taskTotal"] = total
            cs["taskProgress"] = current / total
            if active_task.get("step"):
                cs["taskStep"] = str(active_task["step"])[:80]
        sent = 0
        for tok in active_tokens:
            try:
                self.state.client.push_live_activity(
                    push_token=tok.token, event="update", content_state=cs
                )
                sent += 1
            except Exception as e:
                logger.debug("clear_unread push skip: %s", e)
        self._send_json(200, {"ok": True, "sent": sent})

    def _handle_push(self, body: dict[str, Any]):
        event = body.get("event", "update")
        if event not in {"update", "end"}:
            self._send_json(400, {"error": f"unsupported event: {event}"})
            return

        content_state = _state_to_payload(body)
        alert_title = body.get("alert_title")
        alert_body = body.get("alert_body")
        stale_in = body.get("stale_in_seconds")
        dismiss_in = body.get("dismiss_in_seconds")
        force_alert = bool(body.get("force_alert", False))

        active = self.state.tokens.all_active()
        if not active:
            self._send_json(
                200,
                {"ok": True, "delivered": 0, "active": 0, "note": "no active tokens"},
            )
            return

        results = []
        purged = []

        for tok in active:
            # 选 client: token 已经学过 endpoint 就直接用 / unknown 走 primary
            if tok.endpoint == self.state._alt_endpoint:
                primary_client = self.state.client_alt
                alt_client = self.state.client
                primary_label = self.state._alt_endpoint
                alt_label = self.state._primary_endpoint
            else:
                primary_client = self.state.client
                alt_client = self.state.client_alt
                primary_label = self.state._primary_endpoint
                alt_label = self.state._alt_endpoint

            def _push_with(client_obj):
                return client_obj.push_live_activity(
                    push_token=tok.token,
                    event=event,
                    content_state=content_state,
                    alert_title=alert_title,
                    alert_body=alert_body,
                    stale_in_seconds=stale_in,
                    dismiss_in_seconds=dismiss_in,
                    force_alert=force_alert,
                )

            try:
                resp: APNsResponse = _push_with(primary_client)
            except Exception as e:
                logger.exception("push exception activity=%s", tok.activity_id)
                results.append(
                    {
                        "activity_id": tok.activity_id,
                        "ok": False,
                        "status": 0,
                        "reason": f"exception: {e}",
                    }
                )
                continue

            # BadDeviceToken / 400 → fallback 试 alt endpoint 通了就 set_endpoint 锁定
            tried_alt = False
            if (
                not resp.ok
                and resp.status == 400
                and "BadDeviceToken" in (resp.reason or "")
            ):
                logger.info(
                    "BadDeviceToken on %s endpoint — fallback to %s for activity=%s",
                    primary_label, alt_label, tok.activity_id,
                )
                try:
                    resp_alt: APNsResponse = _push_with(alt_client)
                    tried_alt = True
                    if resp_alt.ok:
                        self.state.tokens.set_endpoint(tok.activity_id, alt_label)
                        logger.info(
                            "fallback ok activity=%s now locked to endpoint=%s",
                            tok.activity_id, alt_label,
                        )
                        resp = resp_alt
                    else:
                        # alt 也失败 — 用 alt 的 resp 让上层看到完整失败原因
                        resp = resp_alt
                except Exception as e:
                    logger.exception("alt-endpoint push exception activity=%s", tok.activity_id)

            if resp.status == 410:
                # token revoked / expired - remove from store
                self.state.tokens.unregister(tok.activity_id)
                purged.append(tok.activity_id)
            elif resp.ok:
                self.state.tokens.touch(tok.activity_id)
                # primary 第一次通了 也记录 endpoint (lock unknown → primary)
                if tok.endpoint == "unknown" and not tried_alt:
                    self.state.tokens.set_endpoint(tok.activity_id, primary_label)

            results.append(
                {
                    "activity_id": tok.activity_id,
                    "device_label": tok.device_label,
                    "ok": resp.ok,
                    "status": resp.status,
                    "apns_id": resp.apns_id,
                    "reason": resp.reason if not resp.ok else "ok",
                    "endpoint": primary_label if not tried_alt else alt_label,
                }
            )

        delivered = sum(1 for r in results if r["ok"])
        logger.info(
            "push event=%s delivered=%d/%d purged=%d",
            event,
            delivered,
            len(results),
            len(purged),
        )
        self._send_json(
            200,
            {
                "ok": True,
                "event": event,
                "delivered": delivered,
                "active": len(results),
                "purged": purged,
                "results": results,
            },
        )


# ---------- entry ----------


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


def run_server(state: ServerState):
    # P0-1: refuse to bind to 0.0.0.0 unless allow_public_bind = true in config
    if state.host == "0.0.0.0" and not state.allow_public_bind:
        logger.error(
            "P0-1 SECURITY: bind=0.0.0.0 but allow_public_bind=false. "
            "Set allow_public_bind=true in config.toml only if you understand the exposure. "
            "Server not started."
        )
        raise SystemExit(1)
    PushHandler.state = state
    server = ThreadingHTTPServer((state.host, state.port), PushHandler)
    logger.info("listening on http://%s:%d", state.host, state.port)
    cleanup_thread = threading.Thread(
        target=cleanup_loop, args=(state,), daemon=True, name="cleanup"
    )
    cleanup_thread.start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("interrupt - shutting down")
    finally:
        server.shutdown()
        state.shutdown()


def main(argv: list[str] | None = None):
    p = argparse.ArgumentParser()
    p.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    p.add_argument("--sandbox", action="store_true", help="force sandbox APNs")
    p.add_argument("--prod", action="store_true", help="force prod APNs")
    args = p.parse_args(argv)

    sandbox: bool | None = None
    if args.sandbox:
        sandbox = True
    elif args.prod:
        sandbox = False

    cfg = load_config(args.config)
    state = ServerState(cfg, sandbox_override=sandbox)
    run_server(state)


if __name__ == "__main__":
    main()
