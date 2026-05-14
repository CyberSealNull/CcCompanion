"""
Device-level APNs push token 存储 (standard remote notification, not Live Activity)

每台设备一行，hex token 字符串，持久化到 tokens/device_tokens.jsonl
APNs 返回 410 时调 remove() 删掉过期 token
"""
from __future__ import annotations

import json
import threading
from pathlib import Path


class DeviceTokenStore:
    def __init__(self, path: str | Path):
        self.path = Path(path).expanduser()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._tokens: set[str] = set()
        self._load()

    def _load(self):
        if not self.path.exists():
            return
        try:
            for line in self.path.read_text().splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                    tok = entry.get("token", "")
                    if tok:
                        self._tokens.add(tok)
                except Exception:
                    continue
        except Exception:
            pass

    def _persist_locked(self):
        lines = [json.dumps({"token": t}, ensure_ascii=False) for t in sorted(self._tokens)]
        text = "\n".join(lines) + ("\n" if lines else "")
        tmp = self.path.with_suffix(self.path.suffix + ".tmp")
        tmp.write_text(text)
        tmp.replace(self.path)

    def register(self, token: str) -> bool:
        """Returns True if this is a new token."""
        with self._lock:
            is_new = token not in self._tokens
            self._tokens.add(token)
            self._persist_locked()
            return is_new

    def remove(self, token: str):
        """Remove expired token (call on APNs 410)."""
        with self._lock:
            self._tokens.discard(token)
            self._persist_locked()

    def all_tokens(self) -> list[str]:
        with self._lock:
            return list(self._tokens)

    def __len__(self) -> int:
        with self._lock:
            return len(self._tokens)
