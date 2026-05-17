"""书房 v1 — vault-aware project dashboard backend.

Spec: /Users/mian/Documents/星原/项目/书房/2026-05-09-书房-implementation-plan.md
Phase 1 — read-only: 今日看板 + 三列项目卡片.

Modules:
- DB schema (init_db, schema_version)
- vault md parser (parse_frontmatter, is_project, extract_project, extract_todos)
- macOS Calendar bridge (pull_calendar_today via osascript)
- Query helpers (today_payload, projects_payload, project_payload)
"""
from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import sqlite3
import subprocess
import threading
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any, Optional

try:
    import yaml
except ImportError:
    yaml = None  # type: ignore[assignment]

logger = logging.getLogger("cc-apns-server.studyroom")

SCHEMA_VERSION = 1

VAULT_ROOT = Path("/Users/mian/Documents/星原")
WATCH_DIRS = [
    VAULT_ROOT / "工作",
    VAULT_ROOT / "投研",
    VAULT_ROOT / "项目",
]
SELF_PATH = VAULT_ROOT / "项目" / "书房"  # exclude self
PROJECT_BLOCKLIST = {
    "事件归档", "会议纪要", "合作方", "行政", "经验总结", "待办", "日记", "收藏夹",
    "周报",  # 投研/周报 是周报存档不是项目
    "每日新闻",
    "投研学习",  # 是学习笔记不是项目
}
INDEX_FILES = ("INDEX.md", "README.md", "status.md", "devlog.md")

OSASCRIPT_FILE = Path(__file__).parent / "studyroom_calendar.scpt"

VALID_STATUS = {"active", "review", "blocked", "done"}
DEFAULT_STATUS = "active"
DEFAULT_OWNER = "opia"


# ---------- DB ----------

def init_db(path: str | Path) -> sqlite3.Connection:
    """Initialize SQLite db at `path`. Idempotent. Returns connection."""
    p = Path(path).expanduser()
    p.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(p))
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cur.executescript("""
        CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS projects (
            slug TEXT PRIMARY KEY,
            name TEXT,
            path TEXT,
            status TEXT CHECK(status IN ('active','review','blocked','done')) DEFAULT 'active',
            owner TEXT,
            last_modified_ts INTEGER,
            summary TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_projects_mtime ON projects(last_modified_ts DESC);
        CREATE INDEX IF NOT EXISTS idx_projects_status ON projects(status);
        CREATE TABLE IF NOT EXISTS todos (
            id TEXT PRIMARY KEY,
            text TEXT,
            done INTEGER,
            project_slug TEXT,
            source_file TEXT,
            source_line INTEGER,
            ts INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_todos_done_ts ON todos(done, ts DESC);
        CREATE INDEX IF NOT EXISTS idx_todos_project ON todos(project_slug);
        CREATE TABLE IF NOT EXISTS calendar_events (
            id TEXT PRIMARY KEY,
            title TEXT,
            start_ts INTEGER,
            end_ts INTEGER,
            calendar_name TEXT,
            location TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_calendar_start ON calendar_events(start_ts ASC);
        CREATE TABLE IF NOT EXISTS recent_notes (
            path TEXT PRIMARY KEY,
            title TEXT,
            mtime INTEGER,
            summary TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_recent_mtime ON recent_notes(mtime DESC);
    """)
    cur.execute("INSERT OR IGNORE INTO schema_version (version) VALUES (?)", (SCHEMA_VERSION,))
    conn.commit()
    return conn


# ---------- Parser ----------

_FM_RE = re.compile(r"^---\s*\n(.*?)\n---\s*\n", re.DOTALL)

def parse_frontmatter(md_text: str) -> dict[str, Any]:
    """Extract YAML frontmatter dict from md. Returns {} if absent / malformed."""
    if yaml is None:
        return {}
    if not md_text:
        return {}
    m = _FM_RE.match(md_text)
    if not m:
        return {}
    try:
        data = yaml.safe_load(m.group(1)) or {}
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _strip_frontmatter(md_text: str) -> str:
    m = _FM_RE.match(md_text)
    if m:
        return md_text[m.end():]
    return md_text


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return ""


def is_project(dir_path: Path) -> bool:
    """Decide whether a directory under WATCH_DIRS is a project."""
    if not dir_path.is_dir():
        return False
    name = dir_path.name
    if name in PROJECT_BLOCKLIST:
        return False
    if name.startswith(".") or name.startswith("_"):
        return False
    # Explicit signal: status.md / devlog.md
    if (dir_path / "status.md").exists() or (dir_path / "devlog.md").exists():
        return True
    # INDEX.md / README.md with frontmatter `tags` containing 'project'
    for cand in ("INDEX.md", "README.md"):
        f = dir_path / cand
        if not f.exists():
            continue
        fm = parse_frontmatter(_read_text(f))
        tags = fm.get("tags") or []
        if isinstance(tags, str):
            tags = [tags]
        if any("project" in str(t).lower() for t in tags):
            return True
    # Fallback: not in blocklist + has at least one .md → treat as project
    has_md = any(p.suffix == ".md" for p in dir_path.iterdir() if p.is_file())
    return has_md


def slugify(s: str) -> str:
    s = re.sub(r"[\s/]+", "-", s.strip())
    s = re.sub(r"[^\w一-鿿\-]", "", s)
    return s[:80] or "untitled"


@dataclass
class Project:
    slug: str
    name: str
    path: str
    status: str
    owner: str
    last_modified_ts: int
    summary: Optional[str]


def extract_project(dir_path: Path) -> Project:
    """Build Project from INDEX.md / README.md / devlog.md frontmatter + first paragraph."""
    name = dir_path.name
    status = DEFAULT_STATUS
    owner = DEFAULT_OWNER
    summary: Optional[str] = None
    last_mtime = 0

    chosen_md: Optional[Path] = None
    for cand in INDEX_FILES:
        f = dir_path / cand
        if f.exists():
            chosen_md = f
            break

    if chosen_md:
        try:
            last_mtime = max(last_mtime, int(chosen_md.stat().st_mtime))
        except Exception:
            pass
        text = _read_text(chosen_md)
        fm = parse_frontmatter(text)
        if fm.get("name"):
            name = str(fm["name"]).strip()
        s = str(fm.get("status") or "").strip().lower()
        if s in VALID_STATUS:
            status = s
        if fm.get("owner"):
            owner = str(fm["owner"]).strip()
        body = _strip_frontmatter(text)
        # First non-empty paragraph (skip headings)
        for para in re.split(r"\n\s*\n", body):
            stripped = para.strip()
            if not stripped:
                continue
            if stripped.startswith("#"):
                # Skip pure heading-only paragraphs
                lines = [l for l in stripped.splitlines() if not l.startswith("#")]
                stripped = "\n".join(lines).strip()
                if not stripped:
                    continue
            summary = stripped[:200]
            break
    # last_modified_ts: use directory's most-recent file mtime
    try:
        for child in dir_path.rglob("*.md"):
            if child.is_file():
                last_mtime = max(last_mtime, int(child.stat().st_mtime))
    except Exception:
        pass

    return Project(
        slug=slugify(name),
        name=name,
        path=str(dir_path),
        status=status,
        owner=owner,
        last_modified_ts=last_mtime,
        summary=summary,
    )


_TODO_RE = re.compile(r"^\s*- \[([ xX])\]\s*(.+?)\s*$")

@dataclass
class Todo:
    id: str
    text: str
    done: bool
    project_slug: Optional[str]
    source_file: str
    source_line: int
    ts: int


def extract_todos(md_text: str, source_file: str, project_slug: Optional[str] = None) -> list[Todo]:
    """Parse `- [ ]` / `- [x]` lines. id = sha1(source_file + line + text)[:16]."""
    out: list[Todo] = []
    if not md_text:
        return out
    try:
        mtime = int(Path(source_file).stat().st_mtime) if source_file else int(time.time())
    except Exception:
        mtime = int(time.time())
    for i, line in enumerate(md_text.splitlines(), start=1):
        m = _TODO_RE.match(line)
        if not m:
            continue
        done = m.group(1).lower() == "x"
        text = m.group(2).strip()
        if not text:
            continue
        h = hashlib.sha1(f"{source_file}|{i}|{text}".encode("utf-8")).hexdigest()[:16]
        out.append(Todo(
            id=h, text=text, done=done,
            project_slug=project_slug,
            source_file=source_file, source_line=i, ts=mtime,
        ))
    return out


# ---------- Calendar bridge ----------

def pull_calendar_today() -> list[dict[str, Any]]:
    """Run osascript to pull today's macOS Calendar events. Returns list of dicts."""
    if not OSASCRIPT_FILE.exists():
        logger.warning("studyroom_calendar.scpt missing at %s", OSASCRIPT_FILE)
        return []
    try:
        proc = subprocess.run(
            ["osascript", str(OSASCRIPT_FILE)],
            capture_output=True, text=True, timeout=20,
        )
    except Exception as e:
        logger.warning("osascript run fail: %s", e)
        return []
    if proc.returncode != 0:
        logger.warning("osascript exit %s stderr=%s", proc.returncode, (proc.stderr or "")[:200])
        return []
    out = (proc.stdout or "").strip()
    if not out:
        return []
    events: list[dict[str, Any]] = []
    from datetime import datetime
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
            if not (isinstance(ev, dict) and ev.get("title")):
                continue
            # AppleScript missing value comes through as the literal string
            for k in ("title", "location", "calendar_name"):
                if str(ev.get(k) or "").strip() == "missing value":
                    ev[k] = ""
            # Convert "YYYY-MM-DD HH:MM:SS" local-time strings to epoch seconds
            for src_key, dst_key in (("start_iso", "start_ts"), ("end_iso", "end_ts")):
                if src_key in ev and dst_key not in ev:
                    s = str(ev[src_key])
                    try:
                        dt = datetime.strptime(s, "%Y-%m-%d %H:%M:%S")
                        # Treat as local time → POSIX epoch
                        ev[dst_key] = int(dt.timestamp())
                    except Exception:
                        ev[dst_key] = 0
            events.append(ev)
        except Exception:
            continue
    return events


# ---------- Storage layer ----------

class StudyroomDB:
    """Thread-safe SQLite wrapper. Only one writer at a time via lock."""

    def __init__(self, db_path: str | Path):
        self.path = str(Path(db_path).expanduser())
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        # Verify schema
        conn = init_db(self.path)
        conn.close()

    def _conn(self) -> sqlite3.Connection:
        c = sqlite3.connect(self.path, timeout=10.0)
        c.row_factory = sqlite3.Row
        return c

    # ----- Writes -----

    def upsert_project(self, p: Project):
        with self._lock, self._conn() as c:
            c.execute("""
                INSERT INTO projects (slug, name, path, status, owner, last_modified_ts, summary)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(slug) DO UPDATE SET
                    name=excluded.name,
                    path=excluded.path,
                    status=excluded.status,
                    owner=excluded.owner,
                    last_modified_ts=excluded.last_modified_ts,
                    summary=excluded.summary
            """, (p.slug, p.name, p.path, p.status, p.owner, p.last_modified_ts, p.summary))

    def replace_todos_for_file(self, source_file: str, todos: list[Todo]):
        """Delete all todos for source_file then insert. Atomic."""
        with self._lock, self._conn() as c:
            c.execute("DELETE FROM todos WHERE source_file = ?", (source_file,))
            for t in todos:
                c.execute("""
                    INSERT OR REPLACE INTO todos
                    (id, text, done, project_slug, source_file, source_line, ts)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """, (t.id, t.text, 1 if t.done else 0, t.project_slug, t.source_file, t.source_line, t.ts))

    def purge_todos_not_in_paths(self, allowed_paths: list[str]):
        """删除不在 allowed_paths 列表里的所有 todos. 用于 personal todo 来源切换时清旧."""
        with self._lock, self._conn() as c:
            if not allowed_paths:
                c.execute("DELETE FROM todos")
                return
            placeholders = ",".join("?" for _ in allowed_paths)
            c.execute(f"DELETE FROM todos WHERE source_file NOT IN ({placeholders})", allowed_paths)

    def replace_calendar_events(self, events: list[dict[str, Any]]):
        with self._lock, self._conn() as c:
            c.execute("DELETE FROM calendar_events")
            for ev in events:
                c.execute("""
                    INSERT INTO calendar_events (id, title, start_ts, end_ts, calendar_name, location)
                    VALUES (?, ?, ?, ?, ?, ?)
                """, (
                    str(ev.get("id") or ""),
                    str(ev.get("title") or ""),
                    int(ev.get("start_ts") or 0),
                    int(ev.get("end_ts") or 0),
                    str(ev.get("calendar_name") or ""),
                    str(ev.get("location") or ""),
                ))

    def replace_recent_notes(self, notes: list[dict[str, Any]]):
        with self._lock, self._conn() as c:
            c.execute("DELETE FROM recent_notes")
            for n in notes:
                c.execute("""
                    INSERT OR REPLACE INTO recent_notes (path, title, mtime, summary)
                    VALUES (?, ?, ?, ?)
                """, (
                    str(n.get("path") or ""),
                    str(n.get("title") or ""),
                    int(n.get("mtime") or 0),
                    str(n.get("summary") or ""),
                ))

    # ----- Reads -----

    def today_payload(self) -> dict[str, Any]:
        from datetime import datetime
        with self._conn() as c:
            todos_rows = c.execute("""
                SELECT id, text, done, project_slug, source_file, source_line, ts
                FROM todos WHERE done = 0
                ORDER BY ts DESC LIMIT 50
            """).fetchall()
            cal_rows = c.execute("""
                SELECT id, title, start_ts, end_ts, calendar_name, location
                FROM calendar_events ORDER BY start_ts ASC
            """).fetchall()
            note_rows = c.execute("""
                SELECT path, title, mtime, summary FROM recent_notes
                ORDER BY mtime DESC LIMIT 30
            """).fetchall()
            sum_rows = c.execute("""
                SELECT status, COUNT(*) AS n FROM projects GROUP BY status
            """).fetchall()
        summary = {"active": 0, "review": 0, "blocked": 0, "done": 0}
        for r in sum_rows:
            summary[r["status"] or "active"] = r["n"]
        return {
            "date": datetime.now().strftime("%Y-%m-%d"),
            "todos": [dict(r) for r in todos_rows],
            "calendar": [dict(r) for r in cal_rows],
            "recent_notes": [dict(r) for r in note_rows],
            "projects_summary": summary,
        }

    def projects_payload(self) -> dict[str, Any]:
        with self._conn() as c:
            rows = c.execute("""
                SELECT slug, name, path, status, owner, last_modified_ts, summary
                FROM projects ORDER BY last_modified_ts DESC
            """).fetchall()
        grouped: dict[str, list[dict[str, Any]]] = {"active": [], "review": [], "blocked": [], "done": []}
        for r in rows:
            grouped.setdefault(r["status"] or "active", []).append(dict(r))
        return grouped

    def project_payload(self, slug: str) -> Optional[dict[str, Any]]:
        with self._conn() as c:
            row = c.execute("SELECT * FROM projects WHERE slug = ?", (slug,)).fetchone()
            if not row:
                return None
            todos = c.execute("""
                SELECT id, text, done, source_file, source_line, ts
                FROM todos WHERE project_slug = ? ORDER BY done ASC, ts DESC
            """, (slug,)).fetchall()
        return {
            "project": dict(row),
            "todos": [dict(t) for t in todos],
        }
