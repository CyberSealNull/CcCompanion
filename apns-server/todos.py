"""读 vault 里几个 todo md 文件 parse 成结构化 todo 列表"""
from __future__ import annotations

import os
import re
import shutil
from datetime import datetime
from pathlib import Path
from threading import Lock

VAULT = Path(os.path.expanduser("~/Documents/星原"))

TODO_SOURCES = [
    {
        "section": "进行中",
        "path": VAULT / "眠的小家/AI的记忆/日常/进行中事项.md",
    },
    {
        "section": "工作",
        "path": VAULT / "工作/工作待办/总览.md",
    },
    {
        "section": "生活",
        "path": VAULT / "生活/生活待办/个人inbox待办.md",
    },
    {
        "section": "AI",
        "path": VAULT / "眠的小家/AI的记忆/日常/AI协作迭代记录.md",
    },
    {
        "section": "项目",
        "path": VAULT / "工作/工作待办/项目.md",
    },
]

# 匹配: - [ ] / - [x] / - [X] / - [❓] 行
TODO_RE = re.compile(r"^\s*-\s*\[([\sxX❓✓])\]\s*(.+?)\s*$", re.UNICODE)
# 匹配子项 actor [Opia] / [User]
ACTOR_RE = re.compile(r"^\[([^\]]+)\]\s*(.+)$")

PRIORITY_RE = re.compile(r'(?:!p([123])|(?<![a-zA-Z])#p([123]))(?![a-zA-Z0-9])', re.IGNORECASE)
DUEDATE_RE = re.compile(r'@(\d{4}-\d{2}-\d{2})|📅\s*(\d{4}-\d{2}-\d{2})')
TAG_RE = re.compile(r'(?<![a-zA-Z])#([a-zA-Z一-鿿][a-zA-Z0-9一-鿿_-]*)(?![a-zA-Z0-9])')

ALLOWED_PATHS = {src["path"].resolve(): src["section"] for src in TODO_SOURCES}
BACKUP_DIR = Path("~/Opia/dynamic-island/apns-server/tokens/todos_backup").expanduser()
_WRITE_LOCK = Lock()


def parse_file(path: Path) -> list[dict]:
    if not path.exists():
        return []
    items: list[dict] = []
    current_heading = ""
    try:
        text = path.read_text(encoding="utf-8")
    except Exception:
        return []
    for line_idx, raw in enumerate(text.splitlines()):
        line = raw.rstrip()
        if line.startswith("##"):
            current_heading = line.lstrip("#").strip()
            continue
        m = TODO_RE.match(line)
        if not m:
            continue
        status_char = m.group(1)
        body = m.group(2).strip()
        done = status_char.lower() == "x" or status_char == "✓"
        unsure = status_char == "❓"

        raw_text = body  # save before actor strip

        # actor parse
        actor = None
        am = ACTOR_RE.match(body)
        if am:
            actor = am.group(1)
            body = am.group(2).strip()

        # metadata extraction
        raw_body = body  # body after actor strip, before metadata strip

        pm = PRIORITY_RE.search(body)
        priority = None
        if pm:
            priority = int(pm.group(1) or pm.group(2))

        dm = DUEDATE_RE.search(body)
        due_date = None
        if dm:
            due_date = dm.group(1) or dm.group(2)

        tags = []
        for tm in TAG_RE.finditer(body):
            tag = tm.group(1)
            if not re.match(r'^p[123]$', tag, re.IGNORECASE):
                tags.append(tag)

        # strip metadata tokens from display text
        display = body
        display = PRIORITY_RE.sub("", display)
        display = DUEDATE_RE.sub("", display)
        display = TAG_RE.sub(lambda m2: "" if not re.match(r'^p[123]$', m2.group(1), re.IGNORECASE) else m2.group(0), display)
        display = display.strip()

        item: dict = {
            "text": display if display else body,
            "done": done,
            "unsure": unsure,
            "actor": actor,
            "heading": current_heading,
            "rawText": raw_body,
            "lineIndex": line_idx,
        }
        if priority is not None:
            item["priority"] = priority
        if due_date is not None:
            item["dueDate"] = due_date
        if tags:
            item["tags"] = tags
        items.append(item)
    return items


def collect_all() -> list[dict]:
    out: list[dict] = []
    for src in TODO_SOURCES:
        items = parse_file(src["path"])
        if not items:
            continue
        out.append({
            "section": src["section"],
            "source": str(src["path"]).replace(os.path.expanduser("~"), "~"),
            "items": items,
            "count": len(items),
            "pending": sum(1 for i in items if not i["done"]),
        })
    return out


def toggle(
    rel_path: str,
    heading: str,
    text: str,
    expected_done: bool | None = None,
    file_mtime: float | None = None,
    line_index: int | None = None,
) -> dict:
    abs_path = _resolve_path(rel_path)
    if abs_path is None:
        return {"ok": False, "error": "path_not_allowed"}

    with _WRITE_LOCK:
        if not abs_path.exists():
            return {"ok": False, "error": "file_missing"}
        if _mtime_changed(abs_path, file_mtime):
            return {"ok": False, "error": "race_detected"}

        lines = abs_path.read_text(encoding="utf-8").splitlines(keepends=False)
        target_idx = None
        if line_index is not None and 0 <= line_index < len(lines):
            candidate = lines[line_index]
            if TODO_RE.match(candidate):
                target_idx = line_index
        if target_idx is None:
            target_idx = _locate_line(lines, heading, text)
        if target_idx is None:
            return {"ok": False, "error": "line_not_found"}
        if isinstance(target_idx, str):
            return {"ok": False, "error": target_idx}

        m = TODO_RE.match(lines[target_idx])
        if not m:
            return {"ok": False, "error": "regex_fail"}
        cur_char = m.group(1)
        cur_done = cur_char.lower() == "x"
        if expected_done is not None and expected_done != cur_done:
            return {"ok": False, "error": "race_detected"}
        if cur_char not in {" ", "x", "X"}:
            return {"ok": False, "error": "unsupported_status"}

        new_char = " " if cur_done else "x"
        lines[target_idx] = lines[target_idx].replace(f"[{cur_char}]", f"[{new_char}]", 1)
        _backup(abs_path)
        _atomic_write(abs_path, lines)
        return {"ok": True, "new_done": new_char == "x", "file_mtime": abs_path.stat().st_mtime}


def add(
    rel_path: str,
    heading: str,
    text: str,
    actor: str | None = None,
    after_text: str | None = None,
) -> dict:
    abs_path = _resolve_path(rel_path)
    if abs_path is None:
        return {"ok": False, "error": "path_not_allowed"}

    with _WRITE_LOCK:
        if not abs_path.exists():
            return {"ok": False, "error": "file_missing"}

        lines = abs_path.read_text(encoding="utf-8").splitlines(keepends=False)
        block = _heading_block(lines, heading)
        if block is None:
            return {"ok": False, "error": "heading_not_found"}
        heading_idx, next_heading_idx = block

        body = f"[{actor}] {text}" if actor else text
        new_line = f"- [ ] {body}"
        if after_text:
            insert_after = _locate_line(lines, heading, after_text)
            if insert_after is None:
                return {"ok": False, "error": "after_text_not_found"}
            if isinstance(insert_after, str):
                return {"ok": False, "error": insert_after}
            lines.insert(insert_after + 1, new_line)
        else:
            insert_at = next_heading_idx
            while insert_at > heading_idx + 1 and lines[insert_at - 1].strip() == "":
                insert_at -= 1
            lines.insert(insert_at, new_line)

        _backup(abs_path)
        _atomic_write(abs_path, lines)
        return {"ok": True, "added_text": body, "file_mtime": abs_path.stat().st_mtime}


def edit(rel_path: str, heading: str, text: str, new_text: str) -> dict:
    abs_path = _resolve_path(rel_path)
    if abs_path is None:
        return {"ok": False, "error": "path_not_allowed"}

    with _WRITE_LOCK:
        if not abs_path.exists():
            return {"ok": False, "error": "file_missing"}

        lines = abs_path.read_text(encoding="utf-8").splitlines(keepends=False)
        target_idx = _locate_line(lines, heading, text)
        if target_idx is None:
            return {"ok": False, "error": "line_not_found"}
        if isinstance(target_idx, str):
            return {"ok": False, "error": target_idx}

        m = TODO_RE.match(lines[target_idx])
        if not m:
            return {"ok": False, "error": "regex_fail"}
        cur_body = m.group(2).strip()
        am = ACTOR_RE.match(cur_body)
        new_body = f"[{am.group(1)}] {new_text}" if am else new_text
        lines[target_idx] = lines[target_idx][:m.start(2)] + new_body + lines[target_idx][m.end(2):]

        _backup(abs_path)
        _atomic_write(abs_path, lines)
        return {
            "ok": True,
            "old_text": text,
            "new_text": new_text,
            "file_mtime": abs_path.stat().st_mtime,
        }


def _backup(path: Path) -> None:
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    ts = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
    shutil.copy2(path, BACKUP_DIR / f"{path.name}_{ts}.bak")


def _resolve_path(rel_path: str) -> Path | None:
    if not rel_path or os.path.isabs(rel_path) or ".." in Path(rel_path).parts:
        return None
    candidate = (VAULT / rel_path).resolve()
    if candidate in ALLOWED_PATHS:
        return candidate
    return None


def _mtime_changed(path: Path, file_mtime: float | None) -> bool:
    if file_mtime is None:
        return False
    return abs(path.stat().st_mtime - float(file_mtime)) > 0.01


def _heading_block(lines: list[str], heading: str) -> tuple[int, int] | None:
    heading_idx = None
    for i, line in enumerate(lines):
        if line.startswith("##") and line.lstrip("#").strip() == heading:
            heading_idx = i
            break
    if heading_idx is None:
        return None
    next_heading_idx = len(lines)
    for j in range(heading_idx + 1, len(lines)):
        if lines[j].startswith("##"):
            next_heading_idx = j
            break
    return heading_idx, next_heading_idx


def _locate_line(lines: list[str], heading: str, text: str) -> int | str | None:
    block = _heading_block(lines, heading)
    if block is None:
        return None
    heading_idx, next_heading_idx = block
    matches: list[int] = []
    target = _compare_text(text)
    for i in range(heading_idx + 1, next_heading_idx):
        m = TODO_RE.match(lines[i])
        if not m:
            continue
        if _compare_text(m.group(2)) == target:
            matches.append(i)
    if not matches:
        return None
    if len(matches) > 1:
        return "ambiguous_match"
    return matches[0]


def _compare_text(text: str) -> str:
    body = text.strip()
    am = ACTOR_RE.match(body)
    return am.group(2).strip() if am else body


def _atomic_write(path: Path, lines: list[str]) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.replace(tmp, path)
