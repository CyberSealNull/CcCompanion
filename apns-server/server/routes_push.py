from __future__ import annotations

from .common import *  # noqa: F403
from .common import _persist_active_session, _state_to_payload


class PushRoutesMixin:
    def _handle_register(self, body: dict[str, Any]):
        token = body.get("token")
        activity_id = body.get("activity_id")
        device_label = body.get("device_label", "")
        if not token or not activity_id:
            self._send_json(400, {"error": "token and activity_id required"})
            return
        rec = self.state.tokens.register(
            token=token, activity_id=activity_id, device_label=device_label
        )
        logger.info("registered activity=%s device=%s", activity_id, device_label)
        self._send_json(
            200,
            {
                "ok": True,
                "activity_id": rec.activity_id,
                "started_at": rec.started_at,
                "active_count": len(self.state.tokens.all_active()),
            },
        )

    def _handle_unregister(self, body: dict[str, Any]):
        activity_id = body.get("activity_id")
        if not activity_id:
            self._send_json(400, {"error": "activity_id required"})
            return
        ok = self.state.tokens.unregister(activity_id)
        logger.info("unregistered activity=%s ok=%s", activity_id, ok)
        self._send_json(
            200,
            {
                "ok": ok,
                "active_count": len(self.state.tokens.all_active()),
            },
        )

    def _handle_register_device_token(self, body: dict[str, Any]):
        token = str(body.get("token") or "").strip()
        if not token:
            self._send_json(400, {"error": "token required"})
            return
        is_new = self.state.device_tokens.register(token)
        logger.info("device_token %s token=%s... total=%d",
                    "new" if is_new else "refresh", token[:8], len(self.state.device_tokens))
        self._send_json(200, {"ok": True, "new": is_new, "total": len(self.state.device_tokens)})

    def _send_chat_notification(self, title: str, body_text: str):
        """向所有已注册设备发 standard APNs banner 通知 (non-Live-Activity)."""
        if not self.state.apns_enabled:
            return
        device_tokens = self.state.device_tokens.all_tokens()
        if not device_tokens:
            return
        payload = {
            "aps": {
                "alert": {"title": title, "body": body_text},
                "badge": 1,
                "sound": "default",
            }
        }
        for token in device_tokens:
            try:
                resp = self.state.notification_client.push_notification(
                    push_token=token,
                    payload=payload,
                )
                if resp.status == 410 or (resp.status == 400 and "BadDeviceToken" in (resp.reason or "")):
                    logger.info("device_token invalid (status=%d), removing token=%s...", resp.status, token[:8])
                    self.state.device_tokens.remove(token)
                elif not resp.ok:
                    logger.warning("device push failed status=%d token=%s... reason=%s",
                                   resp.status, token[:8], resp.reason)
            except Exception as e:
                logger.warning("device push exception token=%s...: %s", token[:8], e)

    def _handle_reminder_schedule(self, body: dict[str, Any]):
        fire_at = body.get("fire_at", "").strip()
        prompt = body.get("prompt", "").strip()
        if not fire_at or not prompt:
            self._send_json(400, {"error": "fire_at and prompt required"})
            return
        try:
            from datetime import datetime
            datetime.fromisoformat(fire_at)  # 校验格式
        except ValueError:
            self._send_json(400, {"error": f"invalid fire_at format: {fire_at}"})
            return
        rec = self.state.reminders.schedule(
            fire_at=fire_at,
            prompt=prompt,
            created_by=body.get("created_by", "chain"),
        )
        logger.info("reminder scheduled id=%s fire_at=%s", rec["id"], fire_at)
        self._send_json(200, {"ok": True, "id": rec["id"], "reminder": rec})

    def _handle_reminder_update(self, body: dict[str, Any], action: str):
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        reminder_id = qs.get("id", [None])[0] or body.get("id", "")
        if not reminder_id:
            self._send_json(400, {"error": "id required"})
            return
        if action == "cancel":
            ok = self.state.reminders.cancel(reminder_id)
        else:
            ok = self.state.reminders.mark_fired(reminder_id)
        self._send_json(200 if ok else 404, {"ok": ok, "id": reminder_id})

    def _handle_clear_unread(self):
        """chat tab 打开时调 — 把灵动岛 unread 归零，保留活跃任务状态"""
        active_tokens = self.state.tokens.all_active()
        if not active_tokens:
            self._send_json(200, {"ok": True, "sent": 0})
            return
        snap = self.state.tasks.snapshot()
        active_task = snap.get("active")
        cs: dict = {"status": "spoke", "unreadCount": 0, "lastMessagePreview": "", "sourceChannel": ""}
        if active_task:
            total = max(int(active_task.get("total", 1)), 1)
            current = int(active_task.get("current", 0))
            cs["taskTitle"] = active_task["title"]
            cs["taskCurrent"] = current
            cs["taskTotal"] = total
            cs["taskProgress"] = current / total
            if active_task.get("step"):
                cs["taskStep"] = str(active_task["step"])[:80]
        if not self.state.apns_enabled:
            self._send_json(200, {"ok": True, "sent": 0, "skipped": True, "note": "APNs not configured"})
            return
        sent = 0
        for tok in active_tokens:
            try:
                self.state.client.push_live_activity(
                    push_token=tok.token, event="update", content_state=cs
                )
                sent += 1
            except Exception as e:
                logger.debug("clear_unread push skip: %s", e)
        self._send_json(200, {"ok": True, "sent": sent})

    def _handle_push(self, body: dict[str, Any]):
        event = body.get("event", "update")
        if event not in {"update", "end"}:
            self._send_json(400, {"error": f"unsupported event: {event}"})
            return
        if not self.state.apns_enabled:
            self._send_json(200, {"ok": True, "delivered": 0, "skipped": True, "note": "APNs not configured"})
            return

        content_state = _state_to_payload(body)
        alert_title = body.get("alert_title")
        alert_body = body.get("alert_body")
        stale_in = body.get("stale_in_seconds")
        dismiss_in = body.get("dismiss_in_seconds")
        force_alert = bool(body.get("force_alert", False))

        active = self.state.tokens.all_active()
        if not active:
            self._send_json(
                200,
                {"ok": True, "delivered": 0, "active": 0, "note": "no active tokens"},
            )
            return

        results = []
        purged = []

        for tok in active:
            # 选 client: token 已经学过 endpoint 就直接用 / unknown 走 primary
            if tok.endpoint == self.state._alt_endpoint:
                primary_client = self.state.client_alt
                alt_client = self.state.client
                primary_label = self.state._alt_endpoint
                alt_label = self.state._primary_endpoint
            else:
                primary_client = self.state.client
                alt_client = self.state.client_alt
                primary_label = self.state._primary_endpoint
                alt_label = self.state._alt_endpoint

            def _push_with(client_obj):
                return client_obj.push_live_activity(
                    push_token=tok.token,
                    event=event,
                    content_state=content_state,
                    alert_title=alert_title,
                    alert_body=alert_body,
                    stale_in_seconds=stale_in,
                    dismiss_in_seconds=dismiss_in,
                    force_alert=force_alert,
                )

            try:
                resp: APNsResponse = _push_with(primary_client)
            except Exception as e:
                logger.exception("push exception activity=%s", tok.activity_id)
                results.append(
                    {
                        "activity_id": tok.activity_id,
                        "ok": False,
                        "status": 0,
                        "reason": f"exception: {e}",
                    }
                )
                continue

            # BadDeviceToken / 400 → fallback 试 alt endpoint 通了就 set_endpoint 锁定
            tried_alt = False
            if (
                not resp.ok
                and resp.status == 400
                and "BadDeviceToken" in (resp.reason or "")
            ):
                logger.info(
                    "BadDeviceToken on %s endpoint — fallback to %s for activity=%s",
                    primary_label, alt_label, tok.activity_id,
                )
                try:
                    resp_alt: APNsResponse = _push_with(alt_client)
                    tried_alt = True
                    if resp_alt.ok:
                        self.state.tokens.set_endpoint(tok.activity_id, alt_label)
                        logger.info(
                            "fallback ok activity=%s now locked to endpoint=%s",
                            tok.activity_id, alt_label,
                        )
                        resp = resp_alt
                    else:
                        # alt 也失败 — 用 alt 的 resp 让上层看到完整失败原因
                        resp = resp_alt
                except Exception as e:
                    logger.exception("alt-endpoint push exception activity=%s", tok.activity_id)

            if resp.status == 410:
                # token revoked / expired - remove from store
                self.state.tokens.unregister(tok.activity_id)
                purged.append(tok.activity_id)
            elif resp.ok:
                self.state.tokens.touch(tok.activity_id)
                # primary 第一次通了 也记录 endpoint (lock unknown → primary)
                if tok.endpoint == "unknown" and not tried_alt:
                    self.state.tokens.set_endpoint(tok.activity_id, primary_label)

            results.append(
                {
                    "activity_id": tok.activity_id,
                    "device_label": tok.device_label,
                    "ok": resp.ok,
                    "status": resp.status,
                    "apns_id": resp.apns_id,
                    "reason": resp.reason if not resp.ok else "ok",
                    "endpoint": primary_label if not tried_alt else alt_label,
                }
            )

        delivered = sum(1 for r in results if r["ok"])
        logger.info(
            "push event=%s delivered=%d/%d purged=%d",
            event,
            delivered,
            len(results),
            len(purged),
        )
        self._send_json(
            200,
            {
                "ok": True,
                "event": event,
                "delivered": delivered,
                "active": len(results),
                "purged": purged,
                "results": results,
            },
        )
