"""WeChat theme v2.7 server support.

JSON-backed stores for repo-local sticker metadata, WeChat nickname, and
patpat rate limiting. This module intentionally contains no live-state data.
"""

from __future__ import annotations

import json
import threading
from datetime import datetime
from pathlib import Path
from typing import Any


def _now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


class StickerStore:
    """Sticker metadata store.

    JSON shape: {"stickers": [{"id","filename","desc","url"}]}.
    URL values are server-relative paths such as /attachments/sticker_x.png.
    """

    def __init__(self, path: str | Path):
        self.path = Path(path).expanduser()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._items: list[dict[str, Any]] = []
        self._load()

    def _load(self) -> None:
        if not self.path.exists():
            return
        try:
            obj = json.loads(self.path.read_text(encoding="utf-8"))
            if isinstance(obj, dict) and isinstance(obj.get("stickers"), list):
                self._items = [s for s in obj["stickers"] if isinstance(s, dict) and s.get("id")]
        except Exception:
            pass

    def _save(self) -> None:
        self.path.write_text(
            json.dumps({"stickers": self._items}, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    def list(self) -> list[dict[str, Any]]:
        with self._lock:
            return [dict(s) for s in self._items]

    def get(self, sticker_id: str) -> dict[str, Any] | None:
        sid = str(sticker_id or "").strip()
        if not sid:
            return None
        with self._lock:
            for s in self._items:
                if s.get("id") == sid:
                    return dict(s)
        return None

    def desc_map(self) -> dict[str, str]:
        with self._lock:
            return {s["id"]: str(s.get("desc", "")) for s in self._items if s.get("id")}

    def upsert(self, *, sticker_id: str, filename: str, desc: str, url: str) -> dict[str, Any]:
        sid = str(sticker_id or "").strip()
        if not sid:
            raise ValueError("sticker id required")
        entry = {
            "id": sid,
            "filename": str(filename or "").strip(),
            "desc": str(desc or "").strip(),
            "url": str(url or "").strip(),
            "updated_at": _now_iso(),
        }
        with self._lock:
            for i, s in enumerate(self._items):
                if s.get("id") == sid:
                    self._items[i] = entry
                    self._save()
                    return dict(entry)
            self._items.append(entry)
            self._save()
            return dict(entry)


class WechatNickStore:
    """WeChat-theme nickname store."""

    def __init__(self, path: str | Path, default: str = "Cc"):
        self.path = Path(path).expanduser()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._nick: str = default
        self._updated_at: str = _now_iso()
        self._load()

    def _load(self) -> None:
        if not self.path.exists():
            return
        try:
            obj = json.loads(self.path.read_text(encoding="utf-8"))
            if isinstance(obj, dict) and isinstance(obj.get("nick"), str) and obj["nick"].strip():
                self._nick = obj["nick"].strip()
                self._updated_at = str(obj.get("updated_at") or _now_iso())
        except Exception:
            pass

    def _save(self) -> None:
        self.path.write_text(
            json.dumps({"nick": self._nick, "updated_at": self._updated_at}, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    def get(self) -> dict[str, Any]:
        with self._lock:
            return {"nick": self._nick, "updated_at": self._updated_at}

    def set(self, nick: str) -> dict[str, Any]:
        n = str(nick or "").strip()
        if not n:
            raise ValueError("nick required")
        n = n[:40]
        with self._lock:
            self._nick = n
            self._updated_at = _now_iso()
            self._save()
            return {"nick": self._nick, "updated_at": self._updated_at}


class PatPatGate:
    """Daily rate limit and quiet-window gate for reverse patpat events."""

    def __init__(
        self,
        path: str | Path,
        *,
        daily_cap: int = 3,
        silent_windows: list[tuple[str, str]] | None = None,
    ):
        self.path = Path(path).expanduser()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self.daily_cap = int(daily_cap)
        self.silent_windows = silent_windows or [("07:20", "08:30"), ("18:00", "19:00")]
        self._date: str = ""
        self._count: int = 0
        self._last_ts: str = ""
        self._load()

    def _load(self) -> None:
        if not self.path.exists():
            return
        try:
            obj = json.loads(self.path.read_text(encoding="utf-8"))
            if isinstance(obj, dict):
                self._date = str(obj.get("date") or "")
                self._count = int(obj.get("count") or 0)
                self._last_ts = str(obj.get("last_ts") or "")
        except Exception:
            pass

    def _save(self) -> None:
        self.path.write_text(
            json.dumps({"date": self._date, "count": self._count, "last_ts": self._last_ts}, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    @staticmethod
    def _in_window(now: datetime, start: str, end: str) -> bool:
        cur = now.hour * 60 + now.minute
        sh, sm = (int(x) for x in start.split(":"))
        eh, em = (int(x) for x in end.split(":"))
        return (sh * 60 + sm) <= cur < (eh * 60 + em)

    def check(self, now: datetime | None = None) -> tuple[bool, str]:
        now = now or datetime.now()
        for start, end in self.silent_windows:
            if self._in_window(now, start, end):
                return False, f"silent_window {start}-{end}"
        today = now.strftime("%Y-%m-%d")
        with self._lock:
            count = self._count if self._date == today else 0
        if count >= self.daily_cap:
            return False, "daily_cap"
        return True, "ok"

    def consume(self, now: datetime | None = None) -> tuple[bool, str]:
        now = now or datetime.now()
        allowed, reason = self.check(now)
        if not allowed:
            return False, reason
        today = now.strftime("%Y-%m-%d")
        with self._lock:
            if self._date != today:
                self._date = today
                self._count = 0
            self._count += 1
            self._last_ts = now.astimezone().isoformat(timespec="seconds")
            self._save()
            return True, "ok"

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return {
                "date": self._date,
                "count": self._count,
                "last_ts": self._last_ts,
                "daily_cap": self.daily_cap,
            }
