"""
APNs HTTP/2 客户端 专做 Live Activity push

支持
- update event (更新 ContentState)
- end event (结束 Live Activity)
- (push-to-start v0.2 才用 这版不实现)

Live Activity 特殊 headers
- apns-topic: <bundle-id>.push-type.liveactivity
- apns-push-type: liveactivity
- apns-priority: 10 (immediate)

Live Activity payload 4KB 上限 (含 attributes + content-state)
"""
from __future__ import annotations

import json
import time
import logging
from dataclasses import dataclass, field
from typing import Any

import httpx

from jwt_helper import APNsJWT


logger = logging.getLogger(__name__)


APNS_PROD = "https://api.push.apple.com"
APNS_SANDBOX = "https://api.sandbox.push.apple.com"


@dataclass
class APNsResponse:
    status: int
    apns_id: str | None
    body: str
    request_payload: dict[str, Any] = field(default_factory=dict)

    @property
    def ok(self) -> bool:
        return self.status == 200

    @property
    def reason(self) -> str:
        if self.ok:
            return "ok"
        try:
            return json.loads(self.body).get("reason", self.body)
        except Exception:
            return self.body


class APNsClient:
    def __init__(
        self,
        bundle_id: str,
        jwt_provider: APNsJWT,
        sandbox: bool = False,
        timeout: float = 10.0,
        live_activity_disabled: bool = False,
    ):
        self.bundle_id = bundle_id
        self.jwt = jwt_provider
        self.base_url = APNS_SANDBOX if sandbox else APNS_PROD
        self.topic = f"{bundle_id}.push-type.liveactivity"
        self.live_activity_disabled = live_activity_disabled

        self._client = httpx.Client(
            http2=True,
            timeout=timeout,
            headers={"User-Agent": "cc-apns-server/0.1"},
        )

    def close(self):
        self._client.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def push_live_activity(
        self,
        push_token: str,
        event: str,
        content_state: dict[str, Any],
        alert_title: str | None = None,
        alert_body: str | None = None,
        stale_in_seconds: int | None = None,
        dismiss_in_seconds: int | None = None,
        relevance_score: float | None = None,
        force_alert: bool = False,
    ) -> APNsResponse:
        """
        event: 'update' / 'end' / 'start' (start 不在本版实现)
        content_state: 跟 iOS swift 端 ActivityAttributes.ContentState 一一对应
        stale_in_seconds: 多久后 Live Activity 进入 stale (超过会被系统标记过期 不删)
        dismiss_in_seconds: end 事件下指定 N 秒后从屏幕消失 (默认 4 小时 max)
        force_alert: True 时把 alert_title / alert_body 写进 aps.alert 触发 banner + 锁屏
                     默认 False 仅 relevance-score 让灵动岛短暂 expand 不响
        """
        # 客户端没新 push Live Activity 走 stale 失活；恢复时把配置改回 false 并重启 server。
        if self.live_activity_disabled:
            return APNsResponse(status=0, apns_id=None, body="live_activity_disabled")
        if event not in {"update", "end"}:
            raise ValueError(f"unsupported event: {event}")

        now = int(time.time())
        aps: dict[str, Any] = {
            "timestamp": now,
            "event": event,
            "content-state": content_state,
        }
        # 默认 alert 静默 (relevance-score 让灵动岛胶囊短暂 expand 不弹 banner)
        # force_alert=True 时切换成 banner + 锁屏弹出 (大事用)
        if alert_title or alert_body:
            aps["relevance-score"] = 100
            if force_alert:
                aps["alert"] = {
                    "title": alert_title or "",
                    "body": alert_body or "",
                }
        if stale_in_seconds is not None:
            aps["stale-date"] = now + stale_in_seconds
        if dismiss_in_seconds is not None and event == "end":
            aps["dismissal-date"] = now + dismiss_in_seconds
        if relevance_score is not None:
            aps["relevance-score"] = relevance_score

        payload = {"aps": aps}
        body = json.dumps(payload, separators=(",", ":"))

        if len(body.encode("utf-8")) > 4096:
            raise ValueError(
                f"payload too large ({len(body)} bytes > 4096). "
                f"trim content-state / alert text"
            )

        url = f"{self.base_url}/3/device/{push_token}"
        headers = {
            "authorization": f"bearer {self.jwt.get_token()}",
            "apns-topic": self.topic,
            "apns-push-type": "liveactivity",
            "apns-priority": "10",
            "apns-expiration": "0",
            "content-type": "application/json",
        }

        try:
            resp = self._client.post(url, content=body, headers=headers)
        except httpx.HTTPError as e:
            logger.error("APNs HTTP error: %s", e)
            return APNsResponse(
                status=599,
                apns_id=None,
                body=str(e),
                request_payload=payload,
            )

        return APNsResponse(
            status=resp.status_code,
            apns_id=resp.headers.get("apns-id"),
            body=resp.text,
            request_payload=payload,
        )

    def end_live_activity(
        self,
        push_token: str,
        final_content_state: dict[str, Any] | None = None,
        dismiss_in_seconds: int = 0,
    ) -> APNsResponse:
        return self.push_live_activity(
            push_token=push_token,
            event="end",
            content_state=final_content_state or {},
            dismiss_in_seconds=dismiss_in_seconds,
        )

    def push_notification(
        self,
        push_token: str,
        payload: dict[str, Any],
    ) -> APNsResponse:
        """Send standard APNs push notification (alert / badge / sound, not Live Activity)."""
        body = json.dumps(payload, separators=(",", ":"))
        url = f"{self.base_url}/3/device/{push_token}"
        headers = {
            "authorization": f"bearer {self.jwt.get_token()}",
            "apns-topic": self.bundle_id,
            "apns-push-type": "alert",
            "apns-priority": "10",
            "apns-expiration": "0",
            "content-type": "application/json",
        }
        try:
            resp = self._client.post(url, content=body, headers=headers)
        except httpx.HTTPError as e:
            logger.error("APNs device push HTTP error: %s", e)
            return APNsResponse(status=599, apns_id=None, body=str(e), request_payload=payload)
        return APNsResponse(
            status=resp.status_code,
            apns_id=resp.headers.get("apns-id"),
            body=resp.text,
            request_payload=payload,
        )
