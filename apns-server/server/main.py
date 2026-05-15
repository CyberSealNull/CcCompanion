from __future__ import annotations

import argparse
import sys
import threading
from http.server import ThreadingHTTPServer
from pathlib import Path

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from server.common import DEFAULT_CONFIG, ServerState, cleanup_loop, load_config, logger
    from server.handler import PushHandler
else:
    from .common import DEFAULT_CONFIG, ServerState, cleanup_loop, load_config, logger
    from .handler import PushHandler


def run_server(state: ServerState):
    # P0-1: refuse to bind to 0.0.0.0 unless allow_public_bind = true in config
    if state.host == "0.0.0.0" and not state.allow_public_bind:
        logger.error(
            "P0-1 SECURITY: bind=0.0.0.0 but allow_public_bind=false. "
            "Set allow_public_bind=true in config.toml only if you understand the exposure. "
            "Server not started."
        )
        raise SystemExit(1)
    PushHandler.state = state
    server = ThreadingHTTPServer((state.host, state.port), PushHandler)
    logger.info("listening on http://%s:%d", state.host, state.port)
    cleanup_thread = threading.Thread(
        target=cleanup_loop, args=(state,), daemon=True, name="cleanup"
    )
    cleanup_thread.start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("interrupt - shutting down")
    finally:
        server.shutdown()
        state.shutdown()


def main(argv: list[str] | None = None):
    p = argparse.ArgumentParser()
    p.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    p.add_argument("--sandbox", action="store_true", help="force sandbox APNs")
    p.add_argument("--prod", action="store_true", help="force prod APNs")
    args = p.parse_args(argv)

    sandbox: bool | None = None
    if args.sandbox:
        sandbox = True
    elif args.prod:
        sandbox = False

    cfg = load_config(args.config)
    state = ServerState(cfg, sandbox_override=sandbox)
    run_server(state)


if __name__ == "__main__":
    main()
