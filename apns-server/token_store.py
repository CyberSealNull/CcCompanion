"""
iPhone Live Activity push token 存储

每次 iPhone app 启动 Live Activity 都会拿到一个 push token
- token 是 activity-specific 不是 device 级
- iPhone 会 POST 到 /register-token 上报
- end Live Activity 时 token 失效 iPhone POST /unregister-token
- server 把 active tokens 存到 tokens/active.json

存储是简单 JSON 文件 多线程访问加锁 进程级一致
重启服务后从文件 reload (方便 launchd 重启不丢 token)
"""
from __future__ import annotations

import json
import threading
import time
from dataclasses import dataclass, asdict
from pathlib import Path


@dataclass
class ActivityToken:
    token: str
    activity_id: str
    started_at: float
    last_seen_at: float
    device_label: str = ""
    # APNs endpoint 学习: unknown=没试过 / prod=production 通过 / sandbox=sandbox 通过
    # 学到一次后下次直接走对应 endpoint 不再 BadDeviceToken
    endpoint: str = "unknown"

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict) -> "ActivityToken":
        return cls(
            token=d["token"],
            activity_id=d["activity_id"],
            started_at=float(d["started_at"]),
            last_seen_at=float(d.get("last_seen_at", d["started_at"])),
            device_label=d.get("device_label", ""),
            endpoint=d.get("endpoint", "unknown"),
        )


class TokenStore:
    def __init__(self, path: str | Path):
        self.path = Path(path).expanduser()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._tokens: dict[str, ActivityToken] = {}
        self._load()

    def _load(self):
        if not self.path.exists():
            return
        try:
            data = json.loads(self.path.read_text())
        except Exception:
            return
        for entry in data.get("active", []):
            try:
                t = ActivityToken.from_dict(entry)
                self._tokens[t.activity_id] = t
            except Exception:
                continue

    def _persist_locked(self):
        data = {
            "saved_at": time.time(),
            "active": [t.to_dict() for t in self._tokens.values()],
        }
        tmp = self.path.with_suffix(self.path.suffix + ".tmp")
        tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False))
        tmp.replace(self.path)

    def register(
        self,
        token: str,
        activity_id: str,
        device_label: str = "",
    ) -> ActivityToken:
        now = time.time()
        with self._lock:
            existing = self._tokens.get(activity_id)
            if existing:
                existing.token = token
                existing.last_seen_at = now
                if device_label:
                    existing.device_label = device_label
                self._persist_locked()
                return existing
            new = ActivityToken(
                token=token,
                activity_id=activity_id,
                started_at=now,
                last_seen_at=now,
                device_label=device_label,
            )
            self._tokens[activity_id] = new
            self._persist_locked()
            return new

    def unregister(self, activity_id: str) -> bool:
        with self._lock:
            if activity_id in self._tokens:
                del self._tokens[activity_id]
                self._persist_locked()
                return True
            return False

    def all_active(self) -> list[ActivityToken]:
        with self._lock:
            return list(self._tokens.values())

    def touch(self, activity_id: str):
        with self._lock:
            if activity_id in self._tokens:
                self._tokens[activity_id].last_seen_at = time.time()
                self._persist_locked()

    def set_endpoint(self, activity_id: str, endpoint: str):
        """记下这个 token 在哪个 APNs endpoint (prod / sandbox) 通的 下次直接走"""
        if endpoint not in {"prod", "sandbox", "unknown"}:
            return
        with self._lock:
            if activity_id in self._tokens:
                self._tokens[activity_id].endpoint = endpoint
                self._persist_locked()

    def cleanup_stale(self, max_age_seconds: float = 3600) -> int:
        """删除超过 max_age 没 touch 的 token (默认 1 小时 — 通常 iPhone 重启 Live Activity 后旧 token 即孤儿)"""
        now = time.time()
        with self._lock:
            stale_ids = [
                aid
                for aid, t in self._tokens.items()
                if now - t.last_seen_at > max_age_seconds
            ]
            for aid in stale_ids:
                del self._tokens[aid]
            if stale_ids:
                self._persist_locked()
            return len(stale_ids)
