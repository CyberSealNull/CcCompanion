"""
DiaryStream — chat-style diary storage for the OTS Diary tab.

Per-day JSONL rollover under <base_dir>/YYYY-MM-DD.jsonl. Records mirror
ChatHistory's shape (ts / role / text / source) so existing iOS bubble
code can render them without translation.

Distinct from `diary.py` (which manages markdown vault entries) and from
`chat_history.py` (which is the open-ended Opia chat). This is the chain↔
用户 journaling stream: chain posts probing questions as role=assistant,
用户 answers as role=user.

Created 2026-05-11 for spec 2026-05-11_23-22_ots-diary-tab-mvp.
"""
from __future__ import annotations

import json
import logging
import threading
from datetime import datetime, timezone, date as _date
from pathlib import Path
from typing import Any, Iterable

logger = logging.getLogger("diary_stream")


def _today_str() -> str:
    return datetime.now().astimezone().strftime("%Y-%m-%d")


def _validate_date(s: str) -> str:
    # YYYY-MM-DD, reject path-traversal characters
    try:
        _date.fromisoformat(s)
    except Exception as e:
        raise ValueError(f"invalid date: {s!r}") from e
    if "/" in s or ".." in s or "\\" in s:
        raise ValueError(f"invalid date: {s!r}")
    return s


class DiaryStream:
    def __init__(self, base_dir: str | Path):
        self.base_dir = Path(base_dir).expanduser()
        self.base_dir.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._unread_path = self.base_dir / "unread.json"

    def _path_for(self, date: str) -> Path:
        return self.base_dir / f"{_validate_date(date)}.jsonl"

    # ---------- write ----------

    def append(
        self,
        role: str,
        text: str,
        source: str = "ios-app",
        metadata: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        if role not in ("user", "assistant", "system"):
            raise ValueError(f"bad role: {role!r}")
        now = datetime.now(timezone.utc).astimezone()
        ts = now.isoformat(timespec="milliseconds")
        date = now.strftime("%Y-%m-%d")
        rec: dict[str, Any] = {
            "ts": ts,
            "date": date,
            "role": role,
            "text": text,
            "source": source,
        }
        if metadata and isinstance(metadata, dict):
            rec["metadata"] = metadata
        path = self._path_for(date)
        with self._lock:
            with path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
            if role == "assistant":
                self._bump_unread_locked()
        return rec

    # ---------- read ----------

    def read_since(self, since_ts: str | None = None, limit: int = 200) -> list[dict[str, Any]]:
        """Read records newer than `since_ts`. Crosses day boundaries."""
        out: list[dict[str, Any]] = []
        for path in self._sorted_day_files():
            for rec in self._iter_file(path):
                if since_ts and rec.get("ts", "") <= since_ts:
                    continue
                out.append(rec)
                if len(out) >= limit:
                    return out
        return out

    def read_day(self, date: str) -> list[dict[str, Any]]:
        path = self._path_for(date)
        if not path.exists():
            return []
        return list(self._iter_file(path))

    def read_history(self, limit: int = 500) -> list[dict[str, Any]]:
        """Most recent `limit` records across all days (oldest→newest in result)."""
        all_records: list[dict[str, Any]] = []
        for path in self._sorted_day_files():
            all_records.extend(self._iter_file(path))
        if limit and len(all_records) > limit:
            all_records = all_records[-limit:]
        return all_records

    def latest_ts(self) -> str | None:
        for path in reversed(self._sorted_day_files()):
            last: str | None = None
            for rec in self._iter_file(path):
                t = rec.get("ts")
                if t:
                    last = t
            if last:
                return last
        return None

    # ---------- unread ----------

    def unread(self) -> int:
        try:
            data = json.loads(self._unread_path.read_text(encoding="utf-8"))
            return int(data.get("count", 0))
        except Exception:
            return 0

    def clear_unread(self) -> int:
        with self._lock:
            self._write_unread_locked(0)
        return 0

    def _bump_unread_locked(self) -> None:
        cur = 0
        try:
            cur = int(json.loads(self._unread_path.read_text(encoding="utf-8")).get("count", 0))
        except Exception:
            cur = 0
        self._write_unread_locked(cur + 1)

    def _write_unread_locked(self, n: int) -> None:
        try:
            self._unread_path.write_text(
                json.dumps({"count": int(n), "updated_at": datetime.now().astimezone().isoformat(timespec="seconds")}),
                encoding="utf-8",
            )
        except Exception:
            logger.exception("write unread failed")

    # ---------- markdown archive ----------

    def archive_day_to_markdown(self, date: str) -> str:
        """Render a day's records as Markdown for the vault.

        Returns the markdown string. Caller writes to whatever path.
        """
        recs = self.read_day(date)
        if not recs:
            return f"# {date} 日记\n\n_（今日没有记录）_\n"
        lines: list[str] = [f"# {date} 日记", "", "_chain ↔ 用户 — 自动归档自 OTS Diary tab._", ""]
        for rec in recs:
            ts = rec.get("ts", "")
            short_ts = ts.split("T", 1)[1][:5] if "T" in ts else ts
            role = rec.get("role", "")
            text = rec.get("text", "")
            label = "AI" if role == "assistant" else ("用户" if role == "user" else role)
            lines.append(f"**{short_ts} · {label}**")
            lines.append("")
            for ln in text.splitlines() or [""]:
                lines.append(f"> {ln}" if ln else ">")
            lines.append("")
        return "\n".join(lines).rstrip() + "\n"

    # ---------- helpers ----------

    def _iter_file(self, path: Path) -> Iterable[dict[str, Any]]:
        try:
            with path.open("r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        yield json.loads(line)
                    except Exception:
                        continue
        except FileNotFoundError:
            return

    def _sorted_day_files(self) -> list[Path]:
        return sorted(
            p for p in self.base_dir.glob("*.jsonl")
            if len(p.stem) == 10 and p.stem[4] == "-" and p.stem[7] == "-"
        )
