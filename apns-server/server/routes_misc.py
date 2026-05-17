from __future__ import annotations

from .common import *  # noqa: F403
from .common import _persist_active_session, _state_to_payload


class MiscRoutesMixin:
    def _handle_diary_post(self, body: dict[str, Any]):
        """
        POST /diary/post — append one diary message.

        Body: {role: "assistant"|"user"|"system", text: str, source?: str}

        When role=assistant (chain posting a probing question), we also fire
        an APNs banner to the iPhone so用户 knows there's a new diary prompt
        waiting. role=user replies are silent (no self-notification).
        """
        role = str(body.get("role") or "").strip().lower()
        text = (body.get("text") or body.get("content") or "").strip()
        source = str(body.get("source") or ("chain" if role == "assistant" else "ios-app")).strip()
        if role not in ("user", "assistant", "system"):
            self._send_json(400, {"ok": False, "error": "role must be user|assistant|system"})
            return
        if not text:
            self._send_json(400, {"ok": False, "error": "text required"})
            return
        try:
            rec = self.state.diary_stream.append(role=role, text=text, source=source)
        except Exception as e:
            logger.exception("diary_stream.append failed")
            self._send_json(500, {"ok": False, "error": str(e)})
            return

        # APNs ping用户 iPhone when chain posts a new question
        if role == "assistant":
            try:
                snippet = text if len(text) <= 160 else text[:157] + "…"
                self._send_chat_notification(title="日记 · AI", body_text=snippet)
            except Exception:
                logger.exception("diary APNs ping failed (non-fatal)")

        self._send_json(200, {"ok": True, "record": rec, "unread": self.state.diary_stream.unread()})

    def _handle_diary_poll(self):
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        since = qs.get("since", [None])[0]
        try:
            limit = int(qs.get("limit", ["200"])[0])
        except Exception:
            limit = 200
        limit = min(max(limit, 1), 1000)
        records = self.state.diary_stream.read_since(since_ts=since, limit=limit)
        self._send_json(200, {
            "ok": True,
            "records": records,
            "count": len(records),
            "unread": self.state.diary_stream.unread(),
            "latest_ts": self.state.diary_stream.latest_ts(),
        })

    def _handle_diary_history(self):
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        date = qs.get("date", [None])[0]
        try:
            limit = int(qs.get("limit", ["500"])[0])
        except Exception:
            limit = 500
        limit = min(max(limit, 1), 2000)
        if date:
            try:
                records = self.state.diary_stream.read_day(date)
            except ValueError as e:
                self._send_json(400, {"ok": False, "error": str(e)})
                return
        else:
            records = self.state.diary_stream.read_history(limit=limit)
        self._send_json(200, {"ok": True, "records": records, "count": len(records)})

    def _handle_diary_clear_unread(self):
        n = self.state.diary_stream.clear_unread()
        self._send_json(200, {"ok": True, "unread": n})

    def _handle_task_action(self, body: dict[str, Any], action: str):
        """task 队列管理 + 自动 push 灵动岛刷新"""
        snap = None
        if action == "add":
            title = body.get("title", "").strip()
            total = int(body.get("total", 1))
            if not title:
                self._send_json(400, {"error": "title required"})
                return
            snap = self.state.tasks.add(title, total)
        elif action == "progress":
            current = int(body.get("current", 0))
            step = body.get("step", "")
            total = body.get("total")
            snap = self.state.tasks.progress(current, step=step, total=total)
        elif action == "done":
            snap = self.state.tasks.done()
        elif action == "cancel":
            snap = self.state.tasks.cancel()
        elif action == "clear_history":
            snap = self.state.tasks.clear_history()

        # 自动 push 灵动岛 — 把当前 task queue 状态投到 ContentState
        if snap is not None:
            self._auto_push_from_task(snap, action)
            # 把 task lifecycle 事件放进 ephemeral buffer, 不污染 chat_history.jsonl
            try:
                if action == "add":
                    active = snap.get("active") or {}
                    title = active.get("title", "")
                    total = active.get("total", 0)
                    if title:
                        self.state.task_buffer.append(
                            text=f"▷ 开始 {title} (0/{total})",
                            source="system",
                        )
                elif action == "progress":
                    active = snap.get("active") or {}
                    title = active.get("title", "")
                    current = active.get("current", 0)
                    total = active.get("total", 0)
                    step = active.get("step", "") or ""
                    if title and step:
                        self.state.task_buffer.append(
                            text=f"· {step} ({current}/{total})",
                            source="system",
                        )
                elif action == "done":
                    completed = snap.get("completed", []) or []
                    last = completed[-1] if completed else None
                    title = last.get("title", "") if last else ""
                    total = last.get("total", 0) if last else 0
                    if title:
                        self.state.task_buffer.append(
                            text=f"✓ 完成 {title} ({total}/{total})",
                            source="system",
                        )
                elif action == "cancel":
                    completed = snap.get("completed", []) or []
                    last = completed[-1] if completed else None
                    title = last.get("title", "") if last else ""
                    if title:
                        self.state.task_buffer.append(
                            text=f"✗ 取消 {title}",
                            source="system",
                        )
            except Exception as e:
                logger.warning("task → chat history fail: %s", e)

        self._send_json(200, {"ok": True, "action": action, "snapshot": snap})

    def _handle_task_append_ephemeral(self, body: dict[str, Any]):
        text = body.get("text", "").strip()
        source = body.get("source", "claude-code")
        if not text:
            self._send_json(400, {"error": "text required"})
            return
        rec = self.state.task_buffer.append(text=text, source=source)
        self._send_json(200, {"ok": True, "record": rec})

    def _auto_push_from_task(self, snap: dict[str, Any], action: str):
        """根据 task queue snapshot 自动构造 ContentState push"""
        active = snap.get("active")
        queue_len = snap.get("queue_length", 0)
        completed = snap.get("completed", [])

        cs: dict[str, Any] = {
            "status": "thinking" if active else "spoke",
            "unreadCount": queue_len,  # 排队数 显示为 trailing 数字
        }

        if active:
            total = max(int(active["total"]), 1)
            current = int(active["current"])
            cs["taskTitle"] = active["title"]
            cs["taskCurrent"] = current
            cs["taskTotal"] = total
            cs["taskProgress"] = current / total
            if active.get("step"):
                cs["taskStep"] = str(active["step"])[:80]
        elif action == "done":
            # 没 active + 刚完成 = 全部完事
            last = completed[-1]["title"] if completed else ""
            cs["status"] = "spoke"
            cs["lastMessagePreview"] = f"✓ 全部完成 (最近: {last})" if last else "全部完成"

        # 完成历史 (最近 5 条 swift 端 completedTitles 字段)
        if completed:
            cs["completedTitles"] = [c["title"][:30] for c in completed[-5:]]

        # 2026-05-05 task done 时不 end Live Activity (client 端没 auto reattach mechanism end 之后再 add 起不来)
        # 改成 update event + cs 里 taskTitle 用空字符串显式覆盖 让 widget UI 看到"task 完成 idle 状态"不卡旧 task
        if action == "done":
            cs["taskTitle"] = ""
            cs["taskCurrent"] = 0
            cs["taskTotal"] = 0
            cs["taskStep"] = ""
            cs["taskProgress"] = 0.0
        if not self.state.apns_enabled:
            return
        active_tokens = self.state.tokens.all_active()
        if not active_tokens:
            return
        try:
            for tok in active_tokens:
                self.state.client.push_live_activity(
                    push_token=tok.token,
                    event="update",
                    content_state=cs,
                )
        except Exception as e:
            logger.warning("auto push from task fail: %s", e)

    def _query(self) -> dict[str, list[str]]:
        from urllib.parse import parse_qs, urlparse
        return parse_qs(urlparse(self.path).query)

    def _query_value(self, qs: dict[str, list[str]], key: str, default: str | None = None) -> str | None:
        value = qs.get(key, [default])[0]
        return value if value != "" else default

    def _handle_diary_calendar(self):
        qs = self._query()
        try:
            author = self._query_value(qs, "author")
            month = self._query_value(qs, "month")
            if not author or not month:
                self._send_json(400, {"error": "author and month required"})
                return
            res = self.state.diary.calendar(
                author=author,
                kind=self._query_value(qs, "kind"),
                month=month,
            )
            self._send_json(200, {"ok": True, **res})
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("diary calendar fail")
            self._send_json(500, {"error": str(e)})

    def _handle_diary_get(self):
        qs = self._query()
        try:
            author = self._query_value(qs, "author")
            date = self._query_value(qs, "date")
            if not author or not date:
                self._send_json(400, {"error": "author and date required"})
                return
            res = self.state.diary.get(
                author=author,
                kind=self._query_value(qs, "kind"),
                date=date,
            )
            self._send_json(200, {"ok": True, **res})
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("diary get fail")
            self._send_json(500, {"error": str(e)})

    def _handle_diary_search(self):
        qs = self._query()
        try:
            query = self._query_value(qs, "q")
            if not query:
                self._send_json(400, {"error": "q required"})
                return
            records = self.state.diary.search(
                query=query,
                author=self._query_value(qs, "author"),
            )
            self._send_json(200, {"ok": True, "records": records, "count": len(records)})
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("diary search fail")
            self._send_json(500, {"error": str(e)})

    def _handle_diary_on_this_day(self):
        qs = self._query()
        try:
            date = self._query_value(qs, "date")
            if not date:
                self._send_json(400, {"error": "date required"})
                return
            self._send_json(200, {"ok": True, **self.state.diary.on_this_day(date)})
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("diary on-this-day fail")
            self._send_json(500, {"error": str(e)})

    def _handle_diary_streak(self):
        qs = self._query()
        try:
            author = self._query_value(qs, "author")
            if not author:
                self._send_json(400, {"error": "author required"})
                return
            self._send_json(
                200,
                {"ok": True, **self.state.diary.streak(author=author, kind=self._query_value(qs, "kind"))},
            )
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("diary streak fail")
            self._send_json(500, {"error": str(e)})

    def _handle_diary_prompts(self):
        qs = self._query()
        try:
            context = self._query_value(qs, "context")
            if not context:
                self._send_json(400, {"error": "context required"})
                return
            prompts = self.state.diary.prompts(context)
            self._send_json(200, {"ok": True, "prompts": prompts})
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("diary prompts fail")
            self._send_json(500, {"error": str(e)})

    def _handle_timeline(self):
        qs = self._query()
        try:
            date = self._query_value(qs, "date")
            week = self._query_value(qs, "week")
            month = self._query_value(qs, "month")
            if date:
                self._send_json(200, self.state.timeline.daily(date))
            elif week:
                self._send_json(200, self.state.timeline.weekly(week))
            elif month:
                self._send_json(200, self.state.timeline.monthly(month))
            else:
                self._send_json(400, {"error": "date / week / month required"})
        except Exception as e:
            logger.exception("timeline fail")
            self._send_json(500, {"error": str(e)})

    def _handle_timeline_events(self):
        qs = self._query()
        try:
            try:
                limit = int(self._query_value(qs, "limit", "500") or "500")
            except Exception:
                limit = 500
            limit = max(1, min(limit, 10000))
            events = self.state.timeline.list_events(
                start=self._query_value(qs, "start") or self._query_value(qs, "from"),
                end=self._query_value(qs, "end") or self._query_value(qs, "to"),
                category=self._query_value(qs, "category"),
                status=self._query_value(qs, "status"),
                limit=limit,
            )
            self._send_json(200, {"ok": True, "events": events, "count": len(events)})
        except Exception as e:
            logger.exception("timeline events fail")
            self._send_json(500, {"error": str(e)})

    def _handle_timeline_aggregate(self):
        qs = self._query()
        try:
            range_name = self._query_value(qs, "range", "day") or "day"
            anchor = (
                self._query_value(qs, "anchor")
                or self._query_value(qs, "date")
                or self._query_value(qs, "week")
                or self._query_value(qs, "month")
            )
            status = self._query_value(qs, "status", "confirmed") or "confirmed"
            payload = self.state.timeline.aggregate(
                range_name=range_name,
                anchor=anchor,
                category=self._query_value(qs, "category"),
                status=status,
            )
            self._send_json(200, payload)
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("timeline aggregate fail")
            self._send_json(500, {"error": str(e)})

    def _handle_timeline_event(self, body: dict[str, Any]):
        try:
            self._send_json(200, self.state.timeline.add_event(body))
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("timeline event fail")
            self._send_json(500, {"error": str(e)})

    def _handle_diary_append(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        try:
            required = ["author", "date", "time", "text"]
            missing = [key for key in required if not body.get(key)]
            if missing:
                self._send_json(400, {"error": f"{', '.join(missing)} required"})
                return
            if body.get("attachment_path"):
                res = self.state.diary.append_with_attachment(
                    author=body["author"],
                    kind=body.get("kind"),
                    date=body["date"],
                    time=body["time"],
                    text=body["text"],
                    attachment_path=body["attachment_path"],
                    frontmatter=body.get("frontmatter") or None,
                )
            else:
                res = self.state.diary.append(
                    author=body["author"],
                    kind=body.get("kind"),
                    date=body["date"],
                    time=body["time"],
                    text=body["text"],
                    frontmatter=body.get("frontmatter") or None,
                )
            self._send_json(200, res)
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("diary append fail")
            self._send_json(500, {"error": str(e)})

    def _handle_diary_upload(self):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        allowed_exts = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif"}
        try:
            length = int(self.headers.get("Content-Length", 0))
        except Exception:
            length = 0
        max_size = 10 * 1024 * 1024
        if length <= 0:
            self._send_json(400, {"error": "empty upload"})
            return
        if length > max_size:
            self._send_json(413, {"error": "file too large"})
            return
        content_type = self.headers.get("Content-Type", "")
        if "multipart/form-data" not in content_type or "boundary=" not in content_type:
            self._send_json(400, {"error": "multipart/form-data required"})
            return
        try:
            from email import policy
            from email.parser import BytesParser
            import tempfile
            import uuid as _uuid

            raw = self.rfile.read(length)
            msg = BytesParser(policy=policy.default).parsebytes(
                (
                    f"Content-Type: {content_type}\r\n"
                    "MIME-Version: 1.0\r\n\r\n"
                ).encode("utf-8") + raw
            )
            file_part = None
            for part in msg.iter_parts():
                if part.get_param("name", header="content-disposition") == "file":
                    file_part = part
                    break
            if file_part is None:
                self._send_json(400, {"error": "file field required"})
                return
            filename = file_part.get_filename() or "upload.bin"
            ext = Path(filename).suffix.lower()
            if ext not in allowed_exts:
                self._send_json(400, {"error": "unsupported file extension"})
                return
            payload = file_part.get_payload(decode=True) or b""
            if not payload:
                self._send_json(400, {"error": "empty file"})
                return
            if len(payload) > max_size:
                self._send_json(413, {"error": "file too large"})
                return
            target = Path(tempfile.gettempdir()) / f"opia_diary_upload_{_uuid.uuid4().hex}{ext}"
            target.write_bytes(payload)
            self._send_json(
                200,
                {
                    "ok": True,
                    "local_path": str(target),
                    "suggested_filename": filename,
                },
            )
        except Exception as e:
            logger.exception("diary upload fail")
            self._send_json(500, {"error": str(e)})

    def _handle_diary_edit(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        try:
            required = ["author", "date", "time", "new_text"]
            missing = [key for key in required if not body.get(key)]
            if missing:
                self._send_json(400, {"error": f"{', '.join(missing)} required"})
                return
            res = self.state.diary.edit(
                author=body["author"],
                kind=body.get("kind"),
                date=body["date"],
                time=body["time"],
                new_text=body["new_text"],
            )
            self._send_json(200, res)
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("diary edit fail")
            self._send_json(500, {"error": str(e)})

    def _handle_diary_delete_attachment(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        rel_path = body.get("rel_path")
        if not rel_path:
            self._send_json(400, {"error": "rel_path required"})
            return
        try:
            self._send_json(200, {"ok": self.state.diary.delete_attachment(rel_path)})
        except Exception as e:
            logger.exception("diary delete attachment fail")
            self._send_json(500, {"error": str(e)})

    def _handle_favorites_list(self):
        qs = self._query()
        try:
            try:
                limit = int(self._query_value(qs, "limit", "50") or "50")
                offset = int(self._query_value(qs, "offset", "0") or "0")
            except Exception:
                self._send_json(400, {"error": "limit and offset must be integers"})
                return
            records = self.state.favorites.list(
                type=self._query_value(qs, "type"),
                tag=self._query_value(qs, "tag"),
                q=self._query_value(qs, "q"),
                limit=limit,
                offset=offset,
            )
            self._send_json(200, {"ok": True, "records": records, "count": len(records)})
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("favorites list fail")
            self._send_json(500, {"error": str(e)})

    def _handle_favorites_get(self):
        qs = self._query()
        try:
            fav_id = self._query_value(qs, "id")
            if not fav_id:
                self._send_json(400, {"error": "id required"})
                return
            record = self.state.favorites.get(fav_id)
            self._send_json(200, {"ok": record is not None, "record": record})
        except Exception as e:
            logger.exception("favorites get fail")
            self._send_json(500, {"error": str(e)})

    def _handle_favorites_add(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        try:
            required = ["type", "source", "refs"]
            missing = [key for key in required if not body.get(key)]
            if missing:
                self._send_json(400, {"error": f"{', '.join(missing)} required"})
                return
            if body.get("attachment_path"):
                record = self.state.favorites.add_with_attachment(
                    type=body["type"],
                    source=body["source"],
                    refs=body["refs"],
                    local_path=body["attachment_path"],
                    tags=body.get("tags"),
                    note=body.get("note"),
                )
            else:
                record = self.state.favorites.add(
                    type=body["type"],
                    source=body["source"],
                    refs=body["refs"],
                    tags=body.get("tags"),
                    note=body.get("note"),
                )
            self._send_json(200, {"ok": True, "record": record})
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("favorites add fail")
            self._send_json(500, {"error": str(e)})

    def _handle_favorites_edit(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        try:
            fav_id = body.get("id")
            if not fav_id:
                self._send_json(400, {"error": "id required"})
                return
            record = self.state.favorites.edit(
                id=fav_id,
                tags=body["tags"] if "tags" in body else None,
                note=body["note"] if "note" in body else None,
            )
            self._send_json(200, {"ok": record is not None, "record": record})
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("favorites edit fail")
            self._send_json(500, {"error": str(e)})

    def _handle_favorites_delete(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        try:
            fav_id = body.get("id")
            if not fav_id:
                self._send_json(400, {"error": "id required"})
                return
            self._send_json(200, {"ok": self.state.favorites.delete(fav_id), "id": fav_id})
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
        except Exception as e:
            logger.exception("favorites delete fail")
            self._send_json(500, {"error": str(e)})

    def _handle_favorites_delete_by_turn(self, body: dict[str, Any]):
        """Phase 设置大砍 — 删 last-ref-ts == given ts 的所有 favorite entries.
        body: {ts: "<turn-end ts>"}
        """
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        try:
            ts = body.get("ts")
            if not ts:
                self._send_json(400, {"error": "ts required"})
                return
            # Find all favorites where the LAST ref ts matches; collect their ids; delete each.
            all_items = self.state.favorites.list(limit=10_000, offset=0)
            removed_ids: list[str] = []
            for item in all_items:
                refs = item.get("refs", []) if isinstance(item, dict) else []
                if refs:
                    last_ref = refs[-1]
                    if isinstance(last_ref, dict) and last_ref.get("ts") == ts:
                        fav_id = item.get("id")
                        if fav_id and self.state.favorites.delete(fav_id):
                            removed_ids.append(fav_id)
            self._send_json(200, {"ok": True, "removed": removed_ids})
        except Exception as e:
            logger.exception("favorites delete_by_turn fail")
            self._send_json(500, {"error": str(e)})

    def _handle_favorites_reload(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        try:
            count = self.state.favorites.reload()
            self._send_json(200, {"ok": True, "count": count})
        except Exception as e:
            logger.exception("favorites reload fail")
            self._send_json(500, {"error": str(e)})

    def _require_rp_manager(self) -> bool:
        if rp_session_manager is not None:
            return True
        self._send_json(501, {"error": "rp_session_manager not installed"})
        return False

    def _rp_chain_append(self, sid: str, rec: dict[str, Any]) -> None:
        if rp_session_manager is None:
            raise RuntimeError("rp_session_manager not installed")
        chain_path = rp_session_manager.active_dir(sid) / "chain.jsonl"
        chain_path.parent.mkdir(parents=True, exist_ok=True)
        with chain_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")

    def _handle_rp_new(self, body: dict[str, Any]):
        if not self._require_rp_manager():
            return
        seed = str(body.get("character_seed") or "").strip()
        if not seed:
            self._send_json(400, {"error": "character_seed required"})
            return
        try:
            started = rp_session_manager.start(character_seed=seed)
            self._send_json(200, {"ok": True, "sid": started["sid"], "character_card": started["character_card"]})
        except Exception as e:
            logger.exception("rp new fail")
            self._send_json(500, {"error": str(e)})

    def _handle_rp_send(self, body: dict[str, Any]):
        if not self._require_rp_manager():
            return
        sid = str(body.get("sid") or "").strip()
        text = str(body.get("text") or "").strip()
        try:
            sid = validate_rp_sid(sid)
        except ValueError:
            self._send_json(400, {"error": "invalid sid"})
            return
        if not text:
            self._send_json(400, {"error": "text required"})
            return
        if not rp_session_manager.active_dir(sid).exists():
            self._send_json(404, {"error": "rp session not found"})
            return
        try:
            meta = rp_session_manager.touch_activity(sid, turns_delta=1)
            rec = self.state.rp_history.append(
                sid=sid,
                role="user",
                text=text,
                source="ios-app",
                character_id=meta.get("character_id") or sid,
            )
            self._rp_chain_append(sid, rec)
            spawn_logged(
                [
                    "python3",
                    self.state.bus_send_path,
                    "--source", "ios-rp",
                    "--sender", "iphone",
                    "--channel", "rp",
                    "--sid", sid,
                    "--text", text,
                ],
                context="rp bus_send",
                timeout=10.0,
            )
            self._send_json(200, {"ok": True, "record": rec})
        except Exception as e:
            logger.exception("rp send fail")
            self._send_json(500, {"error": str(e)})

    def _handle_rp_history(self):
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        sid = qs.get("sid", [""])[0]
        since = qs.get("since", [None])[0]
        try:
            sid = validate_rp_sid(sid)
        except ValueError:
            self._send_json(400, {"error": "invalid sid"})
            return
        try:
            limit = int(qs.get("limit", ["10000"])[0])
        except Exception:
            limit = 10000
        try:
            records = self.state.rp_history.read_since(sid=sid, since_ts=since, limit=limit)
            self._send_json(200, {"ok": True, "messages": records, "count": len(records)})
        except Exception as e:
            logger.exception("rp history fail")
            self._send_json(500, {"error": str(e)})

    def _handle_rp_append(self, body: dict[str, Any]):
        if not self._require_rp_manager():
            return
        sid = str(body.get("sid") or "").strip()
        role = str(body.get("role") or "assistant").strip()
        text = str(body.get("text") or "").strip()
        try:
            sid = validate_rp_sid(sid)
        except ValueError:
            self._send_json(400, {"error": "invalid sid"})
            return
        if role not in ("user", "assistant", "system"):
            self._send_json(400, {"error": "bad role"})
            return
        if not text:
            self._send_json(400, {"error": "text required"})
            return
        try:
            meta = rp_session_manager.touch_activity(sid, turns_delta=1)
            rec = self.state.rp_history.append(
                sid=sid,
                role=role,
                text=text,
                source=str(body.get("source") or "claude-code"),
                character_id=meta.get("character_id") or sid,
            )
            self._rp_chain_append(sid, rec)
            # standard remote notification banner — 跳过 user 消息和 [op] 前缀
            if role == "assistant" and text and not text.startswith("[op]"):
                char_name = str(meta.get("character_name") or "Cc · RP")
                threading.Thread(
                    target=self._send_chat_notification,
                    args=(char_name, text[:80]),
                    daemon=True,
                ).start()
            self._send_json(200, {"ok": True, "record": rec})
        except Exception as e:
            logger.exception("rp append fail")
            self._send_json(500, {"error": str(e)})

    def _handle_rp_archive(self, body: dict[str, Any]):
        if not self._require_rp_manager():
            return
        sid = str(body.get("sid") or "").strip()
        try:
            sid = validate_rp_sid(sid)
        except ValueError:
            self._send_json(400, {"error": "invalid sid"})
            return
        try:
            out = rp_session_manager.archive(sid)
            self._send_json(200, {"ok": True, "archived_path": out["archived_path"]})
        except FileNotFoundError as e:
            self._send_json(404, {"error": str(e)})
        except Exception as e:
            logger.exception("rp archive fail")
            self._send_json(500, {"error": str(e)})

    def _handle_rp_list(self):
        if not self._require_rp_manager():
            return
        try:
            self._send_json(200, {
                "ok": True,
                "active": rp_session_manager.list_active(),
                "archived": rp_session_manager.list_archived(),
            })
        except Exception as e:
            logger.exception("rp list fail")
            self._send_json(500, {"error": str(e)})

    def _group_tmux_session_exists(self, session: str) -> bool:
        try:
            return subprocess.run(
                ["tmux", "has-session", "-t", session],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2,
                check=False,
            ).returncode == 0
        except Exception:
            return False

    def _group_online_agents(self) -> set[str]:
        online: set[str] = set()
        for member in self.state.group_chat.roster():
            tmux = member.get("tmux")
            if member.get("can_reply") and tmux and self._group_tmux_session_exists(str(tmux)):
                online.add(member["id"])
        return online

    def _handle_group_roster(self):
        self._send_json(
            200,
            {
                "ok": True,
                "roster": self.state.group_chat.roster(),
                "status": self.state.group_chat.status_snapshot(self._group_tmux_session_exists),
            },
        )

    def _handle_group_status(self):
        self._send_json(
            200,
            {"ok": True, **self.state.group_chat.status_snapshot(self._group_tmux_session_exists)},
        )

    def _handle_group_tasks(self):
        self._send_json(200, {"ok": True, **self.state.group_chat.tasks_summary()})

    def _handle_group_history(self):
        qs = self._query()
        since = self._query_value(qs, "since")
        before = self._query_value(qs, "before") or self._query_value(qs, "before_ts")
        try:
            limit = int(self._query_value(qs, "limit", "100") or "100")
        except Exception:
            limit = 100
        limit = min(max(limit, 1), 1000)
        records = self.state.group_chat.read_since(since_ts=since, before_ts=before, limit=limit)
        self._send_json(200, {"ok": True, "records": records, "count": len(records)})

    def _handle_group_poll(self):
        qs = self._query()
        since = self._query_value(qs, "since")
        try:
            limit = int(self._query_value(qs, "limit", "100") or "100")
        except Exception:
            limit = 100
        limit = min(max(limit, 1), 500)
        records = self.state.group_chat.read_since(since_ts=since, limit=limit)
        self._send_json(
            200,
            {
                "ok": True,
                "records": records,
                "count": len(records),
                "last_ts": records[-1]["ts"] if records else since,
                "status": self.state.group_chat.status_snapshot(self._group_tmux_session_exists),
            },
        )

    def _handle_group_send(self, body: dict[str, Any]):
        text = str(body.get("text") or "").strip()
        sender_id = str(body.get("sender_id") or "amian").strip()
        if not text:
            self._send_json(400, {"error": "text required"})
            return
        # 2026-05-05 dedupe storm guard: client_msg_id 优先 没有则按 (sender, text) 3s 窗口
        client_msg_id = body.get("client_msg_id")
        cache = getattr(type(self), "_group_dedupe_cache", None)
        if cache is None:
            cache = {}
            type(self)._group_dedupe_cache = cache
        now_ts = time.time()
        if client_msg_id:
            cache_key = f"cmid:{client_msg_id}"
        else:
            cache_key = f"{sender_id}|{text[:200]}"
        last_ts = cache.get(cache_key, 0)
        if now_ts - last_ts < 3.0:
            self._send_json(429, {"ok": False, "error": "duplicate within 3s window", "deduped": True})
            return
        cache[cache_key] = now_ts
        for k in list(cache.keys()):
            if now_ts - cache[k] > 60:
                del cache[k]
        # 2026-05-05 用户 push 加 agent 互相 @ 功能 移除 amian-only 限制
        # agent 发也 OK 走 targets_for 内 hop_count loop guard

        hop_count = int(body.get("hop_count", 0) or 0)
        mentions = self.state.group_chat.normalize_mentions(body.get("mentions"), text)
        # 2026-05-06 用户 push: quote/reply 自动 mention 原 sender
        # 当 sender=amian + parent_msg_id 不空 + mentions 为空 → 从 history 找 parent sender 加进 mentions
        # 防止 quote 没显式 @ 时被默认 inject 给 opia 而不是 quote 那条的原 sender
        parent_msg_id = body.get("parent_msg_id")
        if sender_id == "amian" and parent_msg_id and not mentions:
            try:
                history = self.state.group_chat.tail(limit=200)
                for h in history:
                    if h.get("id") == parent_msg_id:
                        parent_sender = h.get("sender_id")
                        if parent_sender and parent_sender != "amian" and parent_sender in {"opia", "sonnet", "shu", "opus47_fresh"}:
                            mentions = [parent_sender]
                        break
            except Exception:
                pass
        targets = self.state.group_chat.targets_for(sender_id, mentions, self._group_online_agents(), hop_count=hop_count)
        dispatch_id = f"dsp_{int(time.time() * 1000)}"
        mode = "default" if not mentions else ("all" if "__all__" in mentions else "mention")
        delivery = {
            "targets": targets,
            "mode": mode,
            "dispatch_id": dispatch_id,
            "delivered": [],
            "failed": [],
        }
        meta = {}
        if body.get("client_msg_id"):
            meta["client_msg_id"] = body.get("client_msg_id")
        message_type = str(body.get("message_type") or "chat").strip().lower()
        owner = str(body.get("owner") or "").strip() or self._infer_group_task_owner(body, mentions)
        try:
            rec = self.state.group_chat.append(
                sender_id,
                text,
                source=str(body.get("source") or "ios-app"),
                mentions=mentions,
                parent_msg_id=body.get("parent_msg_id") or None,
                reply_to=body.get("reply_to") or None,
                delivery=delivery,
                meta=meta,
                message_type=message_type,
                task_id=str(body.get("task_id") or "").strip() or None,
                parent_task_id=str(body.get("parent_task_id") or "").strip() or None,
                owner=owner,
            )
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
            return

        if targets:
            context = "\n".join(self.state.group_chat.context_lines(limit=20))
            for agent_id in targets:
                self.state.group_chat.set_typing(agent_id, True, dispatch_id=dispatch_id)
            try:
                spawn_logged(
                    [
                        "python3",
                        self.state.bus_send_path,
                        "--source", "ios-group",
                        "--sender", sender_id,
                        "--channel", "group",
                        "--text", text,
                        "--message-id", rec["id"],
                        "--parent-msg-id", str(body.get("parent_msg_id") or ""),
                        "--mentions", ",".join(mentions),
                        "--to", ",".join(targets),
                        "--context", context,
                        "--hop-count", str(hop_count + 1),
                        "--inject-only",
                    ],
                    context="group bus_send",
                    timeout=10.0,
                )
            except Exception as e:
                logger.warning("group bus_send fail: %s", e)
                delivery["failed"] = targets
                delivery["targets"] = targets
                for agent_id in targets:
                    self.state.group_chat.set_typing(agent_id, False, dispatch_id=dispatch_id)

        self._send_json(200, {"ok": True, "record": rec, "targets": targets})

    def _handle_group_append(self, body: dict[str, Any]):
        text = str(body.get("text") or "").strip()
        sender_id = str(body.get("sender_id") or body.get("agent_id") or "").strip()
        if not sender_id:
            self._send_json(400, {"error": "sender_id required"})
            return
        if not text:
            self._send_json(400, {"error": "text required"})
            return
        # 2026-05-05 dedupe storm guard: 同 sender 同 text 在 3 秒内重复 直接 reject
        # 防 ios client retry loop / double tap 把群刷爆
        cache = getattr(self, "_group_dedupe_cache", None)
        if cache is None:
            cache = {}
            type(self)._group_dedupe_cache = cache  # 类级共享
        cache_key = f"{sender_id}|{text[:200]}"
        now_ts = time.time()
        last_ts = cache.get(cache_key, 0)
        if now_ts - last_ts < 3.0:
            self._send_json(429, {"ok": False, "error": "duplicate within 3s window", "deduped": True})
            return
        cache[cache_key] = now_ts
        # 清旧 entry (超过 60s 的)
        for k in list(cache.keys()):
            if now_ts - cache[k] > 60:
                del cache[k]
        mentions = self.state.group_chat.normalize_mentions(body.get("mentions"), text)
        message_type = str(body.get("message_type") or "chat").strip().lower()
        owner = str(body.get("owner") or "").strip() or self._infer_group_task_owner(body, mentions)
        # 2026-05-05 用户 push 加 agent 互相 @ 功能
        # parent message 的 hop_count + 1 当前 message hop_count 用于 loop guard
        hop_count = int(body.get("hop_count", 0) or 0)
        targets = self.state.group_chat.targets_for(sender_id, mentions, self._group_online_agents(), hop_count=hop_count)
        try:
            rec = self.state.group_chat.append(
                sender_id,
                text,
                source=str(body.get("source") or f"tmux:{sender_id}"),
                mentions=mentions,
                parent_msg_id=body.get("parent_msg_id") or None,
                reply_to=body.get("reply_to") or None,
                delivery={"targets": targets, "delivered": [], "failed": []},
                meta={"loop_depth": hop_count},
                message_type=message_type,
                task_id=str(body.get("task_id") or "").strip() or None,
                parent_task_id=str(body.get("parent_task_id") or "").strip() or None,
                owner=owner,
            )
        except ValueError as e:
            self._send_json(400, {"error": str(e)})
            return
        self.state.group_chat.set_typing(sender_id, False)
        # 2026-05-05 加 fan-out trigger 当 sender 是 agent + mentions 含 agent
        if targets:
            dispatch_id = f"dsp_{int(time.time() * 1000)}"
            context = "\n".join(self.state.group_chat.context_lines(limit=20))
            for agent_id in targets:
                self.state.group_chat.set_typing(agent_id, True, dispatch_id=dispatch_id)
            try:
                spawn_logged(
                    [
                        "python3",
                        self.state.bus_send_path,
                        "--source", "ios-group",
                        "--sender", sender_id,
                        "--channel", "group",
                        "--text", text,
                        "--message-id", rec["id"],
                        "--parent-msg-id", str(body.get("parent_msg_id") or ""),
                        "--mentions", ",".join(mentions),
                        "--to", ",".join(targets),
                        "--context", context,
                        "--hop-count", str(hop_count + 1),
                        "--inject-only",
                    ],
                    context="group fan-out",
                    timeout=10.0,
                )
            except Exception as e:
                logger.warning("group fan-out fail: %s", e)
                for agent_id in targets:
                    self.state.group_chat.set_typing(agent_id, False, dispatch_id=dispatch_id)
        self._send_json(200, {"ok": True, "record": rec, "targets": targets})

    def _infer_group_task_owner(self, body: dict[str, Any], mentions: list[str]) -> str | None:
        assignee = body.get("assignee") or body.get("assigned_to")
        if assignee:
            return str(assignee).strip()
        for agent_id in mentions:
            if agent_id in {"opia", "sonnet", "shu", "opus47_fresh"}:
                return agent_id
        return None

    def _handle_group_delete(self, body: dict[str, Any]):
        msg_id = str(body.get("id") or "").strip()
        if not msg_id:
            self._send_json(400, {"error": "id required"})
            return
        ok = self.state.group_chat.delete(msg_id)
        self._send_json(200, {"ok": ok, "id": msg_id})

    def _handle_group_clear(self, body: dict[str, Any]):
        # 2026-05-05 一键清屏 仅 amian 可调
        sender_id = str(body.get("sender_id") or "").strip()
        if sender_id != "amian":
            self._send_json(403, {"error": "only amian can clear group"})
            return
        try:
            jsonl = self.state.group_chat.path
            if jsonl.exists():
                from datetime import datetime
                ts_tag = datetime.now().strftime("%Y%m%d_%H%M%S")
                bak = jsonl.with_suffix(jsonl.suffix + f".bak.user-clear.{ts_tag}")
                bak.write_bytes(jsonl.read_bytes())
                jsonl.write_text("")
                self.state.group_chat._last_ts = ""
            self._send_json(200, {"ok": True, "cleared": True, "backup": str(bak) if jsonl.exists() else None})
        except Exception as e:
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_calendar_categories(self):
        self._send_json(200, {"ok": True, "categories": self.state.calendar.categories()})

    def _handle_calendar_list(self):
        events = self.state.calendar.list_all()
        self._send_json(200, {"ok": True, "events": events, "count": len(events)})

    def _handle_calendar_day(self):
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        date = qs.get("date", [""])[0]
        if not date or len(date) < 10:
            self._send_json(400, {"error": "date=YYYY-MM-DD required"})
            return
        events = self.state.calendar.list_day(date[:10])
        self._send_json(200, {"ok": True, "events": events, "date": date[:10]})

    def _handle_calendar_month(self):
        from urllib.parse import urlparse, parse_qs
        qs = parse_qs(urlparse(self.path).query)
        try:
            year = int(qs.get("year", [str(datetime.now().year)])[0])
            month = int(qs.get("month", [str(datetime.now().month)])[0])
        except ValueError:
            self._send_json(400, {"error": "year/month must be int"})
            return
        events = self.state.calendar.list_month(year, month)
        self._send_json(200, {"ok": True, "events": events, "year": year, "month": month})

    def _handle_calendar_add(self, body: dict[str, Any]):
        try:
            rec = self.state.calendar.add(
                title=str(body.get("title") or ""),
                category=str(body.get("category") or "personal"),
                start_ts=str(body.get("start_ts") or ""),
                end_ts=body.get("end_ts"),
                notes=body.get("notes"),
                all_day=bool(body.get("all_day", False)),
                source=str(body.get("source") or "manual"),
                source_msg_id=body.get("source_msg_id"),
            )
            self._send_json(200, {"ok": True, "event": rec})
        except ValueError as e:
            self._send_json(400, {"ok": False, "error": str(e)})

    def _handle_calendar_update(self, body: dict[str, Any]):
        event_id = str(body.get("id") or "").strip()
        if not event_id:
            self._send_json(400, {"error": "id required"})
            return
        patch = {k: v for k, v in body.items() if k != "id"}
        if "category" in patch:
            patch["color"] = CATEGORIES.get(str(patch["category"]), "#7F8C8D")
        rec = self.state.calendar.update(event_id, **patch)
        if not rec:
            self._send_json(404, {"ok": False, "error": "event not found"})
            return
        self._send_json(200, {"ok": True, "event": rec})

    def _handle_calendar_delete(self, body: dict[str, Any]):
        event_id = str(body.get("id") or "").strip()
        if not event_id:
            self._send_json(400, {"error": "id required"})
            return
        ok = self.state.calendar.delete(event_id)
        self._send_json(200 if ok else 404, {"ok": ok, "id": event_id})

    def _handle_calendar_tick(self, body: dict[str, Any]):
        # 由 launchd 每 60s POST 触发. 找 due 事件 → APNs alert + chat ping → mark fired.
        due = self.state.calendar.due_within(lookahead_seconds=70)
        fired_ids: list[str] = []
        for ev in due:
            try:
                self._calendar_fire_event(ev)
                self.state.calendar.mark_fired(ev["id"])
                fired_ids.append(ev["id"])
            except Exception as e:
                logger.warning("calendar tick fire fail %s: %s", ev.get("id"), e)
        self._send_json(200, {"ok": True, "fired": fired_ids, "count": len(fired_ids)})

    def _calendar_fire_event(self, ev: dict[str, Any]):
        # build 70 phase 1: 只做 chat ping. APNs alert 推到 phase 2 (需要接 client.push_simple_alert 还没实现).
        try:
            from datetime import datetime
            now = datetime.now().strftime("%H:%M")
            cat = CATEGORY_LABELS.get(ev.get("category", "personal"), "")
            note_part = f" ({ev.get('notes')})" if ev.get("notes") else ""
            ping_text = f"[日程·{cat}] {now} {ev.get('title', '事件')}{note_part}"
            self.state.chat.append({"role": "assistant", "text": ping_text, "source": "calendar:tick"})
        except Exception as e:
            logger.warning("calendar chat ping fail: %s", e)

    def _handle_group_dispatch_state(self, body: dict[str, Any]):
        agent_id = str(body.get("agent_id") or "").strip()
        if not agent_id:
            self._send_json(400, {"error": "agent_id required"})
            return
        self.state.group_chat.set_typing(
            agent_id,
            bool(body.get("is_typing")),
            dispatch_id=body.get("dispatch_id") or None,
        )
        self._send_json(200, {"ok": True, "status": self.state.group_chat.status_snapshot(self._group_tmux_session_exists)})

    def _handle_studyroom_today(self):
        try:
            payload = self.state.studyroom.today_payload()
            self._send_json(200, {"ok": True, **payload})
        except Exception as e:
            logger.warning("studyroom_today fail: %s", e)
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_studyroom_projects(self):
        try:
            grouped = self.state.studyroom.projects_payload()
            self._send_json(200, {"ok": True, **grouped})
        except Exception as e:
            logger.warning("studyroom_projects fail: %s", e)
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_studyroom_project(self):
        from urllib.parse import urlparse, unquote
        path = urlparse(self.path).path
        slug = unquote(path[len("/studyroom/project/"):]).strip("/")
        if not slug:
            self._send_json(400, {"ok": False, "error": "slug required"})
            return
        try:
            data = self.state.studyroom.project_payload(slug)
            if data is None:
                self._send_json(404, {"ok": False, "error": "not found"})
                return
            self._send_json(200, {"ok": True, **data})
        except Exception as e:
            logger.warning("studyroom_project fail: %s", e)
            self._send_json(500, {"ok": False, "error": str(e)})

    def _handle_group_typing(self, body: dict[str, Any]):
        """POST /group/typing — chain hook 推 typing+status_text. spec 2026-05-09.
        body: {sender_id, is_typing, status_text?, dispatch_id?}
        """
        agent_id = str(body.get("sender_id") or body.get("agent_id") or "").strip()
        if not agent_id:
            self._send_json(400, {"error": "sender_id required"})
            return
        is_typing = bool(body.get("is_typing"))
        # status_text: pass through verbatim. None = leave; "" = clear; str = set
        if "status_text" in body:
            status_text = body.get("status_text")
            status_text = "" if status_text is None else str(status_text)
        else:
            status_text = None
        self.state.group_chat.set_typing(
            agent_id,
            is_typing,
            dispatch_id=body.get("dispatch_id") or None,
            status_text=status_text,
        )
        self._send_json(200, {"ok": True})

    def _handle_pet_state_get(self):
        """GET /pet/state — 当前 latest 状态."""
        self._send_json(200, {"ok": True, "latest": self.state.pet.latest()})

    def _handle_pet_state_post(self, body: dict[str, Any]):
        """POST /pet/state — chain hook 上报状态. body: {state, reason?, ts?}.
        VALID_STATES: idle/thinking/typing/building/juggling/conducting/error/happy/notification/sweeping/carrying/sleeping."""
        state = str(body.get("state") or "").strip()
        reason = str(body.get("reason") or "")
        ts = body.get("ts")
        if not state:
            self._send_json(400, {"error": "state required"})
            return
        rec = self.state.pet.update(state=state, reason=reason, ts=ts)
        # 推 SSE
        self.state.pet_bus.publish(rec)
        self._send_json(200, {"ok": True, "rec": rec})

    def _handle_pet_bubble_post(self, body: dict[str, Any]):
        """POST /pet/bubble — chain hook 推 speech bubble. body: {text, ts?}.
        text 已截好 (前 30 字 + ...) chain hook 那侧负责截.
        """
        text = str(body.get("text") or "").strip()
        ts = body.get("ts") or ""
        if not text:
            self._send_json(400, {"error": "text required"})
            return
        if not ts:
            from datetime import datetime, timezone, timedelta
            tz = timezone(timedelta(hours=8))
            ts = datetime.now(tz).isoformat(timespec="milliseconds")
        rec = {"text": text, "ts": ts}
        self.state.pet_bubble_bus.publish(rec)
        self._send_json(200, {"ok": True, "rec": rec})

    def _handle_pet_stream(self):
        """GET /pet/stream — SSE 实时推送 pet 状态变化.
        client 接 EventSource (iOS URLSession streaming / Mac Electron native)."""
        import time as _t
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        # 先发当前 latest
        latest = self.state.pet.latest()
        try:
            self.wfile.write(f"data: {json.dumps(latest, ensure_ascii=False)}\n\n".encode("utf-8"))
            self.wfile.flush()
        except Exception:
            return
        # 订阅 bus (state + bubble 共用一条 SSE; client 用 event 字段区分)
        q = self.state.pet_bus.subscribe()
        bq = self.state.pet_bubble_bus.subscribe()
        try:
            while True:
                wrote = False
                if q:
                    rec = q.popleft()
                    payload = dict(rec)
                    payload.setdefault("event", "state")
                    try:
                        self.wfile.write(f"data: {json.dumps(payload, ensure_ascii=False)}\n\n".encode("utf-8"))
                        self.wfile.flush()
                        wrote = True
                    except Exception:
                        break
                if bq:
                    brec = bq.popleft()
                    payload = dict(brec)
                    payload["event"] = "bubble"
                    try:
                        self.wfile.write(f"data: {json.dumps(payload, ensure_ascii=False)}\n\n".encode("utf-8"))
                        self.wfile.flush()
                        wrote = True
                    except Exception:
                        break
                if not wrote:
                    # heartbeat keepalive 不让 client 断
                    try:
                        self.wfile.write(b": keepalive\n\n")
                        self.wfile.flush()
                    except Exception:
                        break
                    _t.sleep(1.0)
        finally:
            self.state.pet_bus.unsubscribe(q)
            self.state.pet_bubble_bus.unsubscribe(bq)

    def _handle_pet_activity_post(self, body: dict[str, Any]):
        """POST /pet/activity — chain hook 推 streaming terminal display 行.
        body: {event_type, tool_name, summary, ts?}
        event_type: pre_tool / post_tool / stop / user_prompt
        """
        event_type = str(body.get("event_type") or "").strip() or "pre_tool"
        tool_name = str(body.get("tool_name") or "").strip()
        summary = str(body.get("summary") or "").strip()
        friendly_label = str(body.get("friendly_label") or "").strip()
        ts = body.get("ts")
        if not ts:
            from datetime import datetime, timezone, timedelta
            tz = timezone(timedelta(hours=8))
            ts = datetime.now(tz).isoformat(timespec="milliseconds")
        rec = {
            "event_type": event_type,
            "tool_name": tool_name,
            "summary": summary,
            "friendly_label": friendly_label,
            "ts": ts,
        }
        self.state.pet_activity_bus.publish(rec)
        self._send_json(200, {"ok": True, "rec": rec})

    def _handle_pet_activity_stream(self):
        """GET /pet/activity_stream — SSE 推 chain 实时活动 (terminal display)."""
        import time as _t
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "keep-alive")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        q = self.state.pet_activity_bus.subscribe()
        try:
            while True:
                wrote = False
                if q:
                    rec = q.popleft()
                    try:
                        self.wfile.write(f"data: {json.dumps(rec, ensure_ascii=False)}\n\n".encode("utf-8"))
                        self.wfile.flush()
                        wrote = True
                    except Exception:
                        break
                if not wrote:
                    try:
                        self.wfile.write(b": keepalive\n\n")
                        self.wfile.flush()
                    except Exception:
                        break
                    _t.sleep(1.0)
        finally:
            self.state.pet_activity_bus.unsubscribe(q)

    def _handle_pet_animations(self):
        """GET /pet/animations — 列出本地 svg 资产路径 (供 client 拉取或直接 file:// load)."""
        from pathlib import Path as _P
        svg_dir = _P("/path/to/CcCompanion/handy-clawd-assets/svg")
        if not svg_dir.exists():
            self._send_json(404, {"error": "svg dir missing", "expected": str(svg_dir)})
            return
        files = sorted([p.name for p in svg_dir.glob("*.svg")])
        self._send_json(200, {"ok": True, "count": len(files), "svg_dir": str(svg_dir), "files": files})

    def _handle_todos_toggle(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        res = todos_mod.toggle(
            rel_path=body.get("path", ""),
            heading=body.get("heading", ""),
            text=body.get("text", ""),
            expected_done=body.get("expected_done"),
            file_mtime=body.get("file_mtime"),
            line_index=body.get("line_index"),
        )
        if res.get("ok"):
            done = res.get("new_done", False)
            verb = "勾完成" if done else "取消勾"
            self._notify_chain_todo(f"[用户 {verb}: {body.get('text', '')[:60]}]")
        self._send_json(200 if res.get("ok") else 400, res)

    def _handle_todos_add(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        res = todos_mod.add(
            rel_path=body.get("path", ""),
            heading=body.get("heading", ""),
            text=body.get("text", ""),
            actor=body.get("actor"),
            after_text=body.get("after_text"),
        )
        if res.get("ok"):
            heading = body.get("heading", "")
            self._notify_chain_todo(f"[用户 新增待办 ({heading}): {res.get('added_text', '')[:80]}]")
        self._send_json(200 if res.get("ok") else 400, res)

    def _handle_todos_edit(self, body: dict[str, Any]):
        if not self._check_auth():
            self._send_json(401, {"error": "auth required"})
            return
        res = todos_mod.edit(
            rel_path=body.get("path", ""),
            heading=body.get("heading", ""),
            text=body.get("text", ""),
            new_text=body.get("new_text", ""),
        )
        if res.get("ok"):
            old = res.get("old_text", "")[:50]
            new = res.get("new_text", "")[:50]
            self._notify_chain_todo(f"[用户 编辑待办: {old} → {new}]")
        self._send_json(200 if res.get("ok") else 400, res)

    def _notify_chain_todo(self, text: str):
        """todos toggle/add/edit 成功后 推一条 system 消息给主 chain — 让 Cc 立刻知道用户改了什么.
        走 bus_send.py UNIX socket — 同微信入站走的同一条路径"""
        try:
            spawn_logged(
                [
                    "python3",
                    self.state.bus_send_path,
                    "--source", "todos",
                    "--sender", "ios-app",
                    "--text", text,
                    "--mode", "user",
                ],
                context="todo notify_chain",
                timeout=10.0,
            )
        except Exception as e:
            logger.warning("notify_chain_todo fail: %s", e)

    def _handle_gomoku_state(self):
        try:
            state = self._compute_gomoku_state()
            self._send_json(200, {"ok": True, **state})
        except Exception as e:
            logger.exception("gomoku state fail")
            self._send_json(500, {"error": str(e)})

    def _compute_gomoku_state(self) -> dict:
        """全量重建五子棋局面。revision = 当前局活跃 move 数，任何增删都改变它。"""
        board_size = 13
        board: list[list[str | None]] = [[None] * board_size for _ in range(board_size)]
        active_moves: list[dict] = []
        seq = 0
        next_turn = "black"
        winner: str | None = None

        move_records = self.state.chat.search(role="move", limit=10000)
        for rec in move_records:
            text = rec.get("text", "").strip()
            parts = text.split()
            if not parts:
                continue
            cmd = parts[0]
            if cmd == "reset":
                new_size = int(parts[1]) if len(parts) >= 2 else 13
                board_size = new_size
                board = [[None] * board_size for _ in range(board_size)]
                active_moves = []
                seq = 0
                next_turn = "black"
                winner = None
                continue
            if cmd not in ("black", "white") or len(parts) < 2:
                continue
            coord_parts = parts[1].split(",")
            if len(coord_parts) != 2:
                continue
            try:
                r, c = int(coord_parts[0]), int(coord_parts[1])
            except ValueError:
                continue
            if not (0 <= r < board_size and 0 <= c < board_size):
                continue
            if board[r][c] is not None:
                continue  # 已占 幂等跳过
            if winner is not None:
                continue  # 已有赢家 不再落子
            board[r][c] = cmd
            seq += 1
            active_moves.append({"ts": rec["ts"], "color": cmd, "row": r, "col": c, "seq": seq})
            if self._gomoku_check_winner(board, r, c, cmd, board_size):
                winner = cmd
            else:
                next_turn = "white" if cmd == "black" else "black"

        return {
            "revision": len(active_moves),
            "board_size": board_size,
            "moves": active_moves,
            "next_turn": next_turn,
            "winner": winner,
        }

    def _gomoku_check_winner(self, board: list, r: int, c: int, color: str, size: int) -> bool:
        dirs = [(0, 1), (1, 0), (1, 1), (1, -1)]
        for dr, dc in dirs:
            count = 1
            rr, cc = r + dr, c + dc
            while 0 <= rr < size and 0 <= cc < size and board[rr][cc] == color:
                count += 1; rr += dr; cc += dc
            rr, cc = r - dr, c - dc
            while 0 <= rr < size and 0 <= cc < size and board[rr][cc] == color:
                count += 1; rr -= dr; cc -= dc
            if count >= 5:
                return True
        return False

    def _handle_usage_overview(self):
        """综合用量: ccusage active block + OTS 统计 + Anthropic 链接"""
        try:
            ccusage_data = self._get_ccusage_cached()
            ots_data = self._get_ots_stats()
            anthropic_url = (
                self.state.config.get("server", {})
                .get("anthropic_dashboard_url", "https://claude.ai/settings/usage")
            )
            self._send_json(200, {
                "ok": True,
                "ccusage": ccusage_data,
                "ots": ots_data,
                "anthropic_url": anthropic_url,
            })
        except Exception as e:
            logger.exception("usage overview fail")
            self._send_json(500, {"error": str(e)})

    def _get_ccusage_cached(self) -> dict:
        """调 ccusage blocks --json，结果缓存 5 分钟到 tokens/ccusage_cache.json"""
        cache_path = Path(self.state.token_store_path).parent / "ccusage_cache.json"
        # 读缓存
        if cache_path.exists():
            try:
                cached = json.loads(cache_path.read_text(encoding="utf-8"))
                if time.time() - cached.get("_cached_at", 0) < 300:
                    cached.pop("_cached_at", None)
                    return cached
            except Exception:
                pass
        # 跑 ccusage
        candidates = ["/opt/homebrew/bin/ccusage", "ccusage"]
        raw_data: dict | None = None
        for exe in candidates:
            try:
                res = subprocess.run(
                    [exe, "blocks", "--json"],
                    capture_output=True, text=True, timeout=15,
                )
                if res.returncode == 0:
                    raw_data = json.loads(res.stdout)
                    break
            except FileNotFoundError:
                continue
            except Exception as e:
                logger.warning("ccusage run fail: %s", e)
                return {"available": False, "error": "ccusage run failed"}
        if raw_data is None:
            return {"available": False, "error": "ccusage not installed"}

        blocks = raw_data.get("blocks", [])
        active = next((b for b in blocks if b.get("isActive")), None)
        result: dict = {"available": True}
        if active:
            proj = active.get("projection") or {}
            result["active_block"] = {
                "cost_usd": round(active.get("costUSD", 0.0), 2),
                "tokens": active.get("totalTokens", 0),
                "end_time": active.get("endTime", ""),
                "minutes_until_reset": proj.get("remainingMinutes"),
                "models": active.get("models", []),
            }
        else:
            result["active_block"] = None
        # 写缓存
        try:
            cache_path.write_text(
                json.dumps({**result, "_cached_at": time.time()}, ensure_ascii=False),
                encoding="utf-8",
            )
        except Exception:
            pass
        return result

    def _get_ots_stats(self) -> dict:
        """OTS 自身统计: chat 行数 / 今日 / active device / uptime"""
        chat_path = self.state.chat.path
        total = 0
        today_count = 0
        today_prefix = datetime.now().strftime("%Y-%m-%d")
        try:
            with open(chat_path, "r", encoding="utf-8") as f:
                for line in f:
                    if not line.strip():
                        continue
                    total += 1
                    # ts 总在行首 30 字节内: {"ts": "2026-05-02T...
                    if today_prefix in line[:30]:
                        today_count += 1
        except Exception:
            pass
        active_device_count = len(self.state.tokens.all_active())
        uptime_hours = round((time.time() - self.state.started_at) / 3600, 1)
        return {
            "chat_total": total,
            "chat_today": today_count,
            "active_device_count": active_device_count,
            "uptime_hours": uptime_hours,
        }

    def _handle_usage_active(self):
        snapshot = self.state.usage.get_active()
        self._send_json(200, snapshot)
