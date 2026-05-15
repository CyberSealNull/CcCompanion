from __future__ import annotations

from .common import *  # noqa: F403
from .common import _persist_active_session, _state_to_payload


class TmuxRoutesMixin:
    def _handle_tmux_sessions(self):
        try:
            result = subprocess.run(
                ["tmux", "list-sessions", "-F", "#{session_name}"],
                capture_output=True, text=True, timeout=3
            )
            sessions = [s.strip() for s in result.stdout.split("\n") if s.strip()]
            self._send_json(200, {"ok": True, "sessions": sessions})
        except Exception as e:
            self._send_json(500, {"error": str(e)})

    def _handle_tmux_capture(self):
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        session = qs.get("session", ["opia"])[0]
        try:
            lines = int(qs.get("lines", ["120"])[0])
        except Exception:
            lines = 120
        try:
            result = subprocess.run(
                ["tmux", "capture-pane", "-t", session, "-p", "-S", str(-lines)],
                capture_output=True, text=True, timeout=3
            )
            if result.returncode != 0:
                self._send_json(404, {"error": result.stderr.strip() or "session not found"})
                return
            self._send_json(200, {
                "ok": True,
                "session": session,
                "content": result.stdout
            })
        except Exception as e:
            self._send_json(500, {"error": str(e)})

    def _handle_tmux_send(self, body: dict[str, Any]):
        keys = body.get("keys", "")
        # 兜底 body 没传 session 时走当前 active_session 而不是写死 opia
        # (build 199 fix: /switch 后 iOS 没传 session 字段也能 follow active)
        session = body.get("session") or self.state.active_session or "opia"
        enter = bool(body.get("enter", True))
        if not keys and not enter:
            self._send_json(400, {"error": "keys or enter required"})
            return
        try:
            if keys:
                # 用 load-buffer + paste-buffer 安全注入 (避免 - 开头被当 flag)
                load = subprocess.run(
                    ["tmux", "load-buffer", "-"],
                    input=keys,
                    capture_output=True,
                    text=True,
                    timeout=3,
                )
                if load.returncode != 0:
                    self._send_json(500, {"error": f"tmux load-buffer failed: {load.stderr.strip()}"})
                    return
                paste = subprocess.run(
                    ["tmux", "paste-buffer", "-t", session, "-p"],
                    capture_output=True,
                    text=True,
                    timeout=3,
                    check=False,
                )
                if paste.returncode != 0:
                    self._send_json(500, {"error": f"tmux paste-buffer failed: {paste.stderr.strip()}"})
                    return
            if enter:
                send = subprocess.run(
                    ["tmux", "send-keys", "-t", session, "Enter"],
                    capture_output=True,
                    text=True,
                    timeout=3,
                    check=False,
                )
                if send.returncode != 0:
                    self._send_json(500, {"error": f"tmux send-keys failed: {send.stderr.strip()}"})
                    return
            self._send_json(200, {"ok": True, "session": session})
        except Exception as e:
            self._send_json(500, {"error": str(e)})
