"""Workgroup chat storage and routing helpers."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import re
import threading
import time
import uuid
from typing import Any, Callable


# Default agent roster. The IDs (amian / opia / shu / sonnet / opus47_fresh)
# are protocol identifiers kept for back-compat with shipped clients. Display
# names, avatars and tmux session names below are generic placeholders. Fork
# users: copy `agents_config.example.json` → `agents_config.json` (gitignored)
# and supply your own roster + mention_aliases. ID-string customization
# (renaming protocol ids) is a future spec.
ROSTER: list[dict[str, Any]] = [
    {
        "id": "amian",
        "display_name": "User",
        "kind": "human",
        "avatar": "U",
        "color": "neutral",
        "model": None,
        "tmux": None,
        "can_reply": False,
    },
    {
        "id": "opia",
        "display_name": "Assistant",
        "kind": "agent",
        "avatar": "A",
        "color": "orange",
        "model": "Claude Opus 4.7",
        "tmux": "assistant",
        "can_reply": True,
        "default_responder": True,
    },
    {
        "id": "sonnet",
        "display_name": "Agent B",
        "kind": "agent",
        "avatar": "B",
        "color": "blue",
        "model": "Claude Sonnet 4.6",
        "tmux": "agent-b",
        "can_reply": True,
    },
    {
        "id": "shu",
        "display_name": "Agent C",
        "kind": "agent",
        "avatar": "C",
        "color": "green",
        "model": "Codex GPT-5.5",
        "tmux": "agent-c",
        "can_reply": True,
    },
    {
        "id": "opus47_fresh",
        "display_name": "Agent D",
        "kind": "agent",
        "avatar": "D",
        "color": "purple",
        "model": "Claude Opus 4.7",
        "tmux": "agent-d",
        "can_reply": True,
        "optional": True,
    },
]


# Load optional user-supplied roster + alias config from `agents_config.json`
# (gitignored). Falls back to defaults above if the file does not exist.
#
# Build 218 r3 item 4 — also merge user_overrides/group_member_{additions,removals}.json
# so adds/removes from the iOS Settings sheet take effect without a server restart.
def _load_agents_config() -> None:
    global ROSTER, ROSTER_BY_ID, REPLY_AGENT_IDS, MENTION_ALIASES
    here = Path(__file__).resolve().parent
    cfg_path = here / "agents_config.json"
    if cfg_path.exists():
        try:
            data = json.loads(cfg_path.read_text(encoding="utf-8"))
            if isinstance(data.get("agents"), list) and data["agents"]:
                ROSTER = data["agents"]
            if isinstance(data.get("mention_aliases"), dict):
                MENTION_ALIASES = dict(data["mention_aliases"])
        except Exception:
            pass

    # Merge user-supplied additions/removals from iOS Settings sheet.
    overrides_dir = here / "user_overrides"
    add_path = overrides_dir / "group_member_additions.json"
    if add_path.exists():
        try:
            additions = json.loads(add_path.read_text(encoding="utf-8") or "[]")
            if isinstance(additions, list):
                existing_ids = {m.get("id") for m in ROSTER}
                for rec in additions:
                    aid = rec.get("id")
                    if not aid or aid in existing_ids:
                        continue
                    ROSTER.append(rec)
                    existing_ids.add(aid)
                    # Self-alias so @<id> mentions resolve. Also alias display_name lowercased.
                    MENTION_ALIASES[aid.lower()] = aid
                    dn = (rec.get("display_name") or "").strip().lower()
                    if dn and dn not in MENTION_ALIASES:
                        MENTION_ALIASES[dn] = aid
        except Exception:
            pass

    rm_path = overrides_dir / "group_member_removals.json"
    if rm_path.exists():
        try:
            removals = json.loads(rm_path.read_text(encoding="utf-8") or "[]")
            if isinstance(removals, list):
                removed = set(removals)
                ROSTER = [m for m in ROSTER if m.get("id") not in removed]
                for rid in removed:
                    # Drop aliases that point to a removed id; also drop alias keyed by the id itself.
                    for key in [k for k, v in MENTION_ALIASES.items() if v == rid or k == rid.lower()]:
                        MENTION_ALIASES.pop(key, None)
        except Exception:
            pass

    ROSTER_BY_ID = {m["id"]: m for m in ROSTER}
    REPLY_AGENT_IDS = [m["id"] for m in ROSTER if m.get("can_reply")]


def reload_agents_config() -> None:
    """Public entry: re-merge agents_config.json + user_overrides files into live ROSTER.

    Called by push.py /group/members/{add,delete} handlers after they persist
    user-override files so iOS-side adds/removes route mentions immediately.
    """
    _load_agents_config()


ROSTER_BY_ID = {m["id"]: m for m in ROSTER}
REPLY_AGENT_IDS = [m["id"] for m in ROSTER if m.get("can_reply")]
ALL_TOKEN = "__all__"
MESSAGE_TYPES = {"task", "decision", "ship", "block", "progress", "chat"}
TASK_STATUS_BY_MESSAGE_TYPE = {
    "task": "open",
    "progress": "in-progress",
    "ship": "done",
    "block": "blocked",
}
MENTION_RE = re.compile(r"@([A-Za-z0-9_\-]+|[\u4e00-\u9fff]+)")
MENTION_ALIASES = {
    "all": ALL_TOKEN,
    "__all__": ALL_TOKEN,
    "assistant": "opia",
    "ai": "opia",
    "AI": "opia",
    "user": "amian",
    "User": "amian",
    "amian": "amian",
    "opia": "opia",
    "agent-b": "sonnet",
    "b": "sonnet",
    "sonnet": "sonnet",
    "agent-c": "shu",
    "c": "shu",
    "shu": "shu",
    "agent-d": "opus47_fresh",
    "d": "opus47_fresh",
    "opus47_fresh": "opus47_fresh",
}

# Apply user config override if present (must run after MENTION_ALIASES init).
_load_agents_config()


def _now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="milliseconds")


def _parse_iso(ts: str) -> datetime | None:
    try:
        return datetime.fromisoformat(ts)
    except Exception:
        return None


def _dedupe_ordered(items: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for item in items:
        if item and item not in seen:
            out.append(item)
            seen.add(item)
    return out


def _task_id() -> str:
    return f"task_{int(time.time() * 1000)}_{uuid.uuid4().hex[:6]}"


class GroupChatStore:
    def __init__(self, jsonl_path: str | Path, state_path: str | Path | None = None):
        self.path = Path(jsonl_path).expanduser()
        self.state_path = Path(state_path).expanduser() if state_path else None
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if self.state_path:
            self.state_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._state = self._load_state()
        self._last_ts = str(self._state.get("last_ts") or "")

    def _load_state(self) -> dict[str, Any]:
        if not self.state_path or not self.state_path.exists():
            return {"agents": {}}
        try:
            with open(self.state_path, encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                return data
        except Exception:
            pass
        return {"agents": {}}

    def _save_state(self):
        if not self.state_path:
            return
        tmp = self.state_path.with_suffix(self.state_path.suffix + ".tmp")
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self._state, f, ensure_ascii=False, indent=2)
        tmp.replace(self.state_path)

    def _next_ts(self) -> str:
        ts = _now_iso()
        prev = _parse_iso(self._last_ts) if self._last_ts else None
        cur = _parse_iso(ts)
        if prev and cur and ts <= self._last_ts:
            ts = (prev + timedelta(milliseconds=1)).isoformat(timespec="milliseconds")
        self._last_ts = ts
        self._state["last_ts"] = ts
        return ts

    def roster(self) -> list[dict[str, Any]]:
        return [dict(m) for m in ROSTER]

    def member(self, agent_id: str) -> dict[str, Any] | None:
        return ROSTER_BY_ID.get(agent_id)

    def normalize_mentions(self, mentions: Any = None, text: str | None = None) -> list[str]:
        raw: list[str] = []
        if isinstance(mentions, str):
            raw.extend([m.strip() for m in mentions.split(",") if m.strip()])
        elif isinstance(mentions, list):
            raw.extend(str(m).strip() for m in mentions if str(m).strip())
        if text:
            raw.extend(m.group(1).strip() for m in MENTION_RE.finditer(text))

        normalized: list[str] = []
        for item in raw:
            key = item.strip().lstrip("@").lower()
            agent_id = MENTION_ALIASES.get(key)
            if agent_id:
                normalized.append(agent_id)
        return _dedupe_ordered(normalized)

    def targets_for(
        self,
        sender_id: str,
        mentions: list[str],
        online_agents: set[str] | None = None,
        hop_count: int = 0,
    ) -> list[str]:
        # 2026-05-05 用户 push 加 agent 互相 @ 功能 + hop_count loop guard
        # human user sends: no @mention → default to primary assistant; otherwise parse @
        # agent 发: 必须 explicit mention 才 fan-out + hop_count >= 3 停 (防无限 loop)
        if sender_id == "amian":
            # Build 217 T3 / B-2 broadcast — human user with no @mention fans
            # out to all reply-capable agents (replaces the old default-to-primary
            # routing). Each receiving agent self-decides whether to respond
            # (their SOP "群聊收到 broadcast 消息" section handles relevance).
            if not mentions:
                candidates = REPLY_AGENT_IDS
            elif ALL_TOKEN in mentions:
                candidates = REPLY_AGENT_IDS
            else:
                candidates = [m for m in mentions if m in REPLY_AGENT_IDS]
        else:
            # agent → agent fan-out
            if hop_count >= 3:
                return []
            if not mentions or ALL_TOKEN in mentions:
                # agent 无 mention 或 @all 不 fan-out (防扩散)
                return []
            candidates = [m for m in mentions if m in REPLY_AGENT_IDS and m != sender_id]
        if online_agents is not None:
            candidates = [m for m in candidates if m in online_agents]
        return _dedupe_ordered(candidates)

    def append(
        self,
        sender_id: str,
        text: str,
        *,
        source: str = "group",
        mentions: list[str] | None = None,
        parent_msg_id: str | None = None,
        reply_to: str | None = None,
        delivery: dict[str, Any] | None = None,
        meta: dict[str, Any] | None = None,
        conversation_id: str = "workgroup",
        message_type: str = "chat",
        task_id: str | None = None,
        parent_task_id: str | None = None,
        owner: str | None = None,
        attachment_url: str | None = None,
        attachment_filename: str | None = None,
        attachment_type: str | None = None,
    ) -> dict[str, Any]:
        member = self.member(sender_id)
        if not member:
            raise ValueError(f"unknown sender_id: {sender_id}")
        text = str(text or "").strip()
        # Build 217-patch-A: attachment-only message (image / file pure upload)
        # allowed — text may be empty when attachment is set.
        if not text and not attachment_url:
            raise ValueError("text or attachment required")
        message_type = str(message_type or "chat").strip().lower()
        if message_type not in MESSAGE_TYPES:
            raise ValueError(f"bad message_type: {message_type}")
        if message_type == "task" and not task_id:
            task_id = _task_id()
        record = {
            "id": f"grp_{int(time.time() * 1000)}_{uuid.uuid4().hex[:8]}",
            "ts": "",
            "conversation_id": conversation_id,
            "sender_id": sender_id,
            "sender_model": member.get("model"),
            "text": text,
            "mentions": mentions or [],
            "parent_msg_id": parent_msg_id,
            "reply_to": reply_to,
            "source": source,
            "delivery": delivery or {},
            "meta": meta or {},
            "message_type": message_type,
            "task_id": task_id,
            "parent_task_id": parent_task_id,
            "owner": owner,
            "attachment_url": attachment_url,
            "attachment_filename": attachment_filename,
            "attachment_type": attachment_type,
        }
        with self._lock:
            ts = self._next_ts()
            record["ts"] = ts
            line = json.dumps(record, ensure_ascii=False)
            with open(self.path, "a", encoding="utf-8") as f:
                f.write(line + "\n")
            if member.get("can_reply"):
                self.set_typing(sender_id, False, save=False)
                self._state.setdefault("agents", {}).setdefault(sender_id, {})["last_seen"] = ts
            self._save_state()
        return record

    def _normalize_record(self, rec: dict[str, Any]) -> dict[str, Any]:
        out = dict(rec)
        msg_type = str(out.get("message_type") or "chat").strip().lower()
        out["message_type"] = msg_type if msg_type in MESSAGE_TYPES else "chat"
        out.setdefault("task_id", None)
        out.setdefault("parent_task_id", None)
        out.setdefault("owner", None)
        # Build 217-patch-A: backfill attachment fields on legacy records
        out.setdefault("attachment_url", None)
        out.setdefault("attachment_filename", None)
        out.setdefault("attachment_type", None)
        return out

    def _iter_records(self) -> list[dict[str, Any]]:
        if not self.path.exists():
            return []
        rows: list[dict[str, Any]] = []
        with open(self.path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(self._normalize_record(json.loads(line)))
                except json.JSONDecodeError:
                    continue
        return rows

    def read_since(
        self,
        since_ts: str | None = None,
        *,
        before_ts: str | None = None,
        limit: int = 100,
    ) -> list[dict[str, Any]]:
        if not self.path.exists():
            return []
        rows: list[dict[str, Any]] = []
        with open(self.path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = rec.get("ts", "")
                if since_ts and ts <= since_ts:
                    continue
                if before_ts and ts >= before_ts:
                    continue
                rows.append(self._normalize_record(rec))
        if before_ts:
            rows = rows[-limit:]
        else:
            rows = rows[:limit] if since_ts else rows[-limit:]
        return rows

    def tasks_summary(self) -> dict[str, Any]:
        tasks: dict[str, dict[str, Any]] = {}
        events: list[dict[str, Any]] = []
        for rec in self._iter_records():
            msg_type = rec.get("message_type", "chat")
            tid = rec.get("task_id") if msg_type == "task" else rec.get("parent_task_id")
            if msg_type not in TASK_STATUS_BY_MESSAGE_TYPE or not tid:
                continue
            status = TASK_STATUS_BY_MESSAGE_TYPE[msg_type]
            if msg_type == "task":
                task = tasks.setdefault(
                    str(tid),
                    {
                        "task_id": tid,
                        "owner": rec.get("owner") or "unassigned",
                        "status": "open",
                        "title": rec.get("text", ""),
                        "created_at": rec.get("ts"),
                        "updated_at": rec.get("ts"),
                        "source_msg_id": rec.get("id"),
                        "last_event_id": rec.get("id"),
                    },
                )
                task["owner"] = rec.get("owner") or task.get("owner") or "unassigned"
                task["status"] = "open"
            else:
                task = tasks.setdefault(
                    str(tid),
                    {
                        "task_id": tid,
                        "owner": rec.get("owner") or "unassigned",
                        "status": status,
                        "title": "",
                        "created_at": None,
                        "updated_at": rec.get("ts"),
                        "source_msg_id": None,
                        "last_event_id": rec.get("id"),
                    },
                )
                if rec.get("owner"):
                    task["owner"] = rec.get("owner")
                task["status"] = status
                task["updated_at"] = rec.get("ts")
                task["last_event_id"] = rec.get("id")
            events.append(
                {
                    "message_id": rec.get("id"),
                    "task_id": tid,
                    "message_type": msg_type,
                    "status": status,
                    "owner": rec.get("owner"),
                    "ts": rec.get("ts"),
                }
            )

        counts_by_owner: dict[str, dict[str, int]] = {}
        for task in tasks.values():
            owner = str(task.get("owner") or "unassigned")
            counts = counts_by_owner.setdefault(
                owner,
                {"open": 0, "in-progress": 0, "done": 0, "blocked": 0, "total": 0},
            )
            status = str(task.get("status") or "open")
            if status not in counts:
                counts[status] = 0
            counts[status] += 1
            counts["total"] += 1

        roster_order = [m["id"] for m in ROSTER if m.get("can_reply")] + ["unassigned"]
        ordered_counts = {
            owner: counts_by_owner.get(owner, {"open": 0, "in-progress": 0, "done": 0, "blocked": 0, "total": 0})
            for owner in roster_order
            if owner in counts_by_owner or owner != "unassigned"
        }
        for owner, counts in sorted(counts_by_owner.items()):
            if owner not in ordered_counts:
                ordered_counts[owner] = counts

        return {
            "tasks": sorted(tasks.values(), key=lambda t: str(t.get("updated_at") or "")),
            "counts_by_owner": ordered_counts,
            "events": events,
        }

    def update_record_delivery(self, msg_id: str, delivery: dict[str, Any]) -> bool:
        """Build 219 r4 item 2 — overwrite the delivery field of an existing record.

        Used by push.py `_group_fan_out` to persist the actual delivered / failed
        targets back to disk after Popen returns (the initial `append()` line had
        delivered=[] because fan-out hadn't run yet). Without this, the on-disk
        jsonl forever shows delivered=[] even when delivery succeeded.

        Rewrites the whole jsonl in place — fine for the workgroup scale
        (tens of records / day). For larger scale add an index.
        """
        if not self.path.exists():
            return False
        with self._lock:
            lines: list[str] = []
            found = False
            try:
                with open(self.path, encoding="utf-8") as f:
                    for line in f:
                        stripped = line.strip()
                        if not stripped:
                            continue
                        try:
                            rec = json.loads(stripped)
                        except json.JSONDecodeError:
                            lines.append(stripped)
                            continue
                        if rec.get("id") == msg_id:
                            rec["delivery"] = delivery
                            lines.append(json.dumps(rec, ensure_ascii=False))
                            found = True
                        else:
                            lines.append(stripped)
            except Exception:
                return False
            if not found:
                return False
            try:
                with open(self.path, "w", encoding="utf-8") as f:
                    for line in lines:
                        f.write(line + "\n")
            except Exception:
                return False
        return True

    def delete(self, msg_id: str) -> bool:
        """Delete a message by id. Rewrites jsonl in place."""
        if not self.path.exists():
            return False
        with self._lock:
            lines: list[str] = []
            found = False
            try:
                with open(self.path, encoding="utf-8") as f:
                    for line in f:
                        stripped = line.strip()
                        if not stripped:
                            continue
                        try:
                            rec = json.loads(stripped)
                        except json.JSONDecodeError:
                            lines.append(stripped)
                            continue
                        if rec.get("id") == msg_id:
                            found = True
                        else:
                            lines.append(stripped)
            except Exception:
                return False
            if not found:
                return False
            try:
                with open(self.path, "w", encoding="utf-8") as f:
                    for line in lines:
                        f.write(line + "\n")
            except Exception:
                return False
        return True

    def tail(self, limit: int = 20) -> list[dict[str, Any]]:
        return self.read_since(limit=limit)

    def context_lines(self, limit: int = 20) -> list[str]:
        # 2026-05-09 用户 catch fan-out 上下文里 codex tool trace (Explored / Ran / Edited / Searched / Read 等)
        # 历史 jsonl 已经存着旧污染 这一层二级 filter 拦不让进 fan-out context
        # only agent senders (non-human, non-primary) emit tool traces; skip otherwise
        TOOL_TRACE_PREFIXES = (
            "Explored",
            "Ran ", "Ran\n",
            "Read ", "Read\n",
            "Edited ", "Edited\n",
            "Wrote ", "Wrote\n",
            "Searched", "Searching",
            "Search ", "Search\n",
            "Created ", "Created\n",
            "Listed ", "List ",
            "Deleted ", "Updated ", "Patched ",
            "Bash(",
            "Added ", "Added\n",
            "Removed ", "Removed\n",
            "Modified ", "Modified\n",
            "Found ", "Fetched ",
            "Reading ", "Editing ", "Writing ", "Running ",
        )
        AGENT_SENDERS = {"shu", "sonnet", "opus47_fresh"}
        # 多拉一些 防 filter 后不足 limit 条
        raw_pull = max(limit * 3, 60)
        lines: list[str] = []
        for rec in self.tail(raw_pull):
            sender_id = rec.get("sender_id", "")
            text_raw = str(rec.get("text", "")).strip()
            # 二级 filter agent tool trace 跳过
            if sender_id in AGENT_SENDERS and text_raw.startswith(TOOL_TRACE_PREFIXES):
                continue
            sender = self.member(sender_id) or {}
            name = sender.get("display_name") or sender_id
            ts = str(rec.get("ts", ""))[11:16]
            text = text_raw.replace("\n", " ")
            if len(text) > 180:
                text = text[:177] + "..."
            lines.append(f"[{ts}] {name}: {text}")
            if len(lines) >= limit:
                break
        return lines

    def set_typing(self, agent_id: str, is_typing: bool, dispatch_id: str | None = None, *, status_text: str | None = None, save: bool = True):
        if agent_id not in ROSTER_BY_ID:
            return
        agents = self._state.setdefault("agents", {})
        state = agents.setdefault(agent_id, {})
        state["is_typing"] = bool(is_typing)
        state["typing_since"] = _now_iso() if is_typing else None
        if dispatch_id is not None:
            state["dispatch_id"] = dispatch_id
        # status_text: explicitly None = leave previous; "" = clear; else set
        if status_text is not None:
            state["status_text"] = status_text if status_text else None
        if not is_typing:
            state["last_seen"] = _now_iso()
            state["status_text"] = None
        if save:
            with self._lock:
                self._save_state()

    def status_snapshot(self, session_exists: Callable[[str], bool] | None = None) -> dict[str, Any]:
        agents: dict[str, Any] = {}
        state_agents = self._state.get("agents", {})
        now = datetime.now(timezone.utc).astimezone()
        changed = False
        for member in ROSTER:
            if member.get("kind") != "agent":
                continue
            agent_id = member["id"]
            tmux = member.get("tmux")
            online = bool(tmux and session_exists and session_exists(str(tmux)))
            stored = state_agents.get(agent_id, {})
            if stored.get("is_typing") and stored.get("typing_since"):
                typing_since = _parse_iso(str(stored.get("typing_since")))
                if typing_since and (now - typing_since).total_seconds() > 180:
                    stored["is_typing"] = False
                    stored["typing_since"] = None
                    changed = True
            agents[agent_id] = {
                "state": "online" if online else "offline",
                "tmux": tmux,
                "last_seen": stored.get("last_seen"),
                "is_typing": bool(stored.get("is_typing")),
                "typing_since": stored.get("typing_since"),
                "dispatch_id": stored.get("dispatch_id"),
                "status_text": stored.get("status_text"),
            }
        if changed:
            with self._lock:
                self._save_state()
        return {"agents": agents}
