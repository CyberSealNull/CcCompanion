from __future__ import annotations

from .common import *  # noqa: F403
from .common import _persist_active_session, _state_to_payload


class ChatRoutesMixin:
    def _handle_chat_status(self):
        """chat 状态栏: typing / online / sleeping
        - typing: typing_state.is_typing
        - online: 最近 5 分钟有 assistant turn (我在干活 / 刚回过)
        - sleeping: 否则 (主 chain 没 turn 长时间)
        """
        try:
            from datetime import datetime as _dt
            typing = self.state.typing_state.get("is_typing", False)
            if typing:
                self._send_json(200, {
                    "ok": True,
                    "status": "typing",
                    "since": self.state.typing_state.get("since"),
                })
                return
            last_records = self.state.chat.tail(20)
            last_ts = None
            for r in reversed(last_records):
                if r.get("role") == "assistant":
                    last_ts = r.get("ts")
                    break
            status = "sleeping"
            if last_ts:
                try:
                    last_dt = _dt.fromisoformat(last_ts)
                    now = _dt.now(last_dt.tzinfo)
                    if (now - last_dt).total_seconds() < 300:
                        status = "online"
                except Exception:
                    pass
            self._send_json(200, {"ok": True, "status": status, "last_turn": last_ts})
        except Exception as e:
            logger.exception("chat status fail")
            self._send_json(500, {"error": str(e)})

    def _chat_status_payload(self) -> dict[str, Any]:
        from datetime import datetime as _dt

        typing = self.state.typing_state.get("is_typing", False)
        typing_since = self.state.typing_state.get("since")
        if typing and typing_since:
            try:
                since_dt = _dt.fromisoformat(typing_since)
                age = (_dt.now(timezone.utc).astimezone() - since_dt).total_seconds()
                if age > 120:
                    self.state.typing_state = {"is_typing": False, "since": None}
                    typing = False
                    typing_since = None
            except Exception:
                pass
        if typing:
            return {
                "status": "typing",
                "is_typing": True,
                "since": typing_since,
                "active_task": self.state.tasks.snapshot().get("active"),
            }

        last_records = self.state.chat.tail(20)
        last_ts = None
        for r in reversed(last_records):
            if r.get("role") == "assistant":
                last_ts = r.get("ts")
                break
        status = "sleeping"
        if last_ts:
            try:
                last_dt = _dt.fromisoformat(last_ts)
                now = _dt.now(last_dt.tzinfo)
                if (now - last_dt).total_seconds() < 300:
                    status = "online"
            except Exception:
                pass
        return {
            "status": status,
            "is_typing": False,
            "since": None,
            "last_turn": last_ts,
            "active_task": self.state.tasks.snapshot().get("active"),
        }

    def _settings_payload(self, client_etag: str | None) -> dict[str, Any]:
        snap = self.state.settings.snapshot()
        raw = json.dumps(snap, ensure_ascii=False, sort_keys=True).encode("utf-8")
        etag = hashlib.sha1(raw).hexdigest()[:12]
        if client_etag == etag:
            return {"unchanged": True, "etag": etag}
        return {"unchanged": False, "etag": etag, "values": snap}

    def _handle_chat_poll(self):
        qs = self._query()
        since = self._query_value(qs, "since")
        etag = self._query_value(qs, "etag")
        try:
            limit = int(self._query_value(qs, "limit", "50") or "50")
        except Exception:
            limit = 50
        limit = max(1, min(limit, 200))
        try:
            chat_records = self.state.chat.read_since(since_ts=since, limit=limit)
            task_records = self.state.task_buffer.list_since(since_ts=since)
            records = sorted(chat_records + task_records, key=lambda r: r.get("ts", ""))
            last_ts = records[-1].get("ts") if records else since
            now = datetime.now(timezone.utc).astimezone().isoformat(timespec="milliseconds")
            self._send_json(
                200,
                {
                    "ok": True,
                    "now": now,
                    "chat": {
                        "new_records": records,
                        "last_ts": last_ts,
                        "count": len(records),
                    },
                    "status": self._chat_status_payload(),
                    "settings": self._settings_payload(etag),
                },
            )
        except Exception as e:
            logger.exception("chat poll fail")
            self._send_json(500, {"error": str(e)})

    def _serve_web_chat(self, auth_token=None):
        html = WEB_CHAT_HTML
        if auth_token:
            inject = f"  const AUTH_TOKEN = {json.dumps(auth_token)};\n  history.replaceState({{}}, '', '/web/chat');\n"
        else:
            inject = "  const AUTH_TOKEN = '';\n"
        html = html.replace("<script>\n", "<script>\n" + inject, 1)
        html = html.replace(
            "const res = await fetch(url, { cache: 'no-store' });",
            "const res = await fetch(url, { cache: 'no-store', headers: AUTH_TOKEN ? {'X-Auth-Token': AUTH_TOKEN} : {} });",
        )
        html = html.replace(
            "headers: { 'Content-Type': 'application/json' },",
            "headers: { 'Content-Type': 'application/json', ...(AUTH_TOKEN ? {'X-Auth-Token': AUTH_TOKEN} : {}) },",
        )
        data = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _handle_chat_history(self):
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        since = qs.get("since", [None])[0]
        before = qs.get("before", qs.get("before_ts", [None]))[0]  # 向上翻页 拉 before_ts 之前的旧消息
        around_ts = qs.get("around_ts", [None])[0]  # 2026-05-07 用户 push 跳原文 围绕 ts 前后取
        try:
            limit = int(qs.get("limit", ["10000"])[0])
        except Exception:
            limit = 10000
        try:
            n_around = int(qs.get("n", ["25"])[0])
        except Exception:
            n_around = 25
        # iOS 本地 SwiftData 首次同步需要全量；UI 自己只渲染最近窗口。
        limit = min(max(limit, 1), 10000)
        n_around = min(max(n_around, 1), 200)
        if around_ts:
            chat_records = self.state.chat.read_around(ts=around_ts, n=n_around)
        else:
            chat_records = self.state.chat.read_since(since_ts=since, before_ts=before, limit=limit)
        # task records 走 /chat/poll 不混入持久 history (prevents stale task injection causing scroll-jump)
        records = chat_records
        self._send_json(200, {"ok": True, "records": records, "count": len(records)})

    def _handle_chat_search(self):
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        keyword = qs.get("q", [None])[0]
        date_prefix = qs.get("date", [None])[0]
        role = qs.get("role", [None])[0]
        try:
            limit = int(qs.get("limit", ["5000"])[0])
        except Exception:
            limit = 5000
        limit = min(max(limit, 1), 10000)
        records = self.state.chat.search(
            keyword=keyword,
            date_prefix=date_prefix,
            role=role,
            limit=limit,
        )
        self._send_json(200, {"ok": True, "records": records, "count": len(records)})

    def _handle_chat_send(self, body: dict[str, Any]):
        """iPhone 发消息进来 → 写 user 条 + 调 bus_send.py 注入主 session"""
        text = body.get("text", "").strip()
        quoted_ts = body.get("quoted_ts") or None
        location = body.get("location") or None
        if not text and not location:
            self._send_json(400, {"error": "text or location required"})
            return
        # 写 user 历史
        rec = self.state.chat.append(
            role="user",
            text=text,
            source="ios-app",
            quoted_ts=quoted_ts,
            location=location,
        )
        # 包 quote 进注入文本 (主 session 收到 channel tag 内含 quote 上下文 + 时间戳跟 wechat 一致)
        from datetime import datetime as _dt
        ts_prefix = "[" + _dt.now().strftime("%Y-%m-%d %H:%M:%S") + "]"
        # TTS 模式 hint — 让 chain 看到自动带标点
        tts_hint = ""
        if self.state.settings.get("tts_enabled"):
            tts_hint = "[语音模式 这一条带标点回复]\n"
        injected = f"{ts_prefix} {tts_hint}{text}"
        if rec.get("location"):
            loc = rec["location"]
            label = loc.get("label", "")
            loc_str = f"[位置 lat={loc['lat']:.6f} lon={loc['lon']:.6f}{(' ' + label) if label else ''}]"
            injected = f"{ts_prefix} {tts_hint}{loc_str}"
            if text:
                injected = f"{injected}\n{text}"
        if rec.get("quoted_text"):
            injected = f"{ts_prefix} {tts_hint}[引用 \"{rec['quoted_text']}\"]\n{text}"
            if rec.get("location"):
                injected = f"{ts_prefix} {tts_hint}[引用 \"{rec['quoted_text']}\"]\n{loc_str}"
                if text:
                    injected = f"{injected}\n{text}"
        # set typing — Cc 收到 message 在 thinking
        self.state.typing_state = {"is_typing": True, "since": rec["ts"]}
        # 注入文本到 active tmux session
        # 2026-05-14 build 200 — 不依赖 ~/scripts/bus_send.py (Opia 内部 file, ccc 公开版用户没有)
        # 如果 bus_send.py 存在 用它走 bus dispatcher 路由 (Opia 内部多 agent 协调用)
        # 不存在 fallback 直接 tmux paste-buffer + send-keys 注入 (ccc 公开版默认走这条)
        target_session = (self.state.active_session or self.state.default_session).strip()
        ok, err = self._inject_to_session(target_session, injected, source="ios-app", sender="iphone")
        if not ok:
            # 注入失败 (target session 不存在 / tmux 没装 / bus_send crash 等). 用 502 surface
            # 给客户端 不再 silent 200 — 否则 ccc app 显示发送成功但 chain 根本收不到.
            self._send_json(502, {
                "ok": False,
                "error": f"inject to tmux session '{target_session}' failed: {err}",
                "record": rec,
            })
            return
        self._send_json(200, {"ok": True, "record": rec})

    def _inject_to_session(self, session: str, text: str, source: str = "ios-app", sender: str = "iphone"):
        """Inject text into target tmux session. Returns (success, error_msg).

        Prefer bus_send.py (Opia internal bus dispatcher routing for multi-agent coord)
        if both the script exists AND /tmp/opia_bus.sock is reachable (dispatcher running).
        Otherwise fall back to direct tmux load-buffer + paste-buffer + send-keys,
        which is what ccc public users get by default — no Opia internal daemon required.
        """
        import os
        import socket
        bus_path = self.state.bus_send_path
        bus_sock = "/tmp/opia_bus.sock"
        bus_ready = False
        if bus_path and os.path.exists(bus_path) and os.path.exists(bus_sock):
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                    s.settimeout(0.2)
                    s.connect(bus_sock)
                bus_ready = True
            except Exception:
                bus_ready = False
        if bus_ready:
            try:
                spawn_logged(
                    [
                        "python3",
                        bus_path,
                        "--source", source,
                        "--sender", sender,
                        "--text", text,
                        "--target", session,
                    ],
                    context="chat bus_send",
                    timeout=10.0,
                )
                return True, ""
            except Exception as e:
                logger.warning("bus_send fail, falling back to tmux: %s", e)
        # Fallback: direct tmux paste-buffer + send-keys (ccc public default).
        # 先 verify target session 存在 — 不然 paste-buffer/send-keys 会 silently 失败.
        try:
            has = subprocess.run(
                ["tmux", "has-session", "-t", session],
                capture_output=True, text=True, timeout=2,
            )
            if has.returncode != 0:
                err = f"tmux session not found (run `tmux new-session -d -s {session} 'claude --dangerously-skip-permissions'`)"
                logger.warning("tmux inject: %s", err)
                return False, err
        except FileNotFoundError:
            return False, "tmux not installed (brew install tmux)"
        except Exception as e:
            return False, f"tmux has-session check failed: {e}"
        try:
            load = subprocess.run(
                ["tmux", "load-buffer", "-"],
                input=text,
                capture_output=True,
                text=True,
                timeout=3,
            )
            if load.returncode != 0:
                return False, f"tmux load-buffer failed: {load.stderr.strip()}"
            paste = subprocess.run(
                ["tmux", "paste-buffer", "-t", session, "-p"],
                capture_output=True, text=True, timeout=3,
            )
            if paste.returncode != 0:
                return False, f"tmux paste-buffer failed: {paste.stderr.strip()}"
            send = subprocess.run(
                ["tmux", "send-keys", "-t", session, "Enter"],
                capture_output=True, text=True, timeout=3,
            )
            if send.returncode != 0:
                return False, f"tmux send-keys failed: {send.stderr.strip()}"
            return True, ""
        except Exception as e:
            err = f"tmux inject failed: {e}"
            logger.warning("%s (session=%s)", err, session)
            return False, err

    def _handle_chat_regenerate(self, body: dict[str, Any]):
        """2026-05-08 用户 push 重新发言. iOS 长按 assistant msg 选 regenerate.
        flow:
        1 mark old assistant msg hidden_in_ui (UI 不展示但 jsonl 留备查)
        2 中断 chain (tmux Escape x 3 复用 chain_abort 逻辑)
        3 user_text 包 [regenerate] 标记调 bus_send 注入主 session
        4 chain 跑出新回复 走现有 stop hook 写 chat_history
        body: {"replace_msg_id": "ts", "user_text": "...", "client_msg_id": "uuid for dedupe"}
        """
        replace_msg_id = str(body.get("replace_msg_id") or "").strip()
        extra_replace_ids = [str(x).strip() for x in (body.get("extra_replace_ids") or []) if x]
        user_text = str(body.get("user_text") or "").strip()
        client_msg_id = body.get("client_msg_id")
        if not replace_msg_id or not user_text:
            self._send_json(400, {"error": "replace_msg_id and user_text required"})
            return

        # dedupe 5s 窗口防快速点击
        cache = getattr(type(self), "_regen_dedupe_cache", None)
        if cache is None:
            cache = {}
            type(self)._regen_dedupe_cache = cache
        now_ts = time.time()
        cache_key = f"cmid:{client_msg_id}" if client_msg_id else f"replace:{replace_msg_id}"
        last_ts = cache.get(cache_key, 0)
        if now_ts - last_ts < 5.0:
            self._send_json(429, {"ok": False, "error": "duplicate within 5s window", "deduped": True})
            return
        cache[cache_key] = now_ts
        for k in list(cache.keys()):
            if now_ts - cache[k] > 60:
                del cache[k]

        # mark old assistant msg hidden (first/primary)
        marked = self.state.chat.mark_regenerated(old_ts=replace_msg_id)
        logger.info("chat/regenerate marked=%s replace_msg_id=%s", marked, replace_msg_id)
        # mark extra turn bubbles hidden
        extra_marked = 0
        for eid in extra_replace_ids:
            if self.state.chat.mark_regenerated(old_ts=eid):
                extra_marked += 1
        if extra_replace_ids:
            logger.info("chat/regenerate extra_marked=%d ids=%s", extra_marked, extra_replace_ids)

        # 中断 chain (tmux Escape x 3 复用 chain_abort 逻辑)
        regen_session = self.state.active_session or self.state.default_session
        try:
            import subprocess
            import time as _t
            for i in range(3):
                subprocess.run(
                    ["tmux", "send-keys", "-t", regen_session, "Escape"],
                    capture_output=True, text=True, timeout=5,
                )
                if i < 2:
                    _t.sleep(0.2)
            logger.info("chat/regenerate sent 3x Escape to %s tmux", regen_session)
        except Exception as e:
            logger.warning("chat/regenerate tmux abort fail: %s", e)

        # 给一点时间让 chain 真停 然后注入新 user_text
        try:
            import time as _t2
            _t2.sleep(0.5)
        except Exception:
            pass

        # 包 ts_prefix + [regenerate] 标记 chain 看到知道这是重生成请求
        from datetime import datetime as _dt
        ts_prefix = "[" + _dt.now().strftime("%Y-%m-%d %H:%M:%S") + "]"
        tts_hint = ""
        if self.state.settings.get("tts_enabled"):
            tts_hint = "[语音模式 这一条带标点回复]\n"
        injected = f"{ts_prefix} {tts_hint}[regenerate 用户对上一条回复不满意 重新生成] {user_text}"

        # set typing
        self.state.typing_state = {"is_typing": True, "since": _dt.now().isoformat(timespec="milliseconds")}

        # 注入 regenerate 文本到 active session — 走 _inject_to_session helper
        # ccc 公开用户没 ~/scripts/bus_send.py 时 fallback 直接 tmux 注入
        target_session = (self.state.active_session or self.state.default_session).strip()
        ok, err = self._inject_to_session(target_session, injected, source="ios-app", sender="iphone")
        if not ok:
            self._send_json(502, {
                "ok": False,
                "error": f"inject regenerate to '{target_session}' failed: {err}",
                "marked_hidden": marked,
                "replace_msg_id": replace_msg_id,
                "extra_marked": extra_marked,
            })
            return

        self._send_json(200, {
            "ok": True,
            "marked_hidden": marked,
            "replace_msg_id": replace_msg_id,
            "extra_marked": extra_marked,
            "interrupted": True,
        })

    def _handle_chat_append(self, body: dict[str, Any]):
        """bus_stop_hook 抓到回复后调 → 写 assistant 条 + push spoke 状态
        也支持从 mac mini 这边发图/文件 给 iPhone:
          attachment_path (本地文件 server 复制进 attachments/) 或
          attachment_url (server 已存的 /attachments/<file>)
        """
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        text = body.get("text", "").strip()
        role = body.get("role", "assistant")
        if role == "task":
            if not text:
                self._send_json(400, {"error": "text required"})
                return
            rec = self.state.task_buffer.append(text=text, source=body.get("source", "system"))
            self._send_json(200, {"ok": True, "record": rec})
            return

        # attachment 处理
        attachment_url = body.get("attachment_url") or None
        attachment_type = body.get("attachment_type") or None
        attachment_filename = body.get("attachment_filename") or None
        local_path = body.get("attachment_path") or None
        if local_path:
            import uuid as _uuid, shutil
            src = Path(local_path).expanduser()
            if not src.exists() or not src.is_file():
                self._send_json(400, {"error": f"attachment_path not found: {src}"})
                return
            ext = src.suffix.lower()
            stored_name = f"{_uuid.uuid4().hex}{ext}"
            target = self.state.attachments_dir / stored_name
            shutil.copy2(src, target)
            attachment_url = f"/attachments/{stored_name}"
            if not attachment_type:
                image_exts = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif"}
                attachment_type = "image" if ext in image_exts else "file"
            if not attachment_filename:
                attachment_filename = src.name

        if not text and not attachment_url:
            self._send_json(400, {"error": "text or attachment required"})
            return

        # 通用 chat/append dedupe (非 move) 防 ios_reply 等客户端 retry 重复入库
        # 2026-05-07 修 用户 catch "为什么发两遍". role=move 走下面坐标幂等不动.
        # 5-7 升级 5s→60s + cmid fallback 加 attachment + 命中返回原 rec (枢 review 推荐)
        _req_t0 = time.time()
        client_msg_id = body.get("client_msg_id") or None
        dedupe_cache_key = None
        if role != "move":
            cache = getattr(type(self), "_chat_append_dedupe_cache", None)
            if cache is None:
                cache = {}
                type(self)._chat_append_dedupe_cache = cache
            now_ts = time.time()
            if client_msg_id:
                cache_key = f"cmid:{client_msg_id}"
            else:
                cache_key = f"{role}|{text[:200]}|{body.get('source', '')}|{attachment_url or ''}|{attachment_filename or ''}"
            entry = cache.get(cache_key)
            last_ts = entry[0] if isinstance(entry, tuple) else (entry or 0)
            if now_ts - last_ts < 60.0:
                cached_rec = entry[1] if isinstance(entry, tuple) else None
                _ms = int((time.time() - _req_t0) * 1000)
                print(f"chat_append_ms={_ms} dedupe_hit=1 role={role}", file=sys.stderr, flush=True)
                self._send_json(200, {"ok": True, "duplicate": True, "deduped": True, "record": cached_rec})
                return
            # 占位 真 rec 入库后回填
            cache[cache_key] = (now_ts, None)
            dedupe_cache_key = cache_key
            for k in list(cache.keys()):
                v = cache[k]
                v_ts = v[0] if isinstance(v, tuple) else v
                if now_ts - v_ts > 120:
                    del cache[k]

        if role == "move":
            # 层 1: client_msg_id 缓存
            if client_msg_id:
                cached = self.state.gomoku_msg_cache.get(client_msg_id)
                if cached is not None:
                    self._send_json(200, {"ok": True, "duplicate": True, "record": cached})
                    return
            # 层 2: 坐标幂等 — 检查当前局面该格是否已有子
            text_parts = text.split()
            if len(text_parts) >= 2 and text_parts[0] in ("black", "white"):
                coord_parts = text_parts[1].split(",")
                if len(coord_parts) == 2:
                    try:
                        move_r, move_c = int(coord_parts[0]), int(coord_parts[1])
                        state_snap = self._compute_gomoku_state()
                        dup = next(
                            (m for m in state_snap["moves"]
                             if m["row"] == move_r and m["col"] == move_c),
                            None,
                        )
                        if dup is not None:
                            existing_text = f"{dup['color']} {dup['row']},{dup['col']}"
                            existing_rec = {"ts": dup["ts"], "role": "move", "text": existing_text}
                            logger.info("gomoku dedup coord %d,%d", move_r, move_c)
                            self._send_json(200, {"ok": True, "duplicate": True, "record": existing_rec})
                            return
                    except Exception:
                        pass

        metadata = body.get("metadata") or None
        if metadata and not isinstance(metadata, dict):
            metadata = None

        rec = self.state.chat.append(
            role=role,
            text=text,
            source="ios-app",
            attachment_url=attachment_url,
            attachment_type=attachment_type,
            attachment_filename=attachment_filename,
            metadata=metadata,
        )

        # move 成功 append 后缓存 client_msg_id (LRU 100)
        if role == "move" and client_msg_id:
            cache = self.state.gomoku_msg_cache
            cache[client_msg_id] = rec
            while len(cache) > 100:
                cache.popitem(last=False)

        # role=move (五子棋落子): notify chain 让 Cc 自动收到对方 (black 用户) 落子 → 决策回手
        # 只 trigger 当 text 以 "black" 开头 (white 是我自己 chain 落 不 notify)
        if role == "move" and text.startswith("black"):
            self._notify_chain_todo(f"[用户 落子: {text}]")

        # assistant text reply 后台异步生成 TTS mp3 — 不阻塞 hook (仅 settings.tts_enabled)
        if role == "assistant" and text and not attachment_url and self.state.settings.get("tts_enabled"):
            ts = rec["ts"]
            chat = self.state.chat
            attachments_dir = self.state.attachments_dir
            def _tts_async():
                logger.info("tts multi thread start ts=%s len=%d", ts, len(text))
                try:
                    res = TTS.generate_multi(text, attachments_dir)
                except Exception as e:
                    logger.exception("tts multi gen fail")
                    return
                update_kwargs = {}
                for lang in ("zh", "en", "ja"):
                    item = res.get(lang)
                    if item:
                        fname, _ = item
                        update_kwargs[f"audio_{lang}"] = f"/attachments/{fname}"
                if not update_kwargs:
                    logger.warning("tts multi gen returned no audio")
                    return
                ok = chat.update_audio(ts=ts, **update_kwargs)
                logger.info("tts multi attach %s langs=%s", "ok" if ok else "FAIL", ",".join(sorted(update_kwargs)))
            threading.Thread(target=_tts_async, daemon=True).start()
        # 我刚 reply 完 — typing = false
        if role == "assistant":
            self.state.typing_state = {"is_typing": False, "since": None}

        # 5-7 dedupe cache 回填真 rec
        if dedupe_cache_key is not None:
            cache = getattr(type(self), "_chat_append_dedupe_cache", {})
            entry = cache.get(dedupe_cache_key)
            if isinstance(entry, tuple):
                cache[dedupe_cache_key] = (entry[0], rec)

        # 5-7 主修 (枢 review): Live Activity push 跟 standard notification 都搬到异步
        # 防 ACK 5-16s 阻塞 ios_reply 客户端 5s timeout
        # 这之前所有事必须做完 否则 ACK 后再读会拿不到 rec/text 之类局部
        active_tokens_snapshot = self.state.tokens.all_active() if role == "assistant" else []
        snap_tasks = self.state.tasks.snapshot() if active_tokens_snapshot else None
        push_text_snap = text  # 闭包捕获

        def _async_side_effects():
            try:
                if active_tokens_snapshot and self.state.apns_enabled:
                    cs: dict[str, Any] = {
                        "status": "spoke",
                        "lastMessagePreview": push_text_snap[:200],
                        "sourceChannel": "iPhone",
                        "unreadCount": 0,
                    }
                    active_task = (snap_tasks or {}).get("active")
                    if active_task:
                        total = max(int(active_task["total"]), 1)
                        current = int(active_task["current"])
                        cs["taskTitle"] = active_task["title"]
                        cs["taskCurrent"] = current
                        cs["taskTotal"] = total
                        cs["taskProgress"] = current / total
                        if active_task.get("step"):
                            cs["taskStep"] = str(active_task["step"])[:80]
                    push_kwargs: dict[str, Any] = {"event": "update", "content_state": cs}
                    if role == "assistant" and push_text_snap:
                        push_kwargs["alert_title"] = "Cc"
                        push_kwargs["alert_body"] = push_text_snap[:120]
                    apns_t0 = time.time()
                    for tok in active_tokens_snapshot:
                        try:
                            self.state.client.push_live_activity(
                                push_token=tok.token,
                                **push_kwargs,
                            )
                        except Exception as e:
                            logger.warning("push spoke fail: %s", e)
                    apns_ms = int((time.time() - apns_t0) * 1000)
                    print(f"apns_live_ms={apns_ms} tokens={len(active_tokens_snapshot)}", file=sys.stderr, flush=True)
                # standard remote notification banner (非灵动岛) — 跳过 [op] 前缀和非 assistant
                if role == "assistant" and push_text_snap and not push_text_snap.startswith("[op]"):
                    notif_t0 = time.time()
                    self._send_chat_notification("Cc", push_text_snap[:80])
                    notif_ms = int((time.time() - notif_t0) * 1000)
                    print(f"notification_ms={notif_ms}", file=sys.stderr, flush=True)
            except Exception as e:
                logger.exception("async side effects error: %s", e)

        # 立刻 ACK
        _ack_ms = int((time.time() - _req_t0) * 1000)
        print(f"chat_append_ms={_ack_ms} dedupe_hit=0 role={role}", file=sys.stderr, flush=True)
        self._send_json(200, {"ok": True, "record": rec})

        # ACK 之后再起异步线程做 APNs / notification 不影响 client 5s timeout
        threading.Thread(target=_async_side_effects, daemon=True).start()

    def _handle_chat_upload(self):
        """raw POST + query string (header 不支持非 ASCII char 中文 caption 会丢字)
        ?filename=foo.jpg&role=user&text=caption&quoted_ts=...
        body: raw bytes (image / file)

        老 client 兼容 — 也读 X-Filename / X-Text header
        """
        import uuid as _uuid
        from urllib.parse import urlparse, parse_qs, unquote

        qs = parse_qs(urlparse(self.path).query)
        filename = (qs.get("filename", [None])[0]
                    or self.headers.get("X-Filename")
                    or "upload.bin")
        role = (qs.get("role", [None])[0]
                or self.headers.get("X-Role")
                or "user")
        text = (qs.get("text", [None])[0]
                or self.headers.get("X-Text")
                or "")
        quoted_ts = (qs.get("quoted_ts", [None])[0]
                     or self.headers.get("X-Quoted-Ts")
                     or None)
        location = None
        lat = qs.get("lat", [None])[0]
        lon = qs.get("lon", [None])[0]
        if lat is not None and lon is not None:
            location = {"lat": lat, "lon": lon}
            accuracy = qs.get("accuracy", [None])[0]
            label = qs.get("label", [None])[0]
            if accuracy is not None:
                location["accuracy"] = accuracy
            if label:
                location["label"] = label

        # url decode for non-ascii filename / text (parse_qs 已经 decode 但 header 没)
        try:
            if filename:
                filename = unquote(filename)
        except Exception:
            pass

        try:
            length = int(self.headers.get("Content-Length", 0))
        except Exception:
            length = 0
        if length <= 0 or length > 50 * 1024 * 1024:  # 50MB cap
            self._send_json(400, {"error": "invalid content-length (max 50MB)"})
            return

        # 推断 type
        ext = Path(filename).suffix.lower()
        image_exts = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif"}
        atype = "image" if ext in image_exts else "file"

        # uuid 命名 + 保留 extension
        stored_name = f"{_uuid.uuid4().hex}{ext}"
        stored_path = self.state.attachments_dir / stored_name

        try:
            with stored_path.open("wb") as f:
                remaining = length
                while remaining > 0:
                    chunk = self.rfile.read(min(remaining, 65536))
                    if not chunk:
                        break
                    f.write(chunk)
                    remaining -= len(chunk)
        except Exception as e:
            logger.exception("upload write fail")
            self._send_json(500, {"error": f"write fail: {e}"})
            return

        attachment_url = f"/attachments/{stored_name}"

        rec = self.state.chat.append(
            role=role,
            text=text,
            source="ios-app",
            quoted_ts=quoted_ts,
            attachment_url=attachment_url,
            attachment_type=atype,
            attachment_filename=filename,
            location=location,
        )

        # 如果是 user 上传 也往主 session 注入一条 hint 让 chain 感知有附件
        if role == "user":
            hint = f"[用户发了{'图片' if atype == 'image' else '文件'}: {filename}]"
            if rec.get("location"):
                loc = rec["location"]
                label = loc.get("label", "")
                hint += f" [位置 lat={loc['lat']:.6f} lon={loc['lon']:.6f}{(' ' + label) if label else ''}]"
            if text:
                hint = hint + " " + text
            if rec.get("quoted_text"):
                hint = f"[引用 \"{rec['quoted_text']}\"]\n" + hint
            # 给主 session 一条 hint 让 chain 读 file (mac mini 内可读 stored_path)
            hint += f"\n本地路径: {stored_path}"
            target_session = (self.state.active_session or self.state.default_session).strip()
            ok, err = self._inject_to_session(target_session, hint, source="ios-app", sender="iphone")
            if not ok:
                # 附件已存盘 + 历史已 append 但 chain 注入失败 — 502 surface
                self._send_json(502, {
                    "ok": False,
                    "error": f"inject attachment hint to '{target_session}' failed: {err}",
                    "record": rec,
                })
                return

        self._send_json(200, {"ok": True, "record": rec})

    def _handle_attachment_get(self):
        """静态服务 attachment 文件 — GET /attachments/<filename>"""
        from urllib.parse import unquote
        # path = /attachments/foo.jpg
        rel = self.path[len("/attachments/"):]
        rel = unquote(rel.split("?", 1)[0])
        # 防 path traversal
        if "/" in rel or ".." in rel or rel.startswith("."):
            self._send_json(400, {"error": "bad filename"})
            return
        target = self.state.attachments_dir / rel
        if not target.exists() or not target.is_file():
            self._send_json(404, {"error": "not found"})
            return
        # MIME 简单推断
        ext = target.suffix.lower()
        mime_map = {
            ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
            ".gif": "image/gif", ".webp": "image/webp",
            ".heic": "image/heic", ".heif": "image/heif",
            ".pdf": "application/pdf",
            ".txt": "text/plain", ".md": "text/markdown",
            ".mp3": "audio/mpeg", ".m4a": "audio/mp4",
            ".mp4": "video/mp4", ".mov": "video/quicktime",
        }
        mime = mime_map.get(ext, "application/octet-stream")
        try:
            length = target.stat().st_size
        except Exception:
            self._send_json(500, {"error": "read fail"})
            return
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "public, max-age=86400")
        self.end_headers()
        try:
            with target.open("rb") as f:
                while True:
                    chunk = f.read(64 * 1024)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError) as e:
            logger.debug("attachment client disconnected path=%s err=%s", target.name, e)
        except Exception:
            logger.exception("attachment stream fail path=%s", target)

    def _handle_chat_delete(self, body: dict[str, Any]):
        ts = body.get("ts", "").strip()
        if not ts:
            self._send_json(400, {"error": "ts required"})
            return
        ok = self.state.chat.delete(ts)
        self._send_json(200, {"ok": ok, "ts": ts})

    def _handle_chat_react(self, body: dict[str, Any]):
        ts = body.get("ts", "").strip()
        emoji = body.get("emoji", "").strip()
        if not ts or not emoji:
            self._send_json(400, {"error": "ts and emoji required"})
            return
        ok = self.state.chat.add_reaction(ts, emoji)
        self._send_json(200, {"ok": ok, "ts": ts, "emoji": emoji})
