"""Calendar event store JSON-Lines.

存 schedule events + 提供 CRUD + tick 触发推送.
跟现有 GroupChatStore / TodosStore 类似的 pattern.
"""
from __future__ import annotations

import json
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


CATEGORIES: dict[str, str] = {
    # category id → hex color
    "meeting": "#4A90E2",
    "design": "#E88C54",
    "fitness": "#5BAA60",
    "coffee": "#8B5A2B",
    "workshop": "#9B6BB5",
    "web_meeting": "#3498DB",
    "holiday": "#E74C3C",
    "personal": "#7F8C8D",
}


CATEGORY_LABELS: dict[str, str] = {
    "meeting": "会议",
    "design": "设计",
    "fitness": "健身",
    "coffee": "咖啡",
    "workshop": "工作坊",
    "web_meeting": "Web 会议",
    "holiday": "节日",
    "personal": "其他",
}


def _now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


class CalendarStore:
    def __init__(self, jsonl_path: str | Path):
        self.path = Path(jsonl_path).expanduser()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()

    def list_all(self) -> list[dict[str, Any]]:
        if not self.path.exists():
            return []
        rows: list[dict[str, Any]] = []
        with open(self.path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if rec.get("status") == "deleted":
                    continue
                rows.append(rec)
        rows.sort(key=lambda r: r.get("start_ts", ""))
        return rows

    def list_day(self, date_yyyymmdd: str) -> list[dict[str, Any]]:
        return [r for r in self.list_all() if str(r.get("start_ts", ""))[:10] == date_yyyymmdd]

    def list_month(self, year: int, month: int) -> list[dict[str, Any]]:
        prefix = f"{year:04d}-{month:02d}"
        return [r for r in self.list_all() if str(r.get("start_ts", "")).startswith(prefix)]

    def add(
        self,
        title: str,
        category: str,
        start_ts: str,
        *,
        end_ts: str | None = None,
        notes: str | None = None,
        all_day: bool = False,
        source: str = "manual",
        source_msg_id: str | None = None,
    ) -> dict[str, Any]:
        title = str(title or "").strip()
        if not title:
            raise ValueError("title required")
        if not start_ts:
            raise ValueError("start_ts required")
        if category not in CATEGORIES:
            category = "personal"
        rec: dict[str, Any] = {
            "id": f"cal_{int(time.time() * 1000)}_{uuid.uuid4().hex[:8]}",
            "title": title,
            "notes": notes or "",
            "category": category,
            "color": CATEGORIES.get(category, "#7F8C8D"),
            "start_ts": start_ts,
            "end_ts": end_ts,
            "all_day": bool(all_day),
            "status": "scheduled",
            "source": source,
            "source_msg_id": source_msg_id,
            "created_at": _now_iso(),
            "updated_at": _now_iso(),
            "fired": False,
        }
        with self._lock:
            with open(self.path, "a", encoding="utf-8") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        return rec

    def update(self, event_id: str, **patch: Any) -> dict[str, Any] | None:
        events = self._read_all_raw()
        found: dict[str, Any] | None = None
        for r in events:
            if r.get("id") == event_id and r.get("status") != "deleted":
                for k, v in patch.items():
                    if k in {"id", "created_at"}:
                        continue
                    r[k] = v
                r["updated_at"] = _now_iso()
                found = r
                break
        if found:
            self._write_all_raw(events)
        return found

    def delete(self, event_id: str) -> bool:
        events = self._read_all_raw()
        ok = False
        for r in events:
            if r.get("id") == event_id and r.get("status") != "deleted":
                r["status"] = "deleted"
                r["updated_at"] = _now_iso()
                ok = True
                break
        if ok:
            self._write_all_raw(events)
        return ok

    def mark_fired(self, event_id: str) -> bool:
        events = self._read_all_raw()
        ok = False
        for r in events:
            if r.get("id") == event_id:
                r["fired"] = True
                r["updated_at"] = _now_iso()
                ok = True
                break
        if ok:
            self._write_all_raw(events)
        return ok

    def due_within(self, lookahead_seconds: int = 70) -> list[dict[str, Any]]:
        """事件 start_ts 在 [now, now+lookahead] 且 fired=False 还没触发过的."""
        now = datetime.now(timezone.utc).astimezone()
        due: list[dict[str, Any]] = []
        for r in self.list_all():
            if r.get("fired"):
                continue
            try:
                start = datetime.fromisoformat(str(r.get("start_ts")))
            except Exception:
                continue
            delta = (start - now).total_seconds()
            if -10 <= delta <= lookahead_seconds:
                due.append(r)
        return due

    def categories(self) -> list[dict[str, Any]]:
        return [
            {"id": k, "label": CATEGORY_LABELS.get(k, k), "color": v}
            for k, v in CATEGORIES.items()
        ]

    def _read_all_raw(self) -> list[dict[str, Any]]:
        if not self.path.exists():
            return []
        rows: list[dict[str, Any]] = []
        with open(self.path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
        return rows

    def _write_all_raw(self, rows: list[dict[str, Any]]) -> None:
        with self._lock:
            tmp = self.path.with_suffix(self.path.suffix + ".tmp")
            with open(tmp, "w", encoding="utf-8") as f:
                for r in rows:
                    f.write(json.dumps(r, ensure_ascii=False) + "\n")
            tmp.replace(self.path)
