"""Claude Code Max plan 5h block usage via ccusage subprocess."""
from __future__ import annotations

import json
import logging
import subprocess
import threading
import time
from typing import Any

logger = logging.getLogger("opia-apns-server.usage")

CCUSAGE_BIN = "/opt/homebrew/bin/ccusage"
CACHE_TTL_SECONDS = 30


class UsageReader:
    def __init__(self, cache_ttl: int = CACHE_TTL_SECONDS):
        self._lock = threading.Lock()
        self._cache_ttl = cache_ttl
        self._cached: dict[str, Any] | None = None
        self._cached_at: float = 0.0

    def get_active(self) -> dict[str, Any]:
        """Return simplified active block snapshot."""
        now = time.time()
        with self._lock:
            if self._cached is not None and (now - self._cached_at) < self._cache_ttl:
                return self._cached

        snapshot = self._fetch()
        with self._lock:
            self._cached = snapshot
            self._cached_at = time.time()
        return snapshot

    def _fetch(self) -> dict[str, Any]:
        try:
            proc = subprocess.run(
                [CCUSAGE_BIN, "blocks", "--active", "--json"],
                capture_output=True,
                text=True,
                timeout=8,
            )
        except FileNotFoundError:
            logger.warning("ccusage binary not found at %s", CCUSAGE_BIN)
            return {"ok": True, "active": None, "error": "ccusage_not_installed"}
        except subprocess.TimeoutExpired:
            logger.warning("ccusage timeout")
            return {"ok": True, "active": None, "error": "ccusage_timeout"}
        except Exception as e:
            logger.exception("ccusage subprocess fail")
            return {"ok": True, "active": None, "error": f"subprocess_fail: {e}"}

        if proc.returncode != 0:
            logger.warning("ccusage exit=%d stderr=%s", proc.returncode, proc.stderr[:200])
            return {"ok": True, "active": None, "error": f"ccusage_exit_{proc.returncode}"}

        try:
            data = json.loads(proc.stdout)
        except Exception as e:
            logger.warning("ccusage json parse fail: %s", e)
            return {"ok": True, "active": None, "error": "json_parse_fail"}

        blocks = data.get("blocks") or []
        active = next((b for b in blocks if b.get("isActive")), None)
        if not active:
            return {"ok": True, "active": None}

        token_counts = active.get("tokenCounts") or {}
        burn = active.get("burnRate") or {}
        projection = active.get("projection") or {}

        return {
            "ok": True,
            "active": {
                "start_time": active.get("startTime"),
                "end_time": active.get("endTime"),
                "models": active.get("models") or [],
                "entries": active.get("entries", 0),
                "total_tokens": active.get("totalTokens", 0),
                "input_tokens": token_counts.get("inputTokens", 0),
                "output_tokens": token_counts.get("outputTokens", 0),
                "cache_create_tokens": token_counts.get("cacheCreationInputTokens", 0),
                "cache_read_tokens": token_counts.get("cacheReadInputTokens", 0),
                "cost_usd": active.get("costUSD", 0.0),
                "burn_tokens_per_min": burn.get("tokensPerMinute", 0.0),
                "burn_indicator": burn.get("tokensPerMinuteForIndicator", 0.0),
                "burn_cost_per_hour": burn.get("costPerHour", 0.0),
                "projection_total_tokens": projection.get("totalTokens", 0),
                "projection_total_cost": projection.get("totalCost", 0.0),
                "projection_remaining_min": projection.get("remainingMinutes", 0),
            },
        }
