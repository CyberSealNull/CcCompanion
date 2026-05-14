"""Task queue 状态管理 — 持久化到 JSON

数据结构:
{
  "active": {            # 当前在跑的 task (最多 1 个)
    "title": "...",
    "current": 3,
    "total": 8,
    "step": "...",
    "started_at": <ts>,
  },
  "queue": [             # 排队 (FIFO)
    {"title": "...", "total": 5, "added_at": <ts>}, ...
  ],
  "completed": [         # 完成历史 (最近 N 条)
    {"title": "...", "total": 5, "completed_at": <ts>}, ...
  ]
}

API:
  add(title, total)      → 加入队列 (如果没 active 自动 promote 成 active)
  progress(current, [step]) → 更新 active 进度
  done()                 → active 标完成 → 移到 completed → 队列首项 promote
  list()                 → 返回 (active, queue, completed)
"""

from __future__ import annotations
import json
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class TaskState:
    title: str
    total: int
    current: int = 0
    step: str = ""
    started_at: float = field(default_factory=time.time)


@dataclass
class CompletedTask:
    title: str
    total: int
    completed_at: float


class TaskQueue:
    MAX_HISTORY = 10  # 最近 10 条 (4KB payload 上限考虑)

    def __init__(self, path: str | Path):
        self.path = Path(path).expanduser()
        self._lock = threading.RLock()
        self.active: TaskState | None = None
        self.queue: list[TaskState] = []
        self.completed: list[CompletedTask] = []
        self._load()

    def _load(self):
        if not self.path.exists():
            return
        try:
            data = json.loads(self.path.read_text())
            if data.get("active"):
                a = data["active"]
                self.active = TaskState(
                    title=a["title"],
                    total=int(a["total"]),
                    current=int(a.get("current", 0)),
                    step=a.get("step", ""),
                    started_at=float(a.get("started_at", time.time())),
                )
            self.queue = [
                TaskState(
                    title=q["title"],
                    total=int(q["total"]),
                    current=int(q.get("current", 0)),
                    step=q.get("step", ""),
                    started_at=float(q.get("added_at", q.get("started_at", time.time()))),
                )
                for q in data.get("queue", [])
            ]
            self.completed = [
                CompletedTask(
                    title=c["title"],
                    total=int(c["total"]),
                    completed_at=float(c["completed_at"]),
                )
                for c in data.get("completed", [])
            ][-self.MAX_HISTORY:]
        except Exception:
            pass

    def _persist(self):
        data = {
            "active": (
                {
                    "title": self.active.title,
                    "total": self.active.total,
                    "current": self.active.current,
                    "step": self.active.step,
                    "started_at": self.active.started_at,
                }
                if self.active
                else None
            ),
            "queue": [
                {
                    "title": t.title,
                    "total": t.total,
                    "current": t.current,
                    "step": t.step,
                    "added_at": t.started_at,
                }
                for t in self.queue
            ],
            "completed": [
                {
                    "title": c.title,
                    "total": c.total,
                    "completed_at": c.completed_at,
                }
                for c in self.completed[-self.MAX_HISTORY:]
            ],
        }
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2))
        tmp.replace(self.path)

    def add(self, title: str, total: int = 1) -> dict[str, Any]:
        """加入队列. 没 active 自动 promote."""
        with self._lock:
            new_task = TaskState(title=title, total=total)
            if self.active is None:
                self.active = new_task
            else:
                self.queue.append(new_task)
            self._persist()
            return self.snapshot()

    def progress(self, current: int, step: str = "", total: int | None = None) -> dict[str, Any]:
        with self._lock:
            if self.active is None:
                return self.snapshot()
            self.active.current = current
            if step:
                self.active.step = step
            if total is not None:
                self.active.total = total
            self._persist()
            return self.snapshot()

    def done(self) -> dict[str, Any]:
        """active 移到 completed 队列首项 promote."""
        with self._lock:
            if self.active is None:
                return self.snapshot()
            self.completed.append(
                CompletedTask(
                    title=self.active.title,
                    total=self.active.total,
                    completed_at=time.time(),
                )
            )
            self.completed = self.completed[-self.MAX_HISTORY:]
            self.active = self.queue.pop(0) if self.queue else None
            self._persist()
            return self.snapshot()

    def cancel(self) -> dict[str, Any]:
        """取消 active 不进 history."""
        with self._lock:
            self.active = self.queue.pop(0) if self.queue else None
            self._persist()
            return self.snapshot()

    def clear_history(self) -> dict[str, Any]:
        with self._lock:
            self.completed = []
            self._persist()
            return self.snapshot()

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return {
                "active": (
                    {
                        "title": self.active.title,
                        "total": self.active.total,
                        "current": self.active.current,
                        "step": self.active.step,
                    }
                    if self.active
                    else None
                ),
                "queue_length": len(self.queue),
                "queue_titles": [t.title for t in self.queue],
                "completed": [
                    {"title": c.title, "total": c.total}
                    for c in self.completed[-self.MAX_HISTORY:]
                ],
            }
