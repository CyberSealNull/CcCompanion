"""Timeline storage + legacy aggregator.

New timeline events live in timeline_events.jsonl and drive the dashboard.
The old diary/chat/task/worklog daily view stays available as fallback.
"""
from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Any


CHAT_DEDUPE_GAP_SEC = 60
CHAT_MAX_PER_DAY = 200

# board → 颜色
BOARD_COLOR = {
    "用户": "pink",
    "opia/生活": "blue",
    "opia/工作": "orange",
}

TZ_CN = timezone(timedelta(hours=8))

DEFAULT_TAXONOMY: dict[str, dict[str, Any]] = {
    "rest": {
        "label": "休息",
        "color": "blue",
        "subcategories": {
            "sleep_night": "夜间睡眠",
            "sleep_nap": "午睡",
            "rest_break": "休息",
            "shower": "洗漱",
        },
    },
    "work": {
        "label": "工作",
        "color": "orange",
        "subcategories": {
            "work_focus": "深度工作",
            "meeting": "会议",
            "ops": "运营处理",
            "coding": "写代码",
            "review": "Review",
        },
    },
    "exercise": {
        "label": "运动",
        "color": "green",
        "subcategories": {
            "run": "跑步",
            "walk": "散步",
            "gym": "健身",
            "stretch": "拉伸",
        },
    },
    "eat": {
        "label": "饮食",
        "color": "pink",
        "subcategories": {
            "meal": "正餐",
            "snack": "零食",
            "drink": "饮品",
        },
    },
    "study": {
        "label": "学习",
        "color": "purple",
        "subcategories": {
            "reading": "阅读",
            "research": "研究",
            "course": "课程",
            "note": "笔记",
        },
    },
    "leisure": {
        "label": "娱乐",
        "color": "teal",
        "subcategories": {
            "game": "游戏",
            "video": "视频",
            "music": "音乐",
            "browse": "浏览",
        },
    },
    "social": {
        "label": "社交",
        "color": "indigo",
        "subcategories": {
            "chat": "聊天",
            "family": "家人",
            "friend": "朋友",
            "outing": "外出",
        },
    },
}


def _parse_iso(ts: str) -> datetime | None:
    try:
        return datetime.fromisoformat(ts)
    except Exception:
        return None


class Timeline:
    def __init__(self, diary, chat_history, task_queue, worklog):
        self.diary = diary
        self.chat = chat_history
        self.tasks = task_queue
        self.worklog = worklog
        base_dir = Path(getattr(chat_history, "path", Path.home() / "Opia" / "dynamic-island" / "apns-server" / "tokens")).expanduser().parent
        base_dir.mkdir(parents=True, exist_ok=True)
        self.events_path = base_dir / "timeline_events.jsonl"
        self.taxonomy_path = base_dir / "timeline_taxonomy.json"
        self.state_path = base_dir / "timeline_state.json"
        self._ensure_taxonomy()

    # ---------- event store ----------

    def _ensure_taxonomy(self):
        if self.taxonomy_path.exists():
            return
        self.taxonomy_path.write_text(
            json.dumps(DEFAULT_TAXONOMY, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

    def taxonomy(self) -> dict[str, Any]:
        self._ensure_taxonomy()
        try:
            return json.loads(self.taxonomy_path.read_text(encoding="utf-8"))
        except Exception:
            return DEFAULT_TAXONOMY

    def add_event(self, payload: dict[str, Any]) -> dict[str, Any]:
        records = self._normalize_payload(payload)
        with self.events_path.open("a", encoding="utf-8") as f:
            for rec in records:
                f.write(json.dumps(rec, ensure_ascii=False, sort_keys=True) + "\n")
        self._write_state()
        return {"ok": True, "events": records, "count": len(records)}

    def list_events(
        self,
        *,
        start: str | None = None,
        end: str | None = None,
        category: str | None = None,
        status: str | None = None,
        limit: int = 500,
    ) -> list[dict[str, Any]]:
        start_dt = _parse_iso(start) if start else None
        end_dt = _parse_iso(end) if end else None
        out: list[dict[str, Any]] = []
        if not self.events_path.exists():
            return out
        with self.events_path.open("r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except Exception:
                    continue
                if category and ev.get("category") != category:
                    continue
                if status and status != "all" and ev.get("status") != status:
                    continue
                ev_start = _parse_iso(ev.get("start_at", ""))
                ev_end = _parse_iso(ev.get("end_at", "")) or ev_start
                if start_dt and ev_end and ev_end <= start_dt:
                    continue
                if end_dt and ev_start and ev_start >= end_dt:
                    continue
                out.append(ev)
        out.sort(key=lambda e: e.get("start_at", ""))
        return out[-limit:] if limit and len(out) > limit else out

    def aggregate(
        self,
        *,
        range_name: str,
        anchor: str | None = None,
        category: str | None = None,
        status: str = "confirmed",
    ) -> dict[str, Any]:
        start_dt, end_dt, bucket = self._range_bounds(range_name, anchor)
        events = self.list_events(
            start=start_dt.isoformat(),
            end=end_dt.isoformat(),
            category=category,
            status=status,
            limit=10000,
        )
        taxonomy = self.taxonomy()
        distribution: dict[str, float] = {}
        breakdown: dict[str, float] = {}
        trend: dict[str, float] = {}
        for ev in events:
            minutes = self._event_minutes(ev)
            cat = ev.get("category") or "other"
            sub = ev.get("subcategory") or "other"
            distribution[cat] = distribution.get(cat, 0) + minutes
            breakdown[f"{cat}/{sub}"] = breakdown.get(f"{cat}/{sub}", 0) + minutes
            dt = _parse_iso(ev.get("start_at", ""))
            key = self._bucket_key(dt, bucket) if dt else "unknown"
            trend[key] = trend.get(key, 0) + minutes

        payload = {
            "ok": True,
            "range": range_name,
            "start": start_dt.isoformat(),
            "end": end_dt.isoformat(),
            "category": category,
            "status": status,
            "taxonomy": taxonomy,
            "distribution": [
                self._metric_row(k, v, taxonomy.get(k, {})) for k, v in sorted(distribution.items(), key=lambda kv: -kv[1])
            ],
            "breakdown": [
                {"key": k, "category": k.split("/", 1)[0], "subcategory": k.split("/", 1)[1], "minutes": round(v, 1)}
                for k, v in sorted(breakdown.items(), key=lambda kv: -kv[1])
            ],
            "trend": [{"bucket": k, "minutes": round(v, 1)} for k, v in sorted(trend.items())],
            "events": events,
        }
        return payload

    def _normalize_payload(self, payload: dict[str, Any]) -> list[dict[str, Any]]:
        start_at = str(payload.get("start_at") or "").strip()
        end_at = str(payload.get("end_at") or "").strip()
        if not start_at or not end_at:
            raise ValueError("start_at and end_at required")
        start = _parse_iso(start_at)
        end = _parse_iso(end_at)
        if not start or not end:
            raise ValueError("start_at/end_at must be ISO datetime")
        if end <= start:
            raise ValueError("end_at must be after start_at")

        taxonomy = self.taxonomy()
        category = str(payload.get("category") or "").strip()
        subcategory = str(payload.get("subcategory") or "").strip()
        if category not in taxonomy:
            raise ValueError(f"unknown category: {category}")
        valid_subs = set((taxonomy.get(category, {}).get("subcategories") or {}).keys())
        if subcategory not in valid_subs:
            raise ValueError(f"unknown subcategory for {category}: {subcategory}")

        status = str(payload.get("status") or "draft").strip()
        if status not in {"draft", "confirmed", "rejected"}:
            raise ValueError("status must be draft/confirmed/rejected")
        try:
            confidence = float(payload.get("confidence", 0.8))
        except Exception:
            confidence = 0.8
        confidence = max(0.0, min(1.0, confidence))

        title = str(payload.get("title") or "").strip()
        if not title:
            raise ValueError("title required")
        summary = str(payload.get("summary") or "").strip()
        source_type = str(payload.get("source_type") or "manual").strip()
        source_id = str(payload.get("source_id") or "").strip()

        records = []
        for idx, (part_start, part_end) in enumerate(self._split_midnight(start, end)):
            base = {
                "start_at": part_start.isoformat(),
                "end_at": part_end.isoformat(),
                "category": category,
                "subcategory": subcategory,
                "event_node": f"{category}/{subcategory}",
                "title": title[:120],
                "summary": summary[:1200],
                "source_type": source_type,
                "source_id": source_id,
                "confidence": confidence,
                "status": status,
                "created_at": datetime.now(TZ_CN).isoformat(timespec="seconds"),
            }
            raw_id = "|".join([base["start_at"], base["end_at"], category, subcategory, title, source_id, str(idx)])
            base["id"] = payload.get("id") if idx == 0 and payload.get("id") else hashlib.sha1(raw_id.encode("utf-8")).hexdigest()[:16]
            records.append(base)
        return records

    def _split_midnight(self, start: datetime, end: datetime) -> list[tuple[datetime, datetime]]:
        parts: list[tuple[datetime, datetime]] = []
        cursor = start
        while cursor.date() < end.date():
            next_midnight = datetime.combine(cursor.date() + timedelta(days=1), datetime.min.time(), tzinfo=cursor.tzinfo)
            parts.append((cursor, next_midnight))
            cursor = next_midnight
        parts.append((cursor, end))
        return parts

    def _range_bounds(self, range_name: str, anchor: str | None) -> tuple[datetime, datetime, str]:
        now = datetime.now(TZ_CN)
        if range_name == "day":
            day = datetime.fromisoformat(anchor).date() if anchor else now.date()
            start = datetime.combine(day, datetime.min.time(), tzinfo=TZ_CN)
            return start, start + timedelta(days=1), "hour"
        if range_name == "week":
            if anchor and "-W" in anchor:
                year_s, week_s = anchor.split("-W", 1)
                day = datetime.fromisocalendar(int(year_s), int(week_s), 1).date()
            elif anchor:
                day = datetime.fromisoformat(anchor).date()
                day = day - timedelta(days=day.weekday())
            else:
                day = now.date() - timedelta(days=now.date().weekday())
            start = datetime.combine(day, datetime.min.time(), tzinfo=TZ_CN)
            return start, start + timedelta(days=7), "day"
        if range_name == "month":
            if anchor:
                base = datetime.fromisoformat(anchor + "-01" if len(anchor) == 7 else anchor).date()
            else:
                base = now.date().replace(day=1)
            start = datetime.combine(base.replace(day=1), datetime.min.time(), tzinfo=TZ_CN)
            next_month = (start.replace(day=28) + timedelta(days=4)).replace(day=1)
            return start, next_month, "day"
        raise ValueError("range must be day/week/month")

    def _bucket_key(self, dt: datetime, bucket: str) -> str:
        if bucket == "hour":
            return dt.strftime("%H:00")
        return dt.date().isoformat()

    def _event_minutes(self, ev: dict[str, Any]) -> float:
        start = _parse_iso(ev.get("start_at", ""))
        end = _parse_iso(ev.get("end_at", ""))
        if not start or not end or end <= start:
            return 0
        return (end - start).total_seconds() / 60

    def _metric_row(self, key: str, minutes: float, meta: dict[str, Any]) -> dict[str, Any]:
        return {
            "category": key,
            "label": meta.get("label", key),
            "color": meta.get("color", "gray"),
            "minutes": round(minutes, 1),
        }

    def _write_state(self):
        try:
            events = self.list_events(limit=10000, status="all")
            self.state_path.write_text(
                json.dumps(
                    {
                        "ok": True,
                        "event_count": len(events),
                        "latest_event_at": events[-1].get("start_at") if events else None,
                        "updated_at": datetime.now(TZ_CN).isoformat(timespec="seconds"),
                    },
                    ensure_ascii=False,
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
        except Exception:
            pass

    # ---------- daily ----------

    def daily(self, date: str) -> dict:
        events: list[dict] = []

        # 1. diary 三 board
        for author, kind in [("用户", None), ("opia", "生活"), ("opia", "工作")]:
            try:
                f = self.diary.get(author=author, kind=kind, date=date)
            except Exception:
                continue
            for seg in f.get("segments", []):
                events.append(self._diary_event(date, author, kind, seg))

        # 2. chat history (filter + 降噪)
        events.extend(self._chat_events(date))

        # 3. task complete (filter 当日)
        events.extend(self._task_events(date))

        # 4. worklog (整日块)
        wl = self.worklog.get(date)
        if wl:
            events.append({
                "ts_start": wl["ts_start"],
                "ts_end": wl["ts_end"],
                "kind": "worklog",
                "subkind": "daily",
                "title": wl["title"],
                "preview": wl["preview"],
                "color": "purple",
                "source_id": f"worklog/{date}",
            })

        events.sort(key=lambda e: e.get("ts_start", ""))
        return {"ok": True, "date": date, "events": events}

    def weekly(self, week: str) -> dict:
        """week = '2026-W18' (ISO week). 返回 7 天 event 计数 + 各 kind 统计."""
        try:
            year_s, w_s = week.split("-W")
            year = int(year_s); w = int(w_s)
        except Exception:
            return {"ok": False, "error": "invalid week format / want YYYY-Www"}
        # ISO week → date
        try:
            monday = datetime.fromisocalendar(year, w, 1).date()
        except Exception:
            return {"ok": False, "error": "invalid week"}
        days = []
        for i in range(7):
            d = (monday + timedelta(days=i)).isoformat()
            day_data = self.daily(d)
            kinds: dict[str, int] = {}
            for ev in day_data["events"]:
                k = ev.get("kind", "other")
                kinds[k] = kinds.get(k, 0) + 1
            days.append({"date": d, "count": len(day_data["events"]), "kinds": kinds})
        return {"ok": True, "week": week, "days": days}

    def monthly(self, month: str) -> dict:
        return {"ok": False, "message": "monthly v0.2"}

    # ---------- helpers ----------

    def _diary_event(self, date: str, author: str, kind: str | None, seg: dict) -> dict:
        time = seg.get("time", "00:00")
        text = seg.get("text", "")
        subkind = author if kind is None else f"{author}/{kind}"
        return {
            "ts_start": f"{date}T{time}:00+08:00",
            "ts_end": None,
            "kind": "diary",
            "subkind": subkind,
            "title": text[:30] or "(空)",
            "preview": text[:500],
            "color": BOARD_COLOR.get(subkind, "gray"),
            "source_id": f"diary/{author}/{kind or '_'}/{date}/{time}",
        }

    def _chat_events(self, date: str) -> list[dict]:
        try:
            records = self.chat.list_for_date(date)
        except Exception:
            return []
        # 过滤 task progress (只保留 task add / done / cancel) — 通过 text 前缀启发式
        # 简化: task role 全保留 但 progress (含 "·" 前缀) 跳过
        filtered = []
        for r in records:
            role = r.get("role", "")
            text = r.get("text", "")
            if role == "task" and text.startswith("·"):
                continue  # progress 跳过
            filtered.append(r)

        # 60s 同 role 合并
        merged: list[dict] = []
        for r in filtered:
            if merged:
                last = merged[-1]
                if last.get("role") == r.get("role"):
                    last_dt = _parse_iso(last.get("ts", ""))
                    cur_dt = _parse_iso(r.get("ts", ""))
                    if last_dt and cur_dt and (cur_dt - last_dt).total_seconds() < CHAT_DEDUPE_GAP_SEC:
                        last["text"] = (last.get("text", "") + "\n" + r.get("text", "")).strip()
                        continue
            merged.append(dict(r))

        # 200 上限
        if len(merged) > CHAT_MAX_PER_DAY:
            kept_head = merged[: CHAT_MAX_PER_DAY // 2]
            kept_tail = merged[-(CHAT_MAX_PER_DAY // 2) :]
            placeholder = {
                "ts": kept_head[-1].get("ts", ""),
                "role": "system",
                "text": f"... 中间 {len(merged) - CHAT_MAX_PER_DAY} 条对话省略",
            }
            merged = kept_head + [placeholder] + kept_tail

        events = []
        for r in merged:
            role = r.get("role", "")
            text = r.get("text", "")
            attachment_type = r.get("attachment_type")
            title_prefix = ""
            if attachment_type == "image":
                title_prefix = "[图片] "
            elif attachment_type == "audio":
                title_prefix = "[语音] "
            elif r.get("audio_zh") or r.get("audio_en") or r.get("audio_ja"):
                title_prefix = "[多语音] "
            color = "blue" if role == "user" else ("orange" if role == "assistant" else "gray")
            events.append({
                "ts_start": r.get("ts", ""),
                "ts_end": None,
                "kind": "chat",
                "subkind": role or "unknown",
                "title": (title_prefix + text)[:30] or "(空)",
                "preview": text[:500],
                "color": color,
                "source_id": f"chat/{r.get('ts','')}/{role}",
            })
        return events

    def _task_events(self, date: str) -> list[dict]:
        try:
            snap = self.tasks.snapshot()
        except Exception:
            return []
        completed = snap.get("completed", []) or []
        # task_queue 自身 completed 没存 ts 在 snapshot... 但内部 json 有 completed_at
        # snapshot 可能不返回 completed_at — 直接读 raw json
        raw_completed = self._tasks_raw_completed()
        # date → 当日 unix 范围
        try:
            day_start = datetime.fromisoformat(f"{date}T00:00:00+08:00")
            day_end = datetime.fromisoformat(f"{date}T23:59:59+08:00")
        except Exception:
            return []
        events = []
        for t in raw_completed:
            ca = t.get("completed_at")
            if not isinstance(ca, (int, float)):
                continue
            ts_dt = datetime.fromtimestamp(ca, tz=timezone(timedelta(hours=8)))
            if not (day_start <= ts_dt <= day_end):
                continue
            ts_iso = ts_dt.isoformat()
            title = t.get("title", "(无标题)")
            total = t.get("total", 0)
            events.append({
                "ts_start": ts_iso,
                "ts_end": None,
                "kind": "task",
                "subkind": "done",
                "title": title[:30],
                "preview": f"✓ {title} ({total}/{total})",
                "color": "green",
                "source_id": f"task/{title}/{ca}",
            })
        return events

    def _tasks_raw_completed(self) -> list[dict]:
        # 直接读 task_queue 内部 path
        try:
            import json
            from pathlib import Path
            p = getattr(self.tasks, "path", None)
            if not p:
                return []
            with open(p, "r", encoding="utf-8") as f:
                d = json.load(f)
            return d.get("completed", []) or []
        except Exception:
            return []
