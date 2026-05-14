"""Favorites store backed by JSONL with a vault markdown mirror."""
from __future__ import annotations

import html
import json
import logging
import re
import shutil
import threading
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any

import httpx


logger = logging.getLogger("opia-apns-server.favorites")

VALID_TYPES = {"text", "image", "link", "collection"}
TITLE_RE = re.compile(r"<title[^>]*>(.+?)</title>", re.IGNORECASE | re.DOTALL)
FAV_HEADING_RE = re.compile(r"(?m)^## (fav_\d+) \[.+?\]\s*$")


class Favorites:
    def __init__(self, jsonl_path: str | Path | None = None, vault_path: str | Path | None = None):
        self.jsonl_path = (
            Path(jsonl_path).expanduser()
            if jsonl_path is not None
            else Path("~/Opia/dynamic-island/apns-server/tokens/favorites.jsonl").expanduser()
        ).resolve()
        self.vault_path = (
            Path(vault_path).expanduser()
            if vault_path is not None
            else Path("~/Documents/星原/眠的小家/收藏夹/").expanduser()
        ).resolve()
        self._lock = threading.Lock()
        self.jsonl_path.parent.mkdir(parents=True, exist_ok=True)
        self.jsonl_path.touch(exist_ok=True)
        self.vault_path.mkdir(parents=True, exist_ok=True)
        self._ensure_inside_vault(self.vault_path)
        self._items: list[dict[str, Any]] = []
        self._next_id_n = 1
        self.reload()

    def add(
        self,
        type: str,
        source: str,
        refs: list[dict[str, Any]],
        tags: list[str] | None = None,
        note: str | None = None,
    ) -> dict[str, Any]:
        with self._lock:
            record = self._build_record(type, source, refs, tags, note)
            self._append_jsonl(record)
            self._items.append(record)
            self._write_markdown_item(record)
            return record

    def add_with_attachment(
        self,
        type: str,
        source: str,
        refs: list[dict[str, Any]],
        local_path: str | Path,
        tags: list[str] | None = None,
        note: str | None = None,
    ) -> dict[str, Any]:
        src = Path(local_path).expanduser().resolve()
        if not src.exists() or not src.is_file():
            raise ValueError(f"attachment local_path not found: {src}")
        ext = src.suffix.lower() or ".bin"
        attachments_dir = self.vault_path / "attachments"
        self._ensure_inside_vault(attachments_dir)
        attachments_dir.mkdir(parents=True, exist_ok=True)
        rel = Path("attachments") / f"{uuid.uuid4().hex}{ext}"
        dest = (self.vault_path / rel).resolve()
        self._ensure_inside_vault(dest)
        shutil.copy2(src, dest)
        refs_copy = [dict(ref) for ref in refs]
        if not refs_copy:
            raise ValueError("refs required")
        refs_copy[0]["attachment_url"] = str(rel)
        return self.add(type, source, refs_copy, tags=tags, note=note)

    def list(
        self,
        type: str | None = None,
        tag: str | None = None,
        q: str | None = None,
        limit: int = 50,
        offset: int = 0,
    ) -> list[dict[str, Any]]:
        with self._lock:
            items = list(reversed(self._items))
        if type:
            items = [item for item in items if item.get("type") == type]
        if tag:
            items = [item for item in items if tag in (item.get("tags") or [])]
        if q:
            needle = q.lower()
            items = [item for item in items if needle in self._haystack(item)]
        return items[max(offset, 0) : max(offset, 0) + max(limit, 0)]

    def get(self, id: str) -> dict[str, Any] | None:
        with self._lock:
            for item in self._items:
                if item.get("id") == id:
                    return dict(item)
        return None

    def edit(
        self,
        id: str,
        tags: list[str] | None = None,
        note: str | None = None,
    ) -> dict[str, Any] | None:
        with self._lock:
            for idx, item in enumerate(self._items):
                if item.get("id") != id:
                    continue
                updated = dict(item)
                if tags is not None:
                    updated["tags"] = [str(tag) for tag in tags]
                if note is not None:
                    updated["note"] = note
                self._items[idx] = updated
                self._rewrite_jsonl()
                self._replace_markdown_item(updated)
                return updated
        return None

    def delete(self, id: str) -> bool:
        with self._lock:
            target = None
            kept = []
            for item in self._items:
                if item.get("id") == id:
                    target = item
                else:
                    kept.append(item)
            if target is None:
                return False
            self._items = kept
            self._rewrite_jsonl()
            self._delete_markdown_item(target)
            self._delete_attachments(target)
            return True

    def reload(self) -> int:
        items: list[dict[str, Any]] = []
        max_id = 0
        if self.jsonl_path.exists():
            with self.jsonl_path.open("r", encoding="utf-8") as f:
                for line_no, line in enumerate(f, 1):
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        item = json.loads(line)
                    except Exception:
                        logger.warning("skip corrupted favorites jsonl line %d", line_no)
                        continue
                    if not isinstance(item, dict):
                        logger.warning("skip non-object favorites jsonl line %d", line_no)
                        continue
                    items.append(item)
                    max_id = max(max_id, self._id_number(item.get("id", "")))
        with self._lock:
            self._items = items
            self._next_id_n = max_id + 1
        return len(items)

    def _build_record(
        self,
        type: str,
        source: str,
        refs: list[dict[str, Any]],
        tags: list[str] | None,
        note: str | None,
    ) -> dict[str, Any]:
        self._validate(type, refs)
        refs_copy = [dict(ref) for ref in refs]
        if type == "link":
            url = refs_copy[0].get("url") or refs_copy[0].get("text")
            if not url:
                raise ValueError("link ref requires url")
            meta = self._extract_url_meta(str(url))
            refs_copy[0]["url"] = str(url)
            refs_copy[0].setdefault("title", meta["title"])
        record = {
            "id": self._next_id(),
            "created_at": datetime.now().astimezone().isoformat(timespec="milliseconds"),
            "type": type,
            "source": source,
            "refs": refs_copy,
            "tags": [str(tag) for tag in (tags or [])],
        }
        if note is not None:
            record["note"] = note
        return record

    def _validate(self, type: str, refs: list[dict[str, Any]]) -> None:
        if type not in VALID_TYPES:
            raise ValueError("type must be text, image, link, or collection")
        if not refs:
            raise ValueError("refs required")
        if type == "collection" and len(refs) < 2:
            raise ValueError("collection requires at least 2 refs")
        if type == "image" and not refs[0].get("attachment_url"):
            raise ValueError("image requires refs[0].attachment_url")

    def _next_id(self) -> str:
        n = self._next_id_n
        self._next_id_n += 1
        width = 3 if n < 1000 else len(str(n))
        return f"fav_{n:0{width}d}"

    def _id_number(self, value: str) -> int:
        match = re.match(r"^fav_(\d+)$", str(value))
        return int(match.group(1)) if match else 0

    def _append_jsonl(self, record: dict[str, Any]) -> None:
        with self.jsonl_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")

    def _rewrite_jsonl(self) -> None:
        tmp = self.jsonl_path.with_suffix(self.jsonl_path.suffix + ".tmp")
        with tmp.open("w", encoding="utf-8") as f:
            for item in self._items:
                f.write(json.dumps(item, ensure_ascii=False) + "\n")
        tmp.replace(self.jsonl_path)

    def _write_markdown_item(self, record: dict[str, Any]) -> None:
        path = self._month_path(record)
        self._ensure_inside_vault(path)
        if not path.exists():
            path.write_text("---\n---\n\n", encoding="utf-8")
        with path.open("a", encoding="utf-8") as f:
            f.write(self._render_markdown_item(record))

    def _replace_markdown_item(self, record: dict[str, Any]) -> None:
        path = self._month_path(record)
        if not path.exists():
            self._write_markdown_item(record)
            return
        content = path.read_text(encoding="utf-8")
        new_content, replaced = self._replace_item_block(content, record["id"], self._render_markdown_item(record))
        if not replaced:
            new_content = content.rstrip() + "\n\n" + self._render_markdown_item(record)
        self._atomic_write(path, new_content)

    def _delete_markdown_item(self, record: dict[str, Any]) -> None:
        path = self._month_path(record)
        if not path.exists():
            return
        content = path.read_text(encoding="utf-8")
        new_content, _ = self._replace_item_block(content, record["id"], "")
        self._atomic_write(path, new_content.rstrip() + "\n")

    def _replace_item_block(self, content: str, id: str, replacement: str) -> tuple[str, bool]:
        matches = list(FAV_HEADING_RE.finditer(content))
        for idx, match in enumerate(matches):
            if match.group(1) != id:
                continue
            start = match.start()
            end = matches[idx + 1].start() if idx + 1 < len(matches) else len(content)
            prefix = content[:start].rstrip() + "\n\n"
            suffix = content[end:].lstrip("\n")
            if replacement:
                return prefix + replacement + suffix, True
            return prefix + suffix, True
        return content, False

    def _atomic_write(self, path: Path, content: str) -> None:
        self._ensure_inside_vault(path)
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(content, encoding="utf-8")
        tmp.replace(path)

    def _delete_attachments(self, record: dict[str, Any]) -> None:
        for ref in record.get("refs") or []:
            attachment_url = str(ref.get("attachment_url") or "")
            if not attachment_url.startswith("attachments/"):
                continue
            path = (self.vault_path / attachment_url).resolve()
            self._ensure_inside_vault(path)
            if path.exists() and path.is_file():
                path.unlink()

    def _month_path(self, record: dict[str, Any]) -> Path:
        created = datetime.fromisoformat(record["created_at"])
        return (self.vault_path / f"{created:%Y-%m}.md").resolve()

    def _ensure_inside_vault(self, path: Path) -> None:
        resolved = path.resolve()
        try:
            resolved.relative_to(self.vault_path)
        except ValueError:
            raise ValueError("path outside favorites vault")

    def _haystack(self, item: dict[str, Any]) -> str:
        parts = [str(item.get("note") or "")]
        for ref in item.get("refs") or []:
            parts.extend(str(ref.get(key) or "") for key in ("text", "title", "url"))
        return "\n".join(parts).lower()

    def _extract_url_meta(self, url: str) -> dict[str, str]:
        try:
            resp = httpx.get(url, timeout=5.0, follow_redirects=True)
            text = resp.text
            match = TITLE_RE.search(text)
            if match:
                title = html.unescape(re.sub(r"\s+", " ", match.group(1)).strip())
                return {"title": title or url}
        except Exception:
            pass
        return {"title": url}

    def _render_markdown_item(self, record: dict[str, Any]) -> str:
        created = datetime.fromisoformat(record["created_at"])
        refs = record.get("refs") or []
        lines = [f"## {record['id']} [{created:%Y-%m-%d %H:%M}]"]
        lines.append(f"来源: {record.get('source', '')} / {self._source_label(record)}")
        lines.append(f"原文 ts: {self._ts_range(refs)}")
        lines.append(f"tags: [{', '.join(record.get('tags') or [])}]")
        lines.append("")
        if record.get("type") == "image":
            attachment = refs[0].get("attachment_url", "")
            if attachment:
                lines.append(f"![]({attachment})")
        elif record.get("type") == "link":
            ref = refs[0]
            title = ref.get("title") or ref.get("url") or ref.get("text") or ""
            url = ref.get("url") or ref.get("text") or ""
            lines.append(f"[{title}]({url})")
        for ref in refs:
            text = str(ref.get("text") or "").replace("\n", " ")
            if text:
                lines.append(f"> {self._role_name(ref.get('role'))} {text} ({self._ref_time(ref)})")
        if record.get("note"):
            lines.append("")
            lines.append(f"note: {record['note']}")
        return "\n".join(lines).rstrip() + "\n\n"

    def _parse_markdown_items(self, content: str) -> list[dict[str, Any]]:
        matches = list(FAV_HEADING_RE.finditer(content))
        items: list[dict[str, Any]] = []
        for idx, match in enumerate(matches):
            end = matches[idx + 1].start() if idx + 1 < len(matches) else len(content)
            items.append({"id": match.group(1), "markdown": content[match.start() : end].strip()})
        return items

    def _source_label(self, record: dict[str, Any]) -> str:
        type = record.get("type")
        refs = record.get("refs") or []
        if type == "collection":
            return f"合并 {len(refs)} 条"
        if type == "image":
            return "图"
        if type == "link":
            return "链接"
        return "单条"

    def _ts_range(self, refs: list[dict[str, Any]]) -> str:
        if not refs:
            return ""
        first = self._ref_time(refs[0])
        last = self._ref_time(refs[-1])
        return first if len(refs) == 1 else f"{first} -> {last}"

    def _ref_time(self, ref: dict[str, Any]) -> str:
        ts = ref.get("ts")
        if not ts:
            return ""
        try:
            return datetime.fromisoformat(str(ts)).strftime("%H:%M")
        except Exception:
            match = re.search(r"(\d{2}):(\d{2})", str(ts))
            return match.group(0) if match else str(ts)

    def _role_name(self, role: Any) -> str:
        if role == "user":
            return "用户"
        if role == "assistant":
            return "Opia"
        return str(role or "")
