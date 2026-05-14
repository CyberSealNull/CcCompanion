#!/usr/bin/env python3
"""书房 indexer — 起 launchd 跑. 全扫 vault → fswatch 增量 → calendar 周期拉.

Spec: /Users/mian/Documents/星原/项目/书房/2026-05-09-书房-implementation-plan.md task 4.
"""
from __future__ import annotations

import json
import logging
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

# Make sure we can import studyroom regardless of cwd
HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))

from studyroom import (  # noqa: E402
    StudyroomDB,
    Project, Todo,
    is_project, extract_project, extract_todos,
    pull_calendar_today,
    WATCH_DIRS, SELF_PATH, VAULT_ROOT,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s %(message)s",
)
logger = logging.getLogger("studyroom_indexer")

DB_PATH = HERE / "state" / "studyroom.db"
RECENT_NOTES_WINDOW_S = 7 * 86400
RECENT_NOTES_LIMIT = 30
CAL_PERIOD_S = 60
DEBOUNCE_S = 1.0

# 2026-05-09 用户崩 reset todo 来源 — 项目内 - [ ] 是 spec checklist 不是 personal todo
# 真待办只从两条路径抽
PERSONAL_TODO_INBOX = VAULT_ROOT / "待办" / "inbox.md"
WORKLOG_DIR = VAULT_ROOT / "工作日志" / "2026年5月"
WORKLOG_RECENT_DAYS = 7


def index_one_project(db: StudyroomDB, dir_path: Path):
    """Index a single project directory: extract project metadata only.
    项目内 - [ ] 不再抽为 todo (是 spec checklist 不是 personal todo). todos 走 scan_personal_todos."""
    if not is_project(dir_path):
        return
    try:
        proj = extract_project(dir_path)
    except Exception as e:
        logger.warning("extract_project fail %s: %s", dir_path, e)
        return
    db.upsert_project(proj)


def scan_personal_todos(db: StudyroomDB) -> int:
    """只从两条 source 抽 personal todo
    1) vault/待办/inbox.md
    2) vault/工作日志/2026年5月/{近 7 天}.md
    """
    sources: list[Path] = []
    if PERSONAL_TODO_INBOX.exists():
        sources.append(PERSONAL_TODO_INBOX)
    # 近 7 天工作日志 (按文件名 1.md 2.md ... 31.md)
    if WORKLOG_DIR.exists():
        from datetime import datetime, timedelta
        today = datetime.now()
        for delta in range(WORKLOG_RECENT_DAYS):
            day = today - timedelta(days=delta)
            if day.month != today.month:
                continue
            f = WORKLOG_DIR / f"{day.day}.md"
            if f.exists():
                sources.append(f)
    # 先清掉所有非 sources 路径下的 todos (以前 scan 留下的)
    db.purge_todos_not_in_paths([str(p) for p in sources])
    total = 0
    for md in sources:
        try:
            text = md.read_text(encoding="utf-8", errors="replace")
            todos = extract_todos(text, str(md), project_slug=None)
            db.replace_todos_for_file(str(md), todos)
            total += len([t for t in todos if not t.done])
        except Exception as e:
            logger.warning("personal todo parse fail %s: %s", md, e)
    logger.info("personal todos scanned: %d sources, %d open todos", len(sources), total)
    return total


def full_scan(db: StudyroomDB) -> tuple[int, int]:
    """Full scan WATCH_DIRS one level deep. Returns (n_projects, 0).
    Project 内 todo 不抽 (走 scan_personal_todos). 第二个返回值保留兼容."""
    n_proj = 0
    for root in WATCH_DIRS:
        if not root.exists():
            continue
        for child in sorted(root.iterdir()):
            if not child.is_dir():
                continue
            try:
                if child.resolve() == SELF_PATH.resolve():
                    continue
            except Exception:
                pass
            if not is_project(child):
                continue
            try:
                proj = extract_project(child)
                db.upsert_project(proj)
                n_proj += 1
            except Exception as e:
                logger.warning("scan project %s fail: %s", child, e)
    return n_proj, 0


def scan_recent_notes(db: StudyroomDB) -> int:
    cutoff = time.time() - RECENT_NOTES_WINDOW_S
    notes: list[dict] = []
    skip_dirs = {".obsidian", ".smart-env", ".trash", ".opia_vault_archive_backup_20260509-1145"}
    for root in WATCH_DIRS:
        if not root.exists():
            continue
        for md in root.rglob("*.md"):
            if not md.is_file():
                continue
            try:
                if any(part in skip_dirs for part in md.parts):
                    continue
                if SELF_PATH in md.parents:
                    continue
                st = md.stat()
                if st.st_mtime < cutoff:
                    continue
                title = md.stem
                # First non-empty paragraph as summary
                summary = ""
                try:
                    text = md.read_text(encoding="utf-8", errors="replace")
                    body = text
                    if text.startswith("---"):
                        end = text.find("\n---", 3)
                        if end > 0:
                            body = text[end + 4:]
                    for para in body.split("\n\n"):
                        p = para.strip()
                        if not p:
                            continue
                        if p.startswith("#"):
                            lines = [l for l in p.splitlines() if not l.startswith("#")]
                            p = "\n".join(lines).strip()
                            if not p:
                                continue
                        summary = p[:120]
                        break
                except Exception:
                    pass
                notes.append({
                    "path": str(md),
                    "title": title,
                    "mtime": int(st.st_mtime),
                    "summary": summary,
                })
            except Exception:
                continue
    notes.sort(key=lambda n: n["mtime"], reverse=True)
    notes = notes[:RECENT_NOTES_LIMIT]
    db.replace_recent_notes(notes)
    return len(notes)


def refresh_calendar(db: StudyroomDB) -> int:
    try:
        events = pull_calendar_today()
    except Exception as e:
        logger.warning("calendar pull fail: %s", e)
        return 0
    db.replace_calendar_events(events)
    return len(events)


# ---------- fswatch loop ----------

def fswatch_loop(db: StudyroomDB, stop_evt: threading.Event):
    # 加 vault/待办 vault/工作日志 watch personal todo source 改动也触发
    extra_paths = [VAULT_ROOT / "待办", VAULT_ROOT / "工作日志"]
    cmd = ["fswatch", "-0"] + [str(p) for p in WATCH_DIRS if p.exists()] + [str(p) for p in extra_paths if p.exists()]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        logger.error("fswatch not installed — skipping incremental updates")
        return
    logger.info("fswatch loop started: %s", " ".join(cmd))
    pending: set[str] = set()
    last_change = [time.time()]
    lock = threading.Lock()

    def debouncer():
        while not stop_evt.is_set():
            time.sleep(0.3)
            now = time.time()
            with lock:
                if pending and now - last_change[0] >= DEBOUNCE_S:
                    batch = list(pending)
                    pending.clear()
                else:
                    batch = []
            if batch:
                handled_dirs: set[Path] = set()
                for path_str in batch:
                    p = Path(path_str)
                    # Find which top-level WATCH_DIR project this path belongs to
                    for root in WATCH_DIRS:
                        try:
                            rel = p.relative_to(root)
                        except ValueError:
                            continue
                        parts = rel.parts
                        if not parts:
                            continue
                        proj_dir = root / parts[0]
                        if SELF_PATH in proj_dir.parents or proj_dir == SELF_PATH:
                            continue
                        handled_dirs.add(proj_dir)
                        break
                for d in handled_dirs:
                    try:
                        index_one_project(db, d)
                    except Exception as e:
                        logger.warning("incremental index %s fail: %s", d, e)
                # Also refresh recent_notes (cheap-ish) + personal todos (cheap)
                try:
                    scan_recent_notes(db)
                except Exception:
                    pass
                try:
                    scan_personal_todos(db)
                except Exception:
                    pass
                logger.info("incremental: %d project dirs reindexed + personal todos refreshed", len(handled_dirs))

    deb_thread = threading.Thread(target=debouncer, daemon=True)
    deb_thread.start()

    buf = b""
    while not stop_evt.is_set():
        try:
            chunk = proc.stdout.read(4096)
        except Exception:
            break
        if not chunk:
            break
        buf += chunk
        while b"\x00" in buf:
            path_b, buf = buf.split(b"\x00", 1)
            path_str = path_b.decode("utf-8", errors="replace")
            with lock:
                pending.add(path_str)
                last_change[0] = time.time()
    proc.terminate()


# ---------- Calendar loop ----------

def calendar_loop(db: StudyroomDB, stop_evt: threading.Event):
    while not stop_evt.is_set():
        try:
            n = refresh_calendar(db)
            logger.info("calendar refresh: %d events", n)
        except Exception as e:
            logger.warning("calendar loop err: %s", e)
        if stop_evt.wait(CAL_PERIOD_S):
            return


def main():
    db = StudyroomDB(DB_PATH)
    logger.info("studyroom indexer starting; db=%s", DB_PATH)

    t0 = time.time()
    n_proj, _ = full_scan(db)
    n_todos = scan_personal_todos(db)
    n_notes = scan_recent_notes(db)
    n_events = refresh_calendar(db)
    logger.info(
        "full scan done in %.1fs: %d projects, %d personal todos, %d recent_notes, %d calendar events",
        time.time() - t0, n_proj, n_todos, n_notes, n_events,
    )

    stop_evt = threading.Event()

    def shutdown(signum, frame):
        logger.info("shutdown signal %s", signum)
        stop_evt.set()
    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    cal_thread = threading.Thread(target=calendar_loop, args=(db, stop_evt), daemon=True)
    cal_thread.start()

    # fswatch is the main blocking loop
    try:
        fswatch_loop(db, stop_evt)
    except Exception as e:
        logger.error("fswatch loop crashed: %s", e)
    stop_evt.set()
    logger.info("studyroom indexer exiting")


if __name__ == "__main__":
    main()
