"""Worklog reader — vault `工作日志/2026年{M}月/{D}.md` (月日不补 0)."""
from __future__ import annotations

import os
from pathlib import Path

DEFAULT_VAULT = Path(os.path.expanduser("~/Documents/星原/工作日志/"))


class Worklog:
    def __init__(self, vault_path: Path | None = None):
        self.vault = vault_path or DEFAULT_VAULT

    def _path(self, date: str) -> Path:
        # date = "2026-04-30" → "2026年4月/30.md"
        y, m, d = date.split("-")
        m_int = int(m); d_int = int(d)
        return self.vault / f"{y}年{m_int}月/{d_int}.md"

    def get(self, date: str) -> dict | None:
        path = self._path(date)
        if not path.exists() or not path.is_file():
            return None
        try:
            content = path.read_text(encoding="utf-8")
        except Exception:
            return None
        # 跳过 frontmatter
        if content.startswith("---"):
            end = content.find("\n---", 3)
            if end > 0:
                content = content[end + 4 :].lstrip()
        return {
            "ts_start": f"{date}T00:00:00+08:00",
            "ts_end": f"{date}T23:59:59+08:00",
            "title": "工作日志",
            "preview": content[:500],
            "source_path": str(path),
        }
