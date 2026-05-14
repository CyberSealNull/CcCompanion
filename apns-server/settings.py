"""持久化 settings — TTS toggle 等用户偏好"""
from __future__ import annotations

import json
import threading
from pathlib import Path
from typing import Any


DEFAULT = {
    "tts_enabled": False,
    "task_push_enabled": True,
    "chat_sound_enabled": True,
    "task_sound_enabled": True,
}


class Settings:
    def __init__(self, path: str | Path):
        self.path = Path(path).expanduser()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._data: dict[str, Any] = dict(DEFAULT)
        self._load()

    def _load(self):
        if not self.path.exists():
            return
        try:
            obj = json.loads(self.path.read_text())
            if isinstance(obj, dict):
                self._data.update(obj)
        except Exception:
            pass

    def _save(self):
        self.path.write_text(json.dumps(self._data, ensure_ascii=False, indent=2))

    def get(self, key: str, default=None):
        with self._lock:
            return self._data.get(key, default)

    def set(self, key: str, value: Any):
        with self._lock:
            self._data[key] = value
            self._save()

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return dict(self._data)
