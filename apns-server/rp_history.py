"""
RP history store, append-only JSONL per sid.

Line schema:
{
  "ts": "2026-05-04T02:13:00.123+08:00",
  "role": "user" | "assistant",
  "text": "...",
  "source": "ios-app",
  "sid": "rp-20260504-021300-a3f9k2",
  "character_id": "..."
}
"""
from __future__ import annotations

import json
import re
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any


_SID_RE = re.compile(r"^rp-\d{8}-\d{6}-[A-Za-z0-9]{6}$")


def validate_sid(sid: str) -> str:
    sid = str(sid or "").strip()
    if not _SID_RE.match(sid):
        raise ValueError("invalid sid")
    return sid


class RPHistory:
    def __init__(self, base_dir: str | Path = "/tmp"):
        self.base_dir = Path(base_dir).expanduser()
        self.base_dir.mkdir(parents=True, exist_ok=True)
        self._locks: dict[str, threading.Lock] = {}
        self._locks_guard = threading.Lock()
        self._last_ts: dict[str, str] = {}

    def path_for(self, sid: str) -> Path:
        sid = validate_sid(sid)
        return self.base_dir / f"opia_rp_history_{sid}.jsonl"

    def _lock_for(self, sid: str) -> threading.Lock:
        with self._locks_guard:
            lock = self._locks.get(sid)
            if lock is None:
                lock = threading.Lock()
                self._locks[sid] = lock
            return lock

    def append(
        self,
        sid: str,
        role: str,
        text: str,
        character_id: str = "",
        source: str = "ios-app",
        metadata: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        sid = validate_sid(sid)
        with self._lock_for(sid):
            ts_dt = datetime.now(timezone.utc).astimezone()
            ts_text = ts_dt.isoformat(timespec="milliseconds")
            last = self._last_ts.get(sid)
            if last is not None and ts_text <= last:
                ts_dt = datetime.fromisoformat(last) + timedelta(milliseconds=1)
                ts_text = ts_dt.isoformat(timespec="milliseconds")
            self._last_ts[sid] = ts_text
        rec: dict[str, Any] = {
            "ts": ts_text,
            "role": str(role),
            "text": str(text),
            "source": str(source),
            "sid": sid,
            "character_id": str(character_id or ""),
        }
        if metadata and isinstance(metadata, dict):
            rec["metadata"] = metadata
        path = self.path_for(sid)
        with self._lock_for(sid):
            with path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        return rec

    def read_since(self, sid: str, since_ts: str | None = None, limit: int = 10000) -> list[dict[str, Any]]:
        sid = validate_sid(sid)
        path = self.path_for(sid)
        if not path.exists():
            return []
        out: list[dict[str, Any]] = []
        with self._lock_for(sid):
            with path.open("r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    ts = rec.get("ts", "")
                    if since_ts and ts <= since_ts:
                        continue
                    out.append(rec)
        return out[-max(1, min(int(limit), 10000)):]

    def tail_text(self, sid: str, max_chars: int = 160) -> str:
        records = self.read_since(sid, limit=1)
        if not records:
            return ""
        return str(records[-1].get("text", ""))[:max_chars]
