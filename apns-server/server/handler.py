from __future__ import annotations

from http.server import BaseHTTPRequestHandler
from typing import Any

from .common import *  # noqa: F403
from .common import ServerState
from .routes_chat import ChatRoutesMixin
from .routes_chain import ChainRoutesMixin
from .routes_misc import MiscRoutesMixin
from .routes_push import PushRoutesMixin
from .routes_tmux import TmuxRoutesMixin


class PushHandler(
    ChatRoutesMixin,
    ChainRoutesMixin,
    TmuxRoutesMixin,
    PushRoutesMixin,
    MiscRoutesMixin,
    BaseHTTPRequestHandler,
):
    state: ServerState  # set by run_server before serving

    server_version = "CcAPNsServer/0.1"

    def log_message(self, format: str, *args):
        logger.info("%s %s", self.address_string(), format % args)

    def _read_body(self) -> dict[str, Any]:
        length = int(self.headers.get("Content-Length", 0))
        if not length:
            return {}
        raw = self.rfile.read(length)
        return json.loads(raw)

    def _check_auth(self) -> bool:
        if self._auth_matches():
            return True
        return not self.state.strict_auth

    def _auth_matches(self) -> bool:
        if not self.state.shared_secret:
            return True
        token = self.headers.get("X-Auth-Token", "") or self.headers.get("X-Auth", "")
        return token == self.state.shared_secret

    def _require_auth(self) -> bool:
        if self._auth_matches():
            return True
        if not self.state.strict_auth:
            ip = self.client_address[0] if self.client_address else "unknown"
            logger.warning(
                "unauthenticated request allowed strict_auth=false ip=%s method=%s path=%s",
                ip,
                self.command,
                self.path,
            )
            return True
        self._send_json(401, {"error": "unauthorized"})
        return False

    def _require_write_auth(self) -> bool:
        return self._require_auth()

    def _is_public_get(self) -> bool:
        return self.path in {"/health", "/version"}

    def _check_ip_allowed(self) -> bool:
        allowed = self.state.allowed_ips
        if not allowed:
            return True
        ip_text = self.client_address[0] if self.client_address else ""
        try:
            client_ip = ipaddress.ip_address(ip_text)
        except ValueError:
            logger.warning("blocked_ip invalid ip=%s path=%s", ip_text, self.path)
            self._send_json(403, {"error": "ip not allowed"})
            return False
        for item in allowed:
            try:
                if "/" in item:
                    if client_ip in ipaddress.ip_network(item, strict=False):
                        return True
                elif client_ip == ipaddress.ip_address(item):
                    return True
            except ValueError:
                logger.warning("invalid allowed_ips entry ignored: %s", item)
        logger.warning("blocked_ip ip=%s path=%s", ip_text, self.path)
        self._send_json(403, {"error": "ip not allowed"})
        return False

    def _send_json(self, status: int, body: dict[str, Any]):
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self._is_public_get() and not self._check_ip_allowed():
            return
        if not self._is_public_get() and not self._require_auth():
            return
        if self.path == "/task/list":
            self._send_json(200, self.state.tasks.snapshot())
            return
        if self.path == "/usage/active":
            self._handle_usage_active()
            return
        if self.path == "/usage":
            self._handle_usage_overview()
            return
        if self.path.startswith("/chat/history"):
            self._handle_chat_history()
            return
        if self.path == "/pet/state":
            self._handle_pet_state_get()
            return
        if self.path == "/pet/stream":
            self._handle_pet_stream()
            return
        if self.path == "/pet/animations":
            self._handle_pet_animations()
            return
        if self.path == "/pet/activity_stream":
            self._handle_pet_activity_stream()
            return
        # 书房 v1 (2026-05-09)
        if self.path == "/studyroom/today":
            self._handle_studyroom_today()
            return
        if self.path == "/studyroom/projects":
            self._handle_studyroom_projects()
            return
        if self.path.startswith("/studyroom/project/"):
            self._handle_studyroom_project()
            return
        if self.path == "/group/roster":
            self._handle_group_roster()
            return
        if self.path == "/group/status":
            self._handle_group_status()
            return
        if self.path == "/group/tasks":
            self._handle_group_tasks()
            return
        if self.path.startswith("/group/list") or self.path.startswith("/group/history"):
            self._handle_group_history()
            return
        if self.path.startswith("/group/poll"):
            self._handle_group_poll()
            return
        if self.path.startswith("/rp/history"):
            self._handle_rp_history()
            return
        if self.path == "/rp/list":
            self._handle_rp_list()
            return
        if self.path.startswith("/chat/poll"):
            self._handle_chat_poll()
            return
        if self.path.startswith("/diary/poll"):
            self._handle_diary_poll()
            return
        if self.path.startswith("/diary/history"):
            self._handle_diary_history()
            return
        if self.path.startswith("/chat/search"):
            self._handle_chat_search()
            return
        if self.path.startswith("/diary/calendar"):
            self._handle_diary_calendar()
            return
        if self.path.startswith("/diary/get"):
            self._handle_diary_get()
            return
        if self.path.startswith("/diary/search"):
            self._handle_diary_search()
            return
        if self.path.startswith("/diary/on-this-day"):
            self._handle_diary_on_this_day()
            return
        if self.path.startswith("/diary/streak"):
            self._handle_diary_streak()
            return
        if self.path.startswith("/diary/prompts"):
            self._handle_diary_prompts()
            return
        if self.path.startswith("/timeline/events"):
            self._handle_timeline_events()
            return
        if self.path.startswith("/timeline/aggregate"):
            self._handle_timeline_aggregate()
            return
        if self.path.startswith("/timeline"):
            self._handle_timeline()
            return
        if self.path.startswith("/favorites/list"):
            self._handle_favorites_list()
            return
        if self.path.startswith("/favorites/get"):
            self._handle_favorites_get()
            return
        if self.path == "/chat/typing":
            ts = self.state.typing_state
            if ts.get("is_typing") and ts.get("since"):
                try:
                    since_dt = datetime.fromisoformat(ts["since"])
                    age = (datetime.now(timezone.utc).astimezone() - since_dt).total_seconds()
                    if age > 120:
                        self.state.typing_state = {"is_typing": False, "since": None}
                except Exception:
                    pass
            self._send_json(200, {"ok": True, **self.state.typing_state})
            return
        if self.path == "/chat/status":
            self._handle_chat_status()
            return
        if self.path == "/settings":
            self._send_json(200, {"ok": True, "settings": self.state.settings.snapshot()})
            return
        if self.path == "/todos":
            try:
                self._send_json(200, {"ok": True, "sections": todos_mod.collect_all()})
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        if self.path == "/drivers/state":
            try:
                state_path = os.path.expanduser("~/CcCompanion/opia_drivers_state.json")
                shadow_path = os.path.expanduser("~/CcCompanion/heartbeat_shadow.jsonl")
                events_path = os.path.expanduser("~/CcCompanion/heartbeat_events.jsonl")
                state_data = {}
                if os.path.exists(state_path):
                    with open(state_path, encoding="utf-8") as f:
                        state_data = json.load(f)
                recent_shadow = []
                if os.path.exists(shadow_path):
                    with open(shadow_path, encoding="utf-8") as f:
                        lines = f.readlines()[-10:]
                        for line in lines:
                            try:
                                recent_shadow.append(json.loads(line))
                            except Exception:
                                continue
                recent_events = []
                if os.path.exists(events_path):
                    with open(events_path, encoding="utf-8") as f:
                        lines = f.readlines()[-10:]
                        for line in lines:
                            try:
                                recent_events.append(json.loads(line))
                            except Exception:
                                continue
                self._send_json(200, {
                    "ok": True,
                    "state": state_data,
                    "recent_shadow": recent_shadow,
                    "recent_events": recent_events,
                })
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        if self.path.startswith("/tmux/capture"):
            # P0-2: remote control disabled by default
            if not self.state.allow_remote_control:
                self._send_json(403, {"error": "remote_control disabled", "hint": "set allow_remote_control=true in config.toml"})
                return
            self._handle_tmux_capture()
            return
        if self.path == "/tmux/sessions":
            if not self.state.allow_remote_control:
                self._send_json(403, {"error": "remote_control disabled"})
                return
            self._handle_tmux_sessions()
            return
        if self.path == "/chain/sessions":
            # Phase B slash /list: list all tmux sessions + mark active one
            if not self.state.allow_remote_control:
                self._send_json(403, {"error": "remote_control disabled"})
                return
            self._handle_chain_sessions_get()
            return
        if self.path.startswith("/attachments/"):
            self._handle_attachment_get()
            return
        # 2026-05-07 settings v2 endpoints
        if self.path == "/session/info":
            self._handle_session_info()
            return
        if self.path == "/session/usage":
            self._handle_session_usage()
            return
        if self.path == "/connections/status":
            self._handle_connections_status()
            return
        if self.path == "/vault/stats":
            self._handle_vault_stats()
            return
        if self.path == "/group/stats":
            self._handle_group_stats()
            return
        if self.path == "/build/last_ship":
            self._handle_build_last_ship()
            return
        if self.path == "/storage/stats":
            self._handle_storage_stats()
            return
        if self.path == "/debug/server_log":
            self._handle_debug_server_log()
            return
        if self.path == "/debug/turn_id":
            self._send_json(200, {"ok": True, "turn_id": "unknown"})
            return
        if self.path == "/admin/rotate-secret":
            # P0-4: rotate shared_secret; requires current secret in X-Auth-Token
            if not self._auth_matches():
                self._send_json(403, {"error": "current secret required to rotate"})
                return
            import secrets as _sec
            new_secret = _sec.token_hex(32)
            secret_file = Path.home() / ".ots" / "secret"
            try:
                secret_file.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                secret_file.write_text(new_secret)
                secret_file.chmod(0o600)
                self.state.shared_secret = new_secret
                logger.info("P0-4: shared_secret rotated")
                self._send_json(200, {"ok": True, "new_secret": new_secret, "hint": "update your iOS app onboarding"})
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        if self.path == "/health":
            self._send_json(
                200,
                {
                    "ok": True,
                    "active_tokens": len(self.state.tokens.all_active()),
                    "sandbox": self.state.sandbox,
                    "bundle_id": self.state.bundle_id,
                },
            )
            return
        if self.path == "/version":
            self._send_json(200, {"ok": True, "version": self.server_version})
            return
        if self.path == "/web/chat" or self.path.startswith("/web/chat?"):
            self._serve_web_chat()
            return
        if self.path == "/gomoku/state":
            self._handle_gomoku_state()
            return
        if self.path.startswith("/reminder/list"):
            self._send_json(200, {"ok": True, "reminders": self.state.reminders.list_pending()})
            return
        if self.path == "/tokens":
            if not self._check_auth():
                self._send_json(401, {"error": "auth required"})
                return
            tokens = [
                {
                    "activity_id": t.activity_id,
                    "device_label": t.device_label,
                    "started_at": t.started_at,
                    "last_seen_at": t.last_seen_at,
                    "token_prefix": t.token[:8] + "..." if t.token else "",
                }
                for t in self.state.tokens.all_active()
            ]
            self._send_json(200, {"tokens": tokens, "count": len(tokens)})
            return
        if self.path.startswith("/calendar/categories"):
            self._handle_calendar_categories()
            return
        if self.path.startswith("/calendar/list"):
            self._handle_calendar_list()
            return
        if self.path.startswith("/calendar/day"):
            self._handle_calendar_day()
            return
        if self.path.startswith("/calendar/month"):
            self._handle_calendar_month()
            return
        if self.path.startswith("/opia/group-msg-redesign"):
            try:
                p = HERE / "static" / "group_msg_redesign.html"
                data = p.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        if self.path.startswith("/opia/tab-mockups"):
            try:
                p = HERE / "static" / "tab_mockups.html"
                data = p.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        if self.path.startswith("/opia/widget"):
            try:
                widget_path = HERE / "static" / "cc_widget.html"
                data = widget_path.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        if not self._check_ip_allowed():
            return
        if not self._require_write_auth():
            return
        # /chat/upload 走 multipart 不解析 JSON 直接 handle raw (现在含 query string)
        if self.path.startswith("/chat/upload"):
            self._handle_chat_upload()
            return
        if self.path == "/diary/upload":
            self._handle_diary_upload()
            return

        try:
            body = self._read_body()
        except Exception as e:
            self._send_json(400, {"error": f"bad json: {e}"})
            return

        if self.path == "/register-token":
            self._handle_register(body)
        elif self.path == "/unregister-token":
            self._handle_unregister(body)
        elif self.path == "/register-device-token":
            self._handle_register_device_token(body)
            return
        elif self.path == "/reminder/schedule":
            self._handle_reminder_schedule(body)
            return
        elif self.path.startswith("/reminder/cancel"):
            self._handle_reminder_update(body, "cancel")
            return
        elif self.path.startswith("/reminder/fired"):
            self._handle_reminder_update(body, "fired")
            return
        elif self.path == "/push/clear-unread":
            self._handle_clear_unread()
            return
        elif self.path == "/push":
            if not self._check_auth():
                self._send_json(401, {"error": "auth required"})
                return
            self._handle_push(body)
        elif self.path == "/diary/post":
            self._handle_diary_post(body)
            return
        elif self.path == "/diary/clear-unread":
            self._handle_diary_clear_unread()
            return
        elif self.path == "/task/add":
            self._handle_task_action(body, "add")
        elif self.path == "/task/progress":
            self._handle_task_action(body, "progress")
        elif self.path == "/task/done":
            self._handle_task_action(body, "done")
        elif self.path == "/task/cancel":
            self._handle_task_action(body, "cancel")
        elif self.path == "/task/clear-history":
            self._handle_task_action(body, "clear_history")
        elif self.path == "/task/append-ephemeral":
            self._handle_task_append_ephemeral(body)
        elif self.path == "/chat/send":
            self._handle_chat_send(body)
        elif self.path == "/chat/regenerate":
            # P0-2: regenerate involves tmux Escape injection — remote control gate
            if not self.state.allow_remote_control:
                self._send_json(403, {"error": "remote_control disabled", "hint": "set allow_remote_control=true in config.toml"})
                return
            self._handle_chat_regenerate(body)
        elif self.path == "/pet/state":
            self._handle_pet_state_post(body)
        elif self.path == "/pet/bubble":
            self._handle_pet_bubble_post(body)
        elif self.path == "/pet/activity":
            self._handle_pet_activity_post(body)
        elif self.path == "/chat/append":
            self._handle_chat_append(body)
        elif self.path == "/chain/abort":
            # P0-2: remote control gate
            if not self.state.allow_remote_control:
                self._send_json(403, {"error": "remote_control disabled", "hint": "set allow_remote_control=true in config.toml"})
                return
            self._handle_chain_abort(body)
        elif self.path == "/chain/new_session":
            # Phase B slash /new: create new tmux session + start CC
            if not self.state.allow_remote_control:
                self._send_json(403, {"error": "remote_control disabled"})
                return
            self._handle_chain_new_session(body)
        elif self.path == "/chain/switch":
            # Phase B slash /switch: change active chain session
            if not self.state.allow_remote_control:
                self._send_json(403, {"error": "remote_control disabled"})
                return
            self._handle_chain_switch(body)
        elif self.path == "/chain/clear":
            self._handle_chain_clear(body)
        elif self.path == "/chain/restart":
            # P0-2: remote control gate
            if not self.state.allow_remote_control:
                self._send_json(403, {"error": "remote_control disabled"})
                return
            self._handle_chain_restart(body)
        elif self.path == "/group/send":
            self._handle_group_send(body)
        elif self.path == "/group/append":
            self._handle_group_append(body)
        elif self.path == "/group/dispatch-state":
            self._handle_group_dispatch_state(body)
        elif self.path == "/group/typing":
            self._handle_group_typing(body)
        elif self.path == "/group/delete":
            self._handle_group_delete(body)
        elif self.path == "/group/clear":
            self._handle_group_clear(body)
        elif self.path == "/calendar/add":
            self._handle_calendar_add(body)
        elif self.path == "/calendar/update":
            self._handle_calendar_update(body)
        elif self.path == "/calendar/delete":
            self._handle_calendar_delete(body)
        elif self.path == "/calendar/tick":
            self._handle_calendar_tick(body)
        elif self.path == "/rp/new":
            self._handle_rp_new(body)
        elif self.path == "/rp/send":
            self._handle_rp_send(body)
        elif self.path == "/rp/append":
            self._handle_rp_append(body)
        elif self.path == "/rp/archive":
            self._handle_rp_archive(body)
        elif self.path == "/chat/delete":
            self._handle_chat_delete(body)
        elif self.path == "/chat/react":
            self._handle_chat_react(body)
        elif self.path == "/diary/append":
            self._handle_diary_append(body)
        elif self.path == "/timeline/event":
            self._handle_timeline_event(body)
        elif self.path == "/diary/edit":
            self._handle_diary_edit(body)
        elif self.path == "/diary/delete-attachment":
            self._handle_diary_delete_attachment(body)
        elif self.path == "/favorites/add":
            self._handle_favorites_add(body)
        elif self.path == "/favorites/edit":
            self._handle_favorites_edit(body)
        elif self.path == "/favorites/delete":
            self._handle_favorites_delete(body)
        elif self.path == "/favorites/delete_by_turn":
            self._handle_favorites_delete_by_turn(body)
        elif self.path == "/favorites/reload":
            self._handle_favorites_reload(body)
        elif self.path == "/todos/toggle":
            self._handle_todos_toggle(body)
        elif self.path == "/todos/add":
            self._handle_todos_add(body)
        elif self.path == "/todos/edit":
            self._handle_todos_edit(body)
        elif self.path == "/tmux/send":
            # P0-2: direct tmux send-keys — remote control gate
            if not self.state.allow_remote_control:
                self._send_json(403, {"error": "remote_control disabled"})
                return
            self._handle_tmux_send(body)
        elif self.path == "/system/lock":
            try:
                import subprocess
                subprocess.run(["pmset", "displaysleepnow"], check=False, timeout=2)
                self._send_json(200, {"ok": True, "action": "lock"})
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        elif self.path == "/settings":
            for k, v in body.items():
                self.state.settings.set(k, v)
            self._send_json(200, {"ok": True, "settings": self.state.settings.snapshot()})
            return
        else:
            self._send_json(404, {"error": "not found"})

