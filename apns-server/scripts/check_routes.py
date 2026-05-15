#!/usr/bin/env python3
"""Route regression checks for the CcCompanion APNs server."""
from __future__ import annotations

import ast
import sys
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
HANDLER_PATH = ROOT / "server" / "handler.py"

EXPECTED_ROUTE_COUNTS = {
    "do_GET": 67,
    "do_POST": 60,
}

CRITICAL_ROUTES = {
    "do_GET": {
        "/health",
        "/version",
        "/chat/history",
        "/chain/sessions",
        "/tmux/capture",
        "/tmux/sessions",
        "/tokens",
    },
    "do_POST": {
        "/chat/send",
        "/chat/regenerate",
        "/chain/abort",
        "/chain/new_session",
        "/chain/switch",
        "/tmux/send",
        "/push",
        "/register-device-token",
    },
}

CRITICAL_METHODS = {
    "do_GET",
    "do_POST",
    "_handle_chat_send",
    "_handle_chat_history",
    "_handle_chain_sessions_get",
    "_handle_tmux_capture",
    "_handle_push",
    "_handle_register_device_token",
}


class Reporter:
    def __init__(self) -> None:
        self.failures = 0

    def ok(self, label: str, detail: str = "") -> None:
        print(f"[OK]   {label}{': ' + detail if detail else ''}")

    def fail(self, label: str, detail: str = "") -> None:
        self.failures += 1
        print(f"[FAIL] {label}{': ' + detail if detail else ''}")


def _route_literals(method: ast.FunctionDef) -> list[str]:
    routes: list[str] = []
    for node in ast.walk(method):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            if node.value.startswith("/"):
                routes.append(node.value)
    return routes


def _push_handler_methods(tree: ast.Module) -> dict[str, ast.FunctionDef]:
    for node in tree.body:
        if isinstance(node, ast.ClassDef) and node.name == "PushHandler":
            return {
                item.name: item
                for item in node.body
                if isinstance(item, ast.FunctionDef)
            }
    raise RuntimeError("PushHandler class not found in server/handler.py")


def _contains_route(routes: Iterable[str], expected: str) -> bool:
    return any(route == expected or route.startswith(expected) for route in routes)


def check_route_table(rep: Reporter) -> None:
    try:
        tree = ast.parse(HANDLER_PATH.read_text())
        methods = _push_handler_methods(tree)
    except Exception as exc:
        rep.fail("route table", str(exc))
        return

    for method_name, expected_count in EXPECTED_ROUTE_COUNTS.items():
        method = methods.get(method_name)
        if method is None:
            rep.fail(method_name, "method missing from PushHandler")
            continue
        routes = _route_literals(method)
        if len(routes) == expected_count:
            rep.ok(method_name, f"{expected_count} route literals")
        else:
            rep.fail(method_name, f"expected {expected_count}, found {len(routes)}")

        missing = sorted(
            route
            for route in CRITICAL_ROUTES[method_name]
            if not _contains_route(routes, route)
        )
        if missing:
            rep.fail(f"{method_name} critical routes", ", ".join(missing))
        else:
            rep.ok(f"{method_name} critical routes")


def check_import_smoke(rep: Reporter) -> None:
    sys.path.insert(0, str(ROOT))
    try:
        from server.handler import PushHandler
    except Exception as exc:
        rep.fail("import smoke", str(exc))
        return
    rep.ok("import smoke", "server.handler.PushHandler")

    missing = sorted(name for name in CRITICAL_METHODS if not hasattr(PushHandler, name))
    if missing:
        rep.fail("critical methods", ", ".join(missing))
    else:
        rep.ok("critical methods", f"{len(CRITICAL_METHODS)} methods")


def main() -> int:
    rep = Reporter()
    check_route_table(rep)
    check_import_smoke(rep)
    print()
    if rep.failures:
        print(f"check_routes: {rep.failures} failure(s)")
        return 1
    print("check_routes: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
