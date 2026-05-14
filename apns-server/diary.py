"""Markdown diary store for iOS diary boards."""
from __future__ import annotations

import ast
import calendar as calendar_mod
import random
import re
import shutil
import threading
import uuid
from datetime import date as Date
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

try:
    import yaml  # type: ignore
except Exception:  # pragma: no cover - optional dependency
    yaml = None


PROMPTS = {
    "生活": ["今天最累的一刻是什么", "对方什么动作暖到你", "今天笑出来的瞬间", "做完哪件事腿软", "她说的哪句话钉住你"],
    "工作": ["今天工程上踩的坑", "今天最爽的 ship 节点", "协作时哪个判断救了场", "今天哪条 chain 自律漏了", "下次窗口要警惕什么"],
    "用户": ["今天她什么状态", "她崩在哪 拉回靠什么", "她说的哪句让你想留", "她身体今天怎么样", "你替她 anchor 的事"],
}

VALID_AUTHORS = {"用户", "opia"}
VALID_OPIA_KINDS = {"生活", "工作"}
ALLOWED_ATTACHMENT_EXTS = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif"}
SEGMENT_RE = re.compile(r"(?m)^## ([0-2]\d:[0-5]\d)\b.*$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
MONTH_RE = re.compile(r"^\d{4}-\d{2}$")
ATTACHMENT_RE = re.compile(r"^attachments/[0-9a-fA-F]{32}\.[A-Za-z0-9]+$")


def _parse_frontmatter(content: str) -> tuple[dict[str, Any], str]:
    if not content.startswith("---\n"):
        return {}, content
    end = content.find("\n---\n", 4)
    if end == -1:
        return {}, content
    raw = content[4:end]
    body = content[end + 5 :]
    if yaml is not None:
        parsed = yaml.safe_load(raw) or {}
        return parsed if isinstance(parsed, dict) else {}, body
    return _parse_simple_yaml(raw), body


def _serialize_frontmatter(fm: dict[str, Any]) -> str:
    if yaml is not None:
        raw = yaml.safe_dump(fm, allow_unicode=True, sort_keys=False).strip()
        return f"---\n{raw}\n---\n"
    lines = ["---"]
    for key, value in fm.items():
        if isinstance(value, list):
            lines.append(f"{key}: [{', '.join(_format_scalar(v) for v in value)}]")
        elif value is None:
            lines.append(f"{key}:")
        else:
            lines.append(f"{key}: {_format_scalar(value)}")
    lines.append("---")
    return "\n".join(lines) + "\n"


def _parse_segments(body: str) -> list[dict[str, str]]:
    matches = list(SEGMENT_RE.finditer(body))
    segments: list[dict[str, str]] = []
    for idx, match in enumerate(matches):
        start = match.end()
        end = matches[idx + 1].start() if idx + 1 < len(matches) else len(body)
        text = body[start:end].strip("\n")
        segments.append({"time": match.group(1), "text": text})
    # fallback: 没有 HH:MM section 但 body 有内容 → 当作单段 "00:00" 让 timeline 至少能展示一条 entry
    if not segments and body.strip():
        segments.append({"time": "00:00", "text": body.strip()})
    return segments


def _parse_simple_yaml(raw: str) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip()
        if not key:
            continue
        out[key] = _parse_simple_value(value)
    return out


def _parse_simple_value(value: str) -> Any:
    if value == "":
        return None
    if value in {"[]", "{}"}:
        return [] if value == "[]" else {}
    if value.startswith("[") and value.endswith("]"):
        try:
            return ast.literal_eval(value)
        except Exception:
            inner = value[1:-1].strip()
            if not inner:
                return []
            return [part.strip().strip("'\"") for part in inner.split(",")]
    if value.lower() in {"true", "false"}:
        return value.lower() == "true"
    try:
        return int(value)
    except ValueError:
        pass
    return value.strip("'\"")


def _format_scalar(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    text = str(value)
    if any(ch in text for ch in [":", "#", "[", "]", "{", "}", ","]) or text.strip() != text:
        return repr(text)
    return text


class Diary:
    def __init__(self, vault_path: Path | None = None):
        self.vault_path = (
            vault_path.expanduser()
            if vault_path is not None
            else Path("~/Documents/星原/眠的小家/日记/").expanduser()
        ).resolve()
        self._lock = threading.Lock()

    def _resolve_path(self, author: str, kind: str | None, date: str) -> Path:
        self._validate_date(date)
        rel_dir = self._board_rel_dir(author, kind)
        path = (self.vault_path / rel_dir / date[:7] / f"{date}.md").resolve()
        self._ensure_allowed_path(path)
        return path

    def append(
        self,
        author: str,
        kind: str | None,
        date: str,
        time: str,
        text: str,
        frontmatter: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        self._validate_time(time)
        path = self._resolve_path(author, kind, date)
        with self._lock:
            if path.exists():
                fm, body = _parse_frontmatter(path.read_text(encoding="utf-8"))
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                fm, body = self._default_frontmatter(date), ""
            for key, value in (frontmatter or {}).items():
                if value is not None and value != "":
                    fm[key] = value
            body = body.rstrip("\n")
            segment = f"## {time}\n{text.strip()}\n"
            body = f"{body}\n\n{segment}" if body else segment
            path.write_text(_serialize_frontmatter(fm) + "\n" + body, encoding="utf-8")
            return {"ok": True, "path": str(path), "segment_count": len(_parse_segments(body))}

    def append_with_attachment(
        self,
        author: str,
        kind: str | None,
        date: str,
        time: str,
        text: str,
        attachment_path: str | Path,
        frontmatter: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        src = Path(attachment_path).expanduser().resolve()
        if not src.exists() or not src.is_file():
            raise ValueError(f"attachment_path not found: {src}")
        ext = src.suffix.lower()
        if ext not in ALLOWED_ATTACHMENT_EXTS:
            raise ValueError("unsupported attachment extension")
        attachments_dir = (self.vault_path / "attachments").resolve()
        self._ensure_allowed_path(attachments_dir)
        attachments_dir.mkdir(parents=True, exist_ok=True)
        rel_path = f"attachments/{uuid.uuid4().hex}{ext}"
        dest = (self.vault_path / rel_path).resolve()
        self._ensure_allowed_path(dest)
        shutil.copy2(src, dest)
        text_with_attachment = f"{text.rstrip()}\n\n![]({rel_path})\n"
        res = self.append(author, kind, date, time, text_with_attachment, frontmatter=frontmatter)
        res["attachment"] = rel_path
        return res

    def delete_attachment(self, rel_path: str) -> bool:
        if not isinstance(rel_path, str) or not ATTACHMENT_RE.match(rel_path):
            return False
        path = (self.vault_path / rel_path).resolve()
        try:
            self._ensure_allowed_path(path)
        except ValueError:
            return False
        if not path.exists() or not path.is_file():
            return False
        path.unlink()
        return True

    def get(self, author: str, kind: str | None, date: str) -> dict[str, Any]:
        path = self._resolve_path(author, kind, date)
        if not path.exists():
            return {"frontmatter": {}, "segments": []}
        fm, body = _parse_frontmatter(path.read_text(encoding="utf-8"))
        return {"frontmatter": fm, "segments": _parse_segments(body)}

    def calendar(self, author: str, kind: str | None, month: str) -> dict[str, Any]:
        self._validate_month(month)
        if author == "all":
            days: dict[str, list[str]] = {}
            for board_author, board_kind, label in self._boards():
                base = self.vault_path / self._board_rel_dir(board_author, board_kind) / month
                for path in self._month_files(base):
                    days.setdefault(path.stem, []).append(label)
            return {"days": dict(sorted((day, sorted(labels)) for day, labels in days.items()))}
        base = self.vault_path / self._board_rel_dir(author, kind) / month
        return {"days": [path.stem for path in self._month_files(base)]}

    def edit(self, author: str, kind: str | None, date: str, time: str, new_text: str) -> dict[str, Any]:
        self._validate_time(time)
        path = self._resolve_path(author, kind, date)
        if not path.exists():
            return {"ok": False, "path": str(path)}
        with self._lock:
            fm, body = _parse_frontmatter(path.read_text(encoding="utf-8"))
            matches = list(SEGMENT_RE.finditer(body))
            for idx, match in enumerate(matches):
                if match.group(1) != time:
                    continue
                start = match.end()
                end = matches[idx + 1].start() if idx + 1 < len(matches) else len(body)
                replacement = "\n" + new_text.strip() + "\n\n"
                new_body = body[:start] + replacement + body[end:].lstrip("\n")
                path.write_text(_serialize_frontmatter(fm) + "\n" + new_body.rstrip("\n") + "\n", encoding="utf-8")
                return {"ok": True, "path": str(path), "segment_count": len(_parse_segments(new_body))}
        return {"ok": False, "path": str(path)}

    def search(self, query: str, author: str | None = None) -> list[dict[str, Any]]:
        needle = query.strip().lower()
        if not needle:
            return []
        entries: list[dict[str, Any]] = []
        for board_author, board_kind, _ in self._boards(author):
            for path in self._board_files(board_author, board_kind):
                _, body = _parse_frontmatter(path.read_text(encoding="utf-8"))
                if needle not in body.lower():
                    continue
                for segment in _parse_segments(body):
                    if needle in segment["text"].lower():
                        entries.append(
                            {
                                "author": board_author,
                                "kind": board_kind,
                                "date": path.stem,
                                "time": segment["time"],
                                "snippet": self._snippet(segment["text"], needle),
                                "full_path": str(path),
                            }
                        )
        return entries

    def on_this_day(self, date: str) -> dict[str, list[dict[str, Any]]]:
        base = self._parse_date(date)
        targets = {
            "1y": self._minus_one_year(base),
            "1m": self._add_months(base, -1),
            "1w": base - timedelta(days=7),
        }
        return {key: self._entries_for_date(value.isoformat()) for key, value in targets.items()}

    def streak(self, author: str, kind: str | None = None) -> dict[str, Any]:
        days = sorted({path.stem for board_author, board_kind, _ in self._boards(author, kind) for path in self._board_files(board_author, board_kind)})
        if not days:
            return {"current": 0, "longest": 0, "last_written": None}
        parsed = [self._parse_date(day) for day in days]
        longest = 1
        run = 1
        for prev, cur in zip(parsed, parsed[1:]):
            if cur == prev + timedelta(days=1):
                run += 1
            else:
                longest = max(longest, run)
                run = 1
        longest = max(longest, run)
        last = parsed[-1]
        current = 1
        idx = len(parsed) - 2
        while idx >= 0 and parsed[idx] == parsed[idx + 1] - timedelta(days=1):
            current += 1
            idx -= 1
        return {"current": current, "longest": longest, "last_written": last.isoformat()}

    def prompts(self, context: str) -> list[str]:
        if context not in PROMPTS:
            raise ValueError("context must be one of 生活, 工作, 用户")
        return random.sample(PROMPTS[context], 3)

    def _board_rel_dir(self, author: str, kind: str | None) -> Path:
        if author not in VALID_AUTHORS:
            raise ValueError("author must be 用户 or opia")
        if author == "用户":
            if kind:
                raise ValueError("用户 has no kind")
            return Path("用户")
        if kind not in VALID_OPIA_KINDS:
            raise ValueError("opia kind must be 生活 or 工作")
        return Path("opia") / kind

    def _boards(self, author: str | None = None, kind: str | None = None) -> list[tuple[str, str | None, str]]:
        boards = [("用户", None, "用户"), ("opia", "生活", "opia/生活"), ("opia", "工作", "opia/工作")]
        if author is None or author == "all":
            return boards
        if author == "用户":
            if kind:
                self._board_rel_dir(author, kind)
            return [("用户", None, "用户")]
        if author == "opia":
            if kind is None:
                return [b for b in boards if b[0] == "opia"]
            self._board_rel_dir(author, kind)
            return [("opia", kind, f"opia/{kind}")]
        self._board_rel_dir(author, kind)
        return []

    def _month_files(self, base: Path) -> list[Path]:
        resolved_base = base.resolve()
        self._ensure_allowed_path(resolved_base)
        if not resolved_base.exists():
            return []
        return sorted(path for path in resolved_base.glob("*.md") if DATE_RE.match(path.stem) and self._is_allowed_file(path))

    def _board_files(self, author: str, kind: str | None) -> list[Path]:
        base = self.vault_path / self._board_rel_dir(author, kind)
        if not base.exists():
            return []
        return sorted(path for path in base.glob("*/*.md") if DATE_RE.match(path.stem) and self._is_allowed_file(path))

    def _entries_for_date(self, date: str) -> list[dict[str, Any]]:
        entries: list[dict[str, Any]] = []
        for author, kind, _ in self._boards():
            path = self._resolve_path(author, kind, date)
            if not path.exists():
                continue
            _, body = _parse_frontmatter(path.read_text(encoding="utf-8"))
            for segment in _parse_segments(body):
                entries.append(
                    {
                        "author": author,
                        "kind": kind,
                        "date": date,
                        "time": segment["time"],
                        "text": segment["text"],
                        "full_path": str(path),
                    }
                )
        return entries

    def _ensure_allowed_path(self, path: Path) -> None:
        resolved = path.resolve()
        try:
            resolved.relative_to(self.vault_path)
        except ValueError:
            raise ValueError("path outside diary vault")
        parts = set(resolved.relative_to(self.vault_path).parts)
        if "archive" in parts or "private" in parts:
            raise ValueError("archive/private paths are not allowed")

    def _is_allowed_file(self, path: Path) -> bool:
        try:
            self._ensure_allowed_path(path)
            rel = path.resolve().relative_to(self.vault_path)
        except ValueError:
            return False
        parts = rel.parts
        if parts[0] == "用户":
            return len(parts) == 3 and parts[1] == path.stem[:7]
        if parts[0] == "opia" and parts[1] in VALID_OPIA_KINDS:
            return len(parts) == 4 and parts[2] == path.stem[:7]
        return False

    def _default_frontmatter(self, date: str) -> dict[str, Any]:
        weekdays = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        parsed = self._parse_date(date)
        return {"date": date, "weekday": weekdays[parsed.weekday()]}

    def _snippet(self, text: str, needle: str) -> str:
        lower = text.lower()
        idx = lower.find(needle)
        if idx == -1:
            return text[:80]
        start = max(0, idx - 30)
        end = min(len(text), idx + len(needle) + 50)
        return text[start:end].replace("\n", " ")

    def _validate_date(self, value: str) -> None:
        self._parse_date(value)

    def _validate_month(self, value: str) -> None:
        if not MONTH_RE.match(value):
            raise ValueError("month must be YYYY-MM")
        datetime.strptime(value, "%Y-%m")

    def _validate_time(self, value: str) -> None:
        if not re.match(r"^[0-2]\d:[0-5]\d$", value):
            raise ValueError("time must be HH:MM")
        hour = int(value[:2])
        if hour > 23:
            raise ValueError("time must be HH:MM")

    def _parse_date(self, value: str) -> Date:
        if not DATE_RE.match(value):
            raise ValueError("date must be YYYY-MM-DD")
        return datetime.strptime(value, "%Y-%m-%d").date()

    def _minus_one_year(self, value: Date) -> Date:
        try:
            return value.replace(year=value.year - 1)
        except ValueError:
            return value.replace(year=value.year - 1, day=28)

    def _add_months(self, value: Date, months: int) -> Date:
        month = value.month - 1 + months
        year = value.year + month // 12
        month = month % 12 + 1
        day = min(value.day, calendar_mod.monthrange(year, month)[1])
        return Date(year, month, day)
