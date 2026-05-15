"""Convenience entry point for running the APNs server from apns-server/."""
from __future__ import annotations

from server.main import main, run_server

__all__ = ["main", "run_server"]


if __name__ == "__main__":
    main()
