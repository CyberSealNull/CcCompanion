"""
APNs JWT (ES256) 生成

Apple Push Notification service 用 token-based authentication
- 每次 push 在 Authorization header 带 JWT bearer token
- JWT 用 .p8 私钥 ES256 签名
- 同一 JWT 最多用 1 小时 (Apple 要求 20 分钟内不能重复生成 但 1 小时内必须 refresh)

Reference: https://developer.apple.com/documentation/usernotifications/establishing_a_token-based_connection_to_apns
"""
from __future__ import annotations

import time
import threading
from pathlib import Path
import jwt


class APNsJWT:
    """JWT 生成器 自动 cache 1 小时内的 token"""

    REFRESH_INTERVAL = 50 * 60  # 50 min refresh (Apple 要求 < 60 min)
    MIN_REGEN_INTERVAL = 21 * 60  # Apple 限制 20 min 内不能重复生成 取 21 安全

    def __init__(self, p8_path: str | Path, key_id: str, team_id: str):
        self.p8_path = Path(p8_path).expanduser()
        self.key_id = key_id
        self.team_id = team_id

        self._token: str | None = None
        self._issued_at: float = 0.0
        self._lock = threading.Lock()
        self._private_key: str | None = None

    def _load_key(self) -> str:
        if self._private_key is None:
            if not self.p8_path.exists():
                raise FileNotFoundError(
                    f".p8 private key not found at {self.p8_path}. "
                    f"下载步骤 docs/01_apple_developer_p8_checklist.md"
                )
            self._private_key = self.p8_path.read_text()
        return self._private_key

    def get_token(self) -> str:
        """返回有效 JWT 自动 cache 必要时 refresh"""
        now = time.time()
        with self._lock:
            if self._token and (now - self._issued_at) < self.REFRESH_INTERVAL:
                return self._token

            if self._token and (now - self._issued_at) < self.MIN_REGEN_INTERVAL:
                # Apple 限制 20 min 内不能重复生成新 JWT
                # 此时 token 仍有效 直接返回旧的
                return self._token

            payload = {"iss": self.team_id, "iat": int(now)}
            headers = {"alg": "ES256", "kid": self.key_id}

            self._token = jwt.encode(
                payload,
                self._load_key(),
                algorithm="ES256",
                headers=headers,
            )
            self._issued_at = now
            return self._token

    def force_refresh(self) -> str:
        """强制重新生成 (调试用 慎用 会触发 Apple rate limit)"""
        with self._lock:
            self._token = None
            self._issued_at = 0.0
        return self.get_token()
