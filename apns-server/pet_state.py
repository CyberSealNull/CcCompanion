"""Handy-Clawd pet 状态 store + SSE bus.

用户 5-8 push 桌面小宠物方案. 单只 pet 代表 Opia (Claude Opus 4.7).

12 状态 (clawd-on-desk 同款): idle / thinking / typing / building / juggling /
conducting / error / happy / notification / sweeping / carrying / sleeping.

API:
- GET /pet/state 当前状态 latest
- POST /pet/state chain hook 上报 (advisory)
- GET /pet/stream SSE 实时推 (iOS + Mac mini Electron 都连)
"""
from __future__ import annotations

import json
import logging
import threading
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


logger = logging.getLogger("opia-apns-server.pet_state")

VALID_STATES = {
    "idle", "thinking", "typing", "building", "juggling", "conducting",
    "error", "happy", "notification", "sweeping", "carrying", "sleeping",
}


class PetState:
    """Latest pet 状态 加 简单历史 (最近 100 条转换)."""

    def __init__(self, path: str | Path):
        self.path = Path(path).expanduser()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._latest: dict[str, Any] = {
            "state": "idle",
            "ts": self._now_iso(),
            "reason": "boot",
        }
        self._history: deque[dict[str, Any]] = deque(maxlen=100)
        self._load()

    def _now_iso(self) -> str:
        from datetime import timedelta
        tz = timezone(timedelta(hours=8))
        return datetime.now(tz).isoformat(timespec="milliseconds")

    def _load(self):
        if not self.path.exists():
            return
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            if isinstance(data.get("latest"), dict):
                self._latest = data["latest"]
            if isinstance(data.get("history"), list):
                self._history = deque(data["history"][-100:], maxlen=100)
        except Exception as e:
            logger.warning("pet_state load fail: %s", e)

    def _persist(self):
        try:
            self.path.write_text(
                json.dumps({"latest": self._latest, "history": list(self._history)}, ensure_ascii=False, indent=2),
                encoding="utf-8",
            )
        except Exception as e:
            logger.warning("pet_state persist fail: %s", e)

    def latest(self) -> dict[str, Any]:
        with self._lock:
            return dict(self._latest)

    def update(self, state: str, reason: str = "", ts: str | None = None) -> dict[str, Any]:
        if state not in VALID_STATES:
            state = "idle"
        if not ts:
            ts = self._now_iso()
        rec = {"state": state, "ts": ts, "reason": reason}
        with self._lock:
            old = self._latest.get("state")
            self._latest = rec
            self._history.append(rec)
            self._persist()
        # transition log (debug)
        if old != state:
            logger.info("pet_state transition %s -> %s reason=%s", old, state, reason)
        return rec

    def history(self, limit: int = 50) -> list[dict[str, Any]]:
        with self._lock:
            return list(self._history)[-limit:]


class PetStateBus:
    """SSE 广播 - clients 连 /pet/stream listen."""

    def __init__(self):
        self._subscribers: list[deque[dict[str, Any]]] = []
        self._lock = threading.Lock()

    def subscribe(self) -> deque[dict[str, Any]]:
        q: deque[dict[str, Any]] = deque(maxlen=20)
        with self._lock:
            self._subscribers.append(q)
        return q

    def unsubscribe(self, q: deque[dict[str, Any]]):
        with self._lock:
            try:
                self._subscribers.remove(q)
            except ValueError:
                pass

    def publish(self, rec: dict[str, Any]):
        with self._lock:
            subs = list(self._subscribers)
        for q in subs:
            q.append(rec)


class PetActivityBus:
    """Activity stream 广播 - chain hook 推送实时 tool call 活动到底部 terminal display.

    每个 PreToolUse / PostToolUse / Stop / UserPromptSubmit hook 推一条:
    {event_type, tool_name, summary, ts}
    iOS 端 ActivityTerminalView SSE listen, 200 行 FIFO buffer, 终端绿橙红配色.
    """

    def __init__(self):
        self._subscribers: list[deque[dict[str, Any]]] = []
        self._lock = threading.Lock()

    def subscribe(self) -> deque[dict[str, Any]]:
        q: deque[dict[str, Any]] = deque(maxlen=200)
        with self._lock:
            self._subscribers.append(q)
        return q

    def unsubscribe(self, q: deque[dict[str, Any]]):
        with self._lock:
            try:
                self._subscribers.remove(q)
            except ValueError:
                pass

    def publish(self, rec: dict[str, Any]):
        with self._lock:
            subs = list(self._subscribers)
        for q in subs:
            q.append(rec)


class PetBubbleBus:
    """Speech bubble 广播 - 复用 /pet/stream SSE event 加 type 字段区分.

    每条 ios_reply 来一个 bubble (chain hook PreToolUse 抓 tool_input.text 截 30 字).
    iOS 端 max 3 FIFO, 单条 5s 自动消失.
    """

    def __init__(self):
        self._subscribers: list[deque[dict[str, Any]]] = []
        self._lock = threading.Lock()

    def subscribe(self) -> deque[dict[str, Any]]:
        q: deque[dict[str, Any]] = deque(maxlen=20)
        with self._lock:
            self._subscribers.append(q)
        return q

    def unsubscribe(self, q: deque[dict[str, Any]]):
        with self._lock:
            try:
                self._subscribers.remove(q)
            except ValueError:
                pass

    def publish(self, rec: dict[str, Any]):
        with self._lock:
            subs = list(self._subscribers)
        for q in subs:
            q.append(rec)


# Hook event -> state mapping (chain hook 推送时用 server 端兜底 fallback)
def derive_state_from_tool(tool_name: str) -> str:
    """tool_name -> state 默认映射. chain hook clawd_state_emit.sh 调用时也用同样逻辑."""
    if not tool_name:
        return "idle"
    tn = tool_name.lower()
    if tn == "bash" or "bash" in tn:
        return "building"
    if tn in {"edit", "write", "notebookedit"}:
        return "typing"
    if "ios_reply" in tn or "wechat_reply" in tn or "ios_ask_choice" in tn:
        return "typing"
    if tn in {"read", "grep", "glob"}:
        return "carrying"
    if "dispatch_to_" in tn:
        return "conducting"
    if "exitplanmode" in tn or "ultrathink" in tn:
        return "thinking"
    return "idle"
