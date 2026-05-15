"""Compatibility entry point for the CcCompanion APNs server.

The implementation lives in the ``server`` package. Keep this file so existing
LaunchAgent plist files and setup docs that run ``python3 push.py`` continue to work.
"""
from __future__ import annotations

from server.common import DEFAULT_CONFIG, ServerState, load_config
from server.handler import PushHandler
from server.main import main, run_server

__all__ = [
    "DEFAULT_CONFIG",
    "PushHandler",
    "ServerState",
    "load_config",
    "main",
    "run_server",
]


if __name__ == "__main__":
    main()
