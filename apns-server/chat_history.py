"""
Chat history store — append-only JSONL

每条 schema:
{
  "ts": "2026-04-30T12:50:00.123",
  "role": "user" | "assistant",
  "text": "...",
  "source": "ios-app",
  "location": {"lat": 31.234, "lon": 121.456}  # optional
}

iPhone 客户端 polling GET /chat/history?since=<ts>
server append on POST /chat/send (user) 和 /chat/append (assistant from bus_stop_hook)
"""
from __future__ import annotations

import json
import logging
import threading
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


logger = logging.getLogger("opia-apns-server.chat_history")


class EphemeralTaskBuffer:
    """In-memory task capsule buffer. Not persisted; reset on server restart."""

    def __init__(self, capacity: int = 100):
        self._buf: deque[dict[str, Any]] = deque(maxlen=capacity)
        self._lock = threading.Lock()

    def append(self, text: str, source: str = "claude-code") -> dict[str, Any]:
        from datetime import timedelta

        tz = timezone(timedelta(hours=8))
        ts = datetime.now(tz).isoformat(timespec="milliseconds")
        rec: dict[str, Any] = {
            "ts": ts,
            "role": "task",
            "text": text,
            "source": source,
            "id": ts,
        }
        with self._lock:
            self._buf.append(rec)
        return rec

    def list_since(self, since_ts: str | None = None) -> list[dict[str, Any]]:
        with self._lock:
            snap = list(self._buf)
        if since_ts:
            snap = [r for r in snap if r["ts"] > since_ts]
        return snap

    def list_all(self) -> list[dict[str, Any]]:
        with self._lock:
            return list(self._buf)


class ChatHistory:
    def __init__(self, path: str | Path):
        self.path = Path(path).expanduser()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()

    def append(
        self,
        role: str,
        text: str,
        source: str = "ios-app",
        quoted_ts: str | None = None,
        attachment_url: str | None = None,
        attachment_type: str | None = None,
        attachment_filename: str | None = None,
        location: dict[str, Any] | None = None,
        metadata: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        rec: dict[str, Any] = {
            "ts": datetime.now(timezone.utc).astimezone().isoformat(timespec="milliseconds"),
            "role": role,
            "text": text,
            "source": source,
            "audio_zh": None,
            "audio_en": None,
            "audio_ja": None,
        }
        if quoted_ts:
            rec["quoted_ts"] = quoted_ts
            quoted_text = self._lookup_text(quoted_ts)
            if quoted_text is not None:
                rec["quoted_text"] = quoted_text[:120]
        if attachment_url:
            rec["attachment_url"] = attachment_url
        if attachment_type:
            rec["attachment_type"] = attachment_type  # "image" | "file"
        if attachment_filename:
            rec["attachment_filename"] = attachment_filename
        if location:
            loc_clean = self._clean_location(location)
            if loc_clean:
                rec["location"] = loc_clean
        if metadata and isinstance(metadata, dict):
            rec["metadata"] = metadata
        with self._lock:
            with self.path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        return rec

    def _clean_location(self, loc: dict[str, Any]) -> dict[str, Any] | None:
        try:
            out: dict[str, Any] = {
                "lat": float(loc["lat"]),
                "lon": float(loc["lon"]),
            }
            if "accuracy" in loc and loc["accuracy"] is not None:
                out["accuracy"] = float(loc["accuracy"])
            if "label" in loc and loc["label"]:
                out["label"] = str(loc["label"])[:200]
            if not (-90.0 <= out["lat"] <= 90.0):
                return None
            if not (-180.0 <= out["lon"] <= 180.0):
                return None
            return out
        except Exception:
            return None

    def update_audio(
        self,
        ts: str,
        audio_zh: str | None = None,
        audio_en: str | None = None,
        audio_ja: str | None = None,
    ) -> bool:
        """Update multilingual TTS URLs for one record. None means leave unchanged."""
        updates = {
            key: value
            for key, value in {
                "audio_zh": audio_zh,
                "audio_en": audio_en,
                "audio_ja": audio_ja,
            }.items()
            if value is not None
        }
        if not updates:
            return False
        if not self.path.exists():
            logger.warning("update_audio skip: history missing")
            return False
        try:
            with self._lock:
                lines = self.path.read_text(encoding="utf-8").splitlines()
                kept: list[str] = []
                ok = False
                for line in lines:
                    if not line.strip():
                        continue
                    try:
                        rec = json.loads(line)
                    except Exception:
                        kept.append(line)
                        continue
                    if rec.get("ts") == ts:
                        rec.update(updates)
                        ok = True
                    kept.append(json.dumps(rec, ensure_ascii=False))
                if ok:
                    tmp = self.path.with_suffix(self.path.suffix + ".tmp")
                    tmp.write_text("\n".join(kept) + "\n", encoding="utf-8")
                    tmp.replace(self.path)
                else:
                    logger.warning("update_audio skip: ts not found")
                return ok
        except Exception as e:
            logger.warning("update_audio fail: %s", e)
            return False

    def update_audio_url(self, ts: str, audio_url: str) -> bool:
        """Backward-compatible single URL updater."""
        return self.update_audio(ts, audio_zh=audio_url)

    def _lookup_text(self, ts: str) -> str | None:
        if not self.path.exists():
            return None
        with self.path.open("r", encoding="utf-8") as f:
            for line in f:
                try:
                    rec = json.loads(line.strip())
                except Exception:
                    continue
                if rec.get("ts") == ts:
                    return rec.get("text", "")
        return None

    def read_since(self, since_ts: str | None = None, before_ts: str | None = None, limit: int = 10000, include_hidden: bool = False) -> list[dict[str, Any]]:
        """since_ts 之后 + before_ts 之前 (二者皆 optional).
        include_hidden=False (默认) 过滤掉 hidden_in_ui=True 的 record (重新发言覆盖那条)."""
        if not self.path.exists():
            return []
        out: list[dict[str, Any]] = []
        with self._lock:
            with self.path.open("r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    ts = rec.get("ts", "")
                    if since_ts and ts <= since_ts:
                        continue
                    if before_ts and ts >= before_ts:
                        continue
                    if not include_hidden and rec.get("hidden_in_ui"):
                        continue
                    out.append(rec)
        # before_ts 模式 (向上翻页) 取最末 N 条 = 最靠近 before_ts 的旧消息
        # 默认模式 (since_ts 之后或全量) 取最末 N 条 = 最新
        return out[-limit:]

    def tail(self, n: int = 50) -> list[dict[str, Any]]:
        return self.read_since(since_ts=None, limit=n)

    def read_around(self, ts: str, n: int = 25) -> list[dict[str, Any]]:
        """围绕指定 ts 取前 n + 后 n 条 (含目标本身). 2026-05-07 用户 push 跳原文用."""
        if not self.path.exists() or not ts:
            return []
        all_recs: list[dict[str, Any]] = []
        with self._lock:
            with self.path.open("r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    all_recs.append(rec)
        # 找目标 idx (按 ts 匹配 找最近的)
        target_idx = -1
        for i, rec in enumerate(all_recs):
            if rec.get("ts", "") == ts:
                target_idx = i
                break
        if target_idx < 0:
            # 没找到精确匹配 找最近的 ts (按字典序最接近)
            for i, rec in enumerate(all_recs):
                rec_ts = rec.get("ts", "")
                if rec_ts >= ts:
                    target_idx = i
                    break
            if target_idx < 0:
                target_idx = len(all_recs) - 1
        lo = max(0, target_idx - n)
        hi = min(len(all_recs), target_idx + n + 1)
        return all_recs[lo:hi]

    def list_for_date(self, date: str) -> list[dict[str, Any]]:
        """读 jsonl 全部 filter ts 起头匹配 date (YYYY-MM-DD prefix)."""
        if not self.path.exists():
            return []
        out: list[dict[str, Any]] = []
        with self._lock:
            with self.path.open("r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    if rec.get("ts", "").startswith(date):
                        out.append(rec)
        return out

    def search(
        self,
        keyword: str | None = None,
        date_prefix: str | None = None,
        role: str | None = None,
        limit: int = 5000,
    ) -> list[dict[str, Any]]:
        """关键字 + 日期 (YYYY-MM-DD) + role 过滤 — 都 optional 任意组合"""
        if not self.path.exists():
            return []
        keyword_lower = keyword.lower() if keyword else None
        out: list[dict[str, Any]] = []
        with self._lock:
            with self.path.open("r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                    except Exception:
                        continue
                    if date_prefix and not rec.get("ts", "").startswith(date_prefix):
                        continue
                    if role and rec.get("role") != role:
                        continue
                    if keyword_lower:
                        text = rec.get("text", "") or ""
                        filename = rec.get("attachment_filename", "") or ""
                        haystack = (text + " " + filename).lower()
                        if keyword_lower not in haystack:
                            continue
                    out.append(rec)
        # 2026-05-07 用户 catch 搜索结果应该最新在顶 reverse 后取 limit
        return list(reversed(out[-limit:]))

    def attach_audio(self, ts: str, filename: str) -> bool:
        """异步 TTS 生成完后 把 audio 附加到指定 ts 的 record (rewrite jsonl)"""
        if not self.path.exists():
            return False
        ok = False
        with self._lock:
            with self.path.open("r", encoding="utf-8") as f:
                lines = f.readlines()
            kept: list[str] = []
            for line in lines:
                stripped = line.strip()
                if not stripped:
                    continue
                try:
                    rec = json.loads(stripped)
                except Exception:
                    kept.append(line)
                    continue
                if rec.get("ts") == ts and not rec.get("attachment_url"):
                    rec["attachment_url"] = f"/attachments/{filename}"
                    rec["attachment_type"] = "audio"
                    rec["attachment_filename"] = filename
                    kept.append(json.dumps(rec, ensure_ascii=False) + "\n")
                    ok = True
                else:
                    kept.append(line)
            if ok:
                with self.path.open("w", encoding="utf-8") as f:
                    f.writelines(kept)
        return ok

    def add_reaction(self, ts: str, emoji: str) -> bool:
        """给某条加 reaction (rewrite jsonl) — 同 emoji 重复添加视为去除 (toggle)"""
        if not self.path.exists():
            return False
        toggled = False
        with self._lock:
            with self.path.open("r", encoding="utf-8") as f:
                lines = f.readlines()
            kept: list[str] = []
            for line in lines:
                stripped = line.strip()
                if not stripped:
                    continue
                try:
                    rec = json.loads(stripped)
                except Exception:
                    kept.append(line)
                    continue
                if rec.get("ts") == ts:
                    reactions: list[str] = rec.get("reactions") or []
                    if emoji in reactions:
                        reactions.remove(emoji)
                    else:
                        reactions.append(emoji)
                    if reactions:
                        rec["reactions"] = reactions
                    elif "reactions" in rec:
                        del rec["reactions"]
                    kept.append(json.dumps(rec, ensure_ascii=False) + "\n")
                    toggled = True
                else:
                    kept.append(line)
            if toggled:
                with self.path.open("w", encoding="utf-8") as f:
                    f.writelines(kept)
        return toggled

    def mark_regenerated(self, old_ts: str, new_ts: str | None = None) -> bool:
        """标记 old_ts 这条 assistant msg 为 regenerated 加 hidden_in_ui (UI 默认不展示但 jsonl 留备查).
        2026-05-08 用户 push 重新发言功能 — 旧消息直接覆盖 UI 不展示旧版."""
        if not self.path.exists() or not old_ts:
            return False
        marked = False
        with self._lock:
            with self.path.open("r", encoding="utf-8") as f:
                lines = f.readlines()
            new_lines: list[str] = []
            for line in lines:
                stripped = line.strip()
                if not stripped:
                    new_lines.append(line)
                    continue
                try:
                    rec = json.loads(stripped)
                except Exception:
                    new_lines.append(line)
                    continue
                if rec.get("ts") == old_ts and not marked:
                    rec["hidden_in_ui"] = True
                    rec["regenerated_at"] = datetime.now(timezone.utc).isoformat(timespec="milliseconds")
                    if new_ts:
                        rec["regenerated_to"] = new_ts
                    marked = True
                    new_lines.append(json.dumps(rec, ensure_ascii=False) + "\n")
                else:
                    new_lines.append(line)
            if marked:
                with self.path.open("w", encoding="utf-8") as f:
                    f.writelines(new_lines)
        return marked

    def delete(self, ts: str) -> bool:
        """按 ts 精确删一条 (rewrite jsonl). 返回是否找到并删除"""
        if not self.path.exists():
            return False
        deleted = False
        with self._lock:
            with self.path.open("r", encoding="utf-8") as f:
                lines = f.readlines()
            kept: list[str] = []
            for line in lines:
                stripped = line.strip()
                if not stripped:
                    continue
                try:
                    rec = json.loads(stripped)
                except Exception:
                    kept.append(line)
                    continue
                if rec.get("ts") == ts and not deleted:
                    deleted = True
                    continue
                kept.append(line)
            if deleted:
                with self.path.open("w", encoding="utf-8") as f:
                    f.writelines(kept)
        return deleted
