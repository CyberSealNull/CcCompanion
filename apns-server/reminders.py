"""
Opia reminder store — 模型给自己的定时唤醒队列

数据格式 (jsonl 每行一条):
{
  "id": "rem_uuid",
  "fire_at": "2026-05-03T10:05:00+08:00",
  "prompt": "醒来检查用户醒了没 没醒就调米家放歌开窗帘",
  "created_at": "2026-05-02T23:50:00+08:00",
  "created_by": "chain",
  "status": "pending|fired|cancelled"
}
"""
from __future__ import annotations

import json
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


class ReminderStore:
    def __init__(self, path: str | Path):
        self.path = Path(path).expanduser()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()

    def _now_iso(self) -> str:
        return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")

    def _read_all(self) -> list[dict[str, Any]]:
        if not self.path.exists():
            return []
        out = []
        with self.path.open("r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except Exception:
                    pass
        return out

    def _write_all(self, records: list[dict[str, Any]]) -> None:
        tmp = self.path.with_suffix(self.path.suffix + ".tmp")
        tmp.write_text(
            "\n".join(json.dumps(r, ensure_ascii=False) for r in records) + "\n",
            encoding="utf-8",
        )
        tmp.replace(self.path)

    def schedule(self, fire_at: str, prompt: str, created_by: str = "chain") -> dict[str, Any]:
        rec: dict[str, Any] = {
            "id": f"rem_{uuid.uuid4().hex[:12]}",
            "fire_at": fire_at,
            "prompt": prompt,
            "created_at": self._now_iso(),
            "created_by": created_by,
            "status": "pending",
        }
        with self._lock:
            with self.path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        return rec

    def list_pending(self) -> list[dict[str, Any]]:
        with self._lock:
            all_recs = self._read_all()
        return [r for r in all_recs if r.get("status") == "pending"]

    def list_due(self, now: datetime | None = None) -> list[dict[str, Any]]:
        """返回 status=pending 且 fire_at <= now 的 reminders"""
        if now is None:
            now = datetime.now(timezone.utc).astimezone()
        due = []
        for r in self.list_pending():
            try:
                fire_dt = datetime.fromisoformat(r["fire_at"])
                if fire_dt <= now:
                    due.append(r)
            except Exception:
                pass
        return due

    def _update_status(self, reminder_id: str, new_status: str) -> bool:
        with self._lock:
            recs = self._read_all()
            found = False
            for r in recs:
                if r.get("id") == reminder_id:
                    r["status"] = new_status
                    found = True
                    break
            if found:
                self._write_all(recs)
        return found

    def cancel(self, reminder_id: str) -> bool:
        return self._update_status(reminder_id, "cancelled")

    def mark_fired(self, reminder_id: str) -> bool:
        return self._update_status(reminder_id, "fired")
