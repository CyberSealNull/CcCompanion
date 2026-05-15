from __future__ import annotations

from .common import *  # noqa: F403
from .common import _persist_active_session, _state_to_payload


class ChainRoutesMixin:
    def _handle_chain_abort(self, body: dict[str, Any]):
        """2026-05-07 用户 push: 紧急停止 chain. tmux send-keys C-c 到目标 session.
        session 名 allowlist 防滥用."""
        session = str(body.get("session") or "opia").strip()
        ALLOWED = {"opia", "shu", "bao", "opus", "opus47_fresh", "sonnet"}
        logger.info("chain/abort received session=%r", session)
        if session not in ALLOWED:
            logger.warning("chain/abort rejected session=%r not in allowlist", session)
            self._send_json(400, {"ok": False, "error": f"session not in allowlist: {session}"})
            return
        try:
            import subprocess
            import time as _t
            # 2026-05-07 单次 Escape 不够 cc 仍 emit 一段简短 reply 多发 3 次间隔 0.2s 真 hard quiet
            last_returncode = 0
            for i in range(3):
                res = subprocess.run(
                    ["tmux", "send-keys", "-t", session, "Escape"],
                    capture_output=True, text=True, timeout=5,
                )
                last_returncode = res.returncode
                logger.info(
                    "chain/abort tmux Escape #%d exit=%d stderr=%r",
                    i + 1, res.returncode, res.stderr,
                )
                if i < 2:
                    _t.sleep(0.2)
            res = subprocess.CompletedProcess(args=[], returncode=last_returncode, stdout='', stderr='')
            # 2026-05-10 用户 catch typing 状态没 reset abort 后客户端还显"正在输入"
            self.state.typing_state = {"is_typing": False, "since": None}
            if res.returncode == 0:
                self._send_json(200, {"ok": True, "session": session, "action": "abort"})
            else:
                self._send_json(500, {"ok": False, "error": res.stderr or "tmux send-keys failed", "exit": res.returncode})
        except Exception as e:
            logger.error("chain/abort exception: %s", e)
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_chain_clear(self, body: dict[str, Any]):
        """2026-05-07 cc 内 /clear 清 context 不重启进程."""
        session = str(body.get("session") or "opia").strip()
        ALLOWED = {"opia", "shu", "bao", "opus", "opus47_fresh", "sonnet"}
        logger.info("chain/clear received session=%r", session)
        if session not in ALLOWED:
            self._send_json(400, {"ok": False, "error": f"session not allowed: {session}"})
            return
        try:
            import subprocess
            subprocess.run(["tmux", "send-keys", "-t", session, "/clear"], timeout=5)
            subprocess.run(["tmux", "send-keys", "-t", session, "Enter"], timeout=5)
            self._send_json(200, {"ok": True, "session": session, "action": "clear"})
        except Exception as e:
            logger.error("chain/clear exception: %s", e)
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_chain_restart(self, body: dict[str, Any]):
        """2026-05-07 麻醉 退 cc + (TODO) 起新 cc resume. 当前先实现退出."""
        session = str(body.get("session") or "opia").strip()
        ALLOWED = {"opia", "shu", "bao", "opus", "opus47_fresh", "sonnet"}
        logger.info("chain/restart received session=%r", session)
        if session not in ALLOWED:
            self._send_json(400, {"ok": False, "error": f"session not allowed: {session}"})
            return
        try:
            import subprocess, time as _t
            # cc 内连按两次 Ctrl+C 退出 (cc 第一次提示"Press Ctrl+C again to exit")
            subprocess.run(["tmux", "send-keys", "-t", session, "C-c"], timeout=5)
            _t.sleep(0.3)
            subprocess.run(["tmux", "send-keys", "-t", session, "C-c"], timeout=5)
            _t.sleep(0.5)
            # 起新 cc 进程 (resume 上一个 session)
            subprocess.run(["tmux", "send-keys", "-t", session, "claude --resume", "Enter"], timeout=5)
            self._send_json(200, {"ok": True, "session": session, "action": "restart", "note": "cc 退出 + 自动 resume 上一 session"})
        except Exception as e:
            logger.error("chain/restart exception: %s", e)
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_chain_sessions_get(self):
        """Phase B /chain/sessions — list tmux sessions, mark active."""
        try:
            result = subprocess.run(
                ["tmux", "list-sessions", "-F", "#{session_name}:#{session_windows}:#{session_attached}"],
                capture_output=True, text=True, timeout=5
            )
            sessions = []
            for line in result.stdout.strip().splitlines():
                parts = line.split(":")
                sid = parts[0] if parts else "?"
                sessions.append({
                    "sid": sid,
                    "active": sid == self.state.active_session,
                })
            self._send_json(200, {"ok": True, "sessions": sessions, "active_sid": self.state.active_session})
        except Exception as e:
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_chain_new_session(self, body: dict[str, Any]):
        """Phase B /chain/new_session — create new tmux session + start CC.
        2026-05-14 — 之前默认自动 switch active_session 到新建的 sid 但用户测试一下就被踢到
        陌生的新 claude 不知道 UX 不友好. 改成"创了但不切" 用户想切过去再 /switch <sid> 显式."""
        import time as _t
        counter = _t.strftime("%H%M%S")
        new_sid = f"opia-{counter}"
        try:
            subprocess.run(["tmux", "new-session", "-d", "-s", new_sid], check=True, timeout=10)
            _t.sleep(0.5)
            subprocess.run(
                ["tmux", "send-keys", "-t", new_sid, "claude --dangerously-skip-permissions", "Enter"],
                timeout=5
            )
            # 不自动 switch active_session 用户想切过去发 /switch <sid> 自己切
            current_active = self.state.active_session
            logger.info("chain/new_session created sid=%s (active stays at %s)", new_sid, current_active)
            self._send_json(200, {
                "ok": True,
                "sid": new_sid,
                "active_sid": current_active,
                "note": f"新建 {new_sid} cc 启动中. active 还在 {current_active}. 想切过去发 /switch {new_sid}"
            })
        except Exception as e:
            logger.error("chain/new_session exception: %s", e)
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_chain_switch(self, body: dict[str, Any]):
        """Phase B /chain/switch — persist active_session for future chat sends."""
        sid = str(body.get("sid") or "opia").strip()
        if not sid:
            self._send_json(400, {"error": "sid required"})
            return
        # Verify session exists
        try:
            res = subprocess.run(
                ["tmux", "has-session", "-t", sid],
                capture_output=True, timeout=5
            )
            if res.returncode != 0:
                self._send_json(404, {"ok": False, "error": f"session '{sid}' not found"})
                return
        except Exception:
            pass
        self.state.active_session = sid
        _persist_active_session(self.state)
        logger.info("chain/switch active_session=%s", sid)
        self._send_json(200, {"ok": True, "active_sid": sid})

    def _handle_session_info(self):
        """主对话流 session id (从最新 .jsonl 找 sessionId)."""
        try:
            from pathlib import Path
            base = Path.home() / ".claude" / "projects" / "-Users-mian"
            sid = "unknown"
            mtime = 0.0
            if base.exists():
                latest = max(base.glob("*.jsonl"), key=lambda p: p.stat().st_mtime, default=None)
                if latest:
                    sid = latest.stem
                    mtime = latest.stat().st_mtime
            from datetime import datetime as _dt
            self._send_json(200, {
                "ok": True,
                "session_id": sid,
                "session_id_short": sid[:8] if sid != "unknown" else sid,
                "last_active": _dt.fromtimestamp(mtime).isoformat(timespec="seconds") if mtime else None,
            })
        except Exception as e:
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_session_usage(self):
        """今日 / 累计 token (临时 stub 后续接 ccusage)."""
        # TODO: 接真 ccusage
        self._send_json(200, {
            "ok": True,
            "today_input": 50000,
            "today_output": 8000,
            "today_total": 58000,
            "cumulative_total": 1500000,
            "stub": True,
        })

    def _handle_connections_status(self):
        """各通道 status (绿/红 + last seen)."""
        import subprocess, os
        from datetime import datetime as _dt
        def launchd_active(label: str) -> bool:
            try:
                r = subprocess.run(["launchctl", "list", label], capture_output=True, text=True, timeout=2)
                return r.returncode == 0
            except Exception:
                return False
        def tmux_alive(s: str) -> bool:
            try:
                r = subprocess.run(["tmux", "has-session", "-t", s], capture_output=True, timeout=2)
                return r.returncode == 0
            except Exception:
                return False
        def file_recent(path: str, hours: int = 24) -> bool:
            try:
                p = os.path.expanduser(path)
                if not os.path.exists(p):
                    return False
                age_h = (_dt.now().timestamp() - os.path.getmtime(p)) / 3600
                return age_h < hours
            except Exception:
                return False
        try:
            chat_path = "/path/to/CcCompanion/apns-server/tokens/chat_history.jsonl"
            group_path = "/path/to/CcCompanion/apns-server/tokens/group_chat.jsonl"
            self._send_json(200, {
                "ok": True,
                "connections": {
                    "wechat": launchd_active("com.opia.watchdog"),
                    "aisay": file_recent("~/CcCompanion/aisay-state/last_ack.json", 6),
                    "ios_chat": True,
                    "workgroup": file_recent(group_path, 24),
                    "terminal_opia": tmux_alive("opia"),
                    "heartbeat": launchd_active("com.opia.heartbeat"),
                    "chat_recent": file_recent(chat_path, 1),
                },
            })
        except Exception as e:
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_vault_stats(self):
        """vault md 文件数 + 累计字数."""
        import subprocess
        try:
            base = "/Users/mian/Documents/星原"
            count_r = subprocess.run(
                ["bash", "-c", f"find '{base}' -name '*.md' -type f 2>/dev/null | wc -l"],
                capture_output=True, text=True, timeout=10,
            )
            file_count = int(count_r.stdout.strip() or 0)
            self._send_json(200, {
                "ok": True,
                "path": base,
                "file_count": file_count,
                "total_chars": 2_915_161,  # stub: 全 md cat | wc -m 太慢
                "mode": "工作模式",
                "stub_chars": True,
            })
        except Exception as e:
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_group_stats(self):
        """工作群今日条数."""
        import json as _json
        from datetime import datetime as _dt
        try:
            today = _dt.now().strftime("%Y-%m-%d")
            count = 0
            path = "/path/to/CcCompanion/apns-server/tokens/group_chat.jsonl"
            try:
                with open(path) as f:
                    for line in f:
                        try:
                            r = _json.loads(line)
                            if r.get("ts", "").startswith(today):
                                count += 1
                        except Exception:
                            pass
            except FileNotFoundError:
                pass
            self._send_json(200, {"ok": True, "today_count": count})
        except Exception as e:
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_build_last_ship(self):
        """最新 .xcarchive mtime."""
        import os
        from datetime import datetime as _dt
        try:
            archive_dir = "/Users/mian/Library/Developer/Xcode/Archives"
            latest_mtime = 0.0
            latest_path = ""
            if os.path.exists(archive_dir):
                for root, dirs, _ in os.walk(archive_dir):
                    for d in dirs:
                        if d.endswith(".xcarchive"):
                            full = os.path.join(root, d)
                            m = os.path.getmtime(full)
                            if m > latest_mtime:
                                latest_mtime = m
                                latest_path = full
            self._send_json(200, {
                "ok": True,
                "last_ship": _dt.fromtimestamp(latest_mtime).isoformat(timespec="seconds") if latest_mtime else None,
                "archive": os.path.basename(latest_path) if latest_path else None,
            })
        except Exception as e:
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_storage_stats(self):
        """attachments 总大小 + chat history jsonl 大小."""
        import os
        try:
            att_dir = "/path/to/CcCompanion/apns-server/tokens/attachments"
            att_bytes = 0
            for root, _, files in os.walk(att_dir):
                for f in files:
                    try:
                        att_bytes += os.path.getsize(os.path.join(root, f))
                    except Exception:
                        pass
            chat_path = "/path/to/CcCompanion/apns-server/tokens/chat_history.jsonl"
            chat_bytes = os.path.getsize(chat_path) if os.path.exists(chat_path) else 0
            self._send_json(200, {
                "ok": True,
                "attachments_bytes": att_bytes,
                "chat_history_bytes": chat_bytes,
            })
        except Exception as e:
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_debug_server_log(self):
        """tail -50 server.log."""
        try:
            log_path = "/path/to/CcCompanion/apns-server/server.err.log"
            try:
                with open(log_path) as f:
                    lines = f.readlines()[-50:]
            except FileNotFoundError:
                lines = []
            self._send_json(200, {"ok": True, "lines": [l.rstrip("\n") for l in lines]})
        except Exception as e:
            self._send_json(500, {"ok": False, "error": str(e)})

