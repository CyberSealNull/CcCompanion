#!/usr/bin/env python3
"""Preflight checks for the monolith CcCompanion APNs server."""
from __future__ import annotations

import argparse
import importlib.util
import py_compile
import shutil
import socket
import subprocess
import sys
from pathlib import Path
from typing import Any

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    tomllib = None  # type: ignore[assignment]


ROOT = Path(__file__).resolve().parents[1]
REQUIRED_MODULES = {
    "PyJWT": "jwt",
    "cryptography": "cryptography",
    "httpx": "httpx",
    "h2": "h2",
}


class Reporter:
    def __init__(self) -> None:
        self.failures = 0
        self.warnings = 0

    def ok(self, label: str, detail: str = "") -> None:
        print(f"[OK]   {label}{': ' + detail if detail else ''}")

    def warn(self, label: str, detail: str = "") -> None:
        self.warnings += 1
        print(f"[WARN] {label}{': ' + detail if detail else ''}")

    def fail(self, label: str, detail: str = "") -> None:
        self.failures += 1
        print(f"[FAIL] {label}{': ' + detail if detail else ''}")


def check_python(rep: Reporter) -> None:
    version = sys.version_info
    version_text = f"{version.major}.{version.minor}.{version.micro}"
    if version >= (3, 11):
        rep.ok("Python", version_text)
    else:
        rep.fail("Python", f"{version_text}; Python 3.11+ is required")


def check_dependencies(rep: Reporter) -> None:
    for dist_name, module_name in REQUIRED_MODULES.items():
        if importlib.util.find_spec(module_name) is None:
            rep.fail("dependency", f"{dist_name} is missing; run pip install -r requirements.txt")
        else:
            rep.ok("dependency", dist_name)


def load_config(rep: Reporter, path: Path) -> dict[str, Any] | None:
    if not path.exists():
        rep.fail("config", f"{path} does not exist; copy config.example.toml to config.toml")
        return None
    if tomllib is None:
        rep.fail("config", "cannot parse TOML because this Python has no tomllib")
        return None
    try:
        config = tomllib.loads(path.read_text())
    except Exception as exc:
        rep.fail("config", f"{path} is not valid TOML: {exc}")
        return None
    rep.ok("config", str(path))
    if not isinstance(config.get("server"), dict):
        rep.warn("config", "[server] section is missing; server defaults will be used")
    if not isinstance(config.get("apns"), dict):
        rep.warn("config", "[apns] section is missing; APNs startup may fail")
    return config


def check_command(rep: Reporter, name: str, args: list[str]) -> None:
    path = shutil.which(args[0])
    if not path:
        rep.fail(name, f"{args[0]} not found on PATH")
        return
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=5, check=False)
    except Exception as exc:
        rep.fail(name, str(exc))
        return
    output = (result.stdout or result.stderr or "").strip().splitlines()
    detail = output[0] if output else path
    if result.returncode == 0:
        rep.ok(name, detail)
    else:
        rep.fail(name, detail or f"exit code {result.returncode}")


def check_port(rep: Reporter, config: dict[str, Any] | None) -> None:
    server_cfg = (config or {}).get("server") if isinstance(config, dict) else {}
    if not isinstance(server_cfg, dict):
        server_cfg = {}
    host = str(server_cfg.get("host") or "127.0.0.1")
    port = int(server_cfg.get("port") or 8795)
    bind_host = "127.0.0.1" if host == "0.0.0.0" else host
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.bind((bind_host, port))
    except OSError as exc:
        rep.fail("port", f"{host}:{port} is not available: {exc}")
    else:
        rep.ok("port", f"{host}:{port} is available")
    finally:
        sock.close()


def check_syntax(rep: Reporter) -> None:
    files = sorted(ROOT.glob("*.py"))
    files += sorted((ROOT / "scripts").glob("*.py"))
    for path in files:
        try:
            py_compile.compile(str(path), doraise=True)
        except py_compile.PyCompileError as exc:
            rep.fail("syntax", f"{path.relative_to(ROOT)}: {exc.msg}")
            return
    rep.ok("syntax", f"{len(files)} Python files compile")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=ROOT / "config.toml")
    args = parser.parse_args(argv)

    rep = Reporter()
    check_python(rep)
    check_dependencies(rep)
    config = load_config(rep, args.config)
    check_command(rep, "tmux", ["tmux", "-V"])
    check_command(rep, "Claude Code CLI", ["claude", "--version"])
    check_port(rep, config)
    check_syntax(rep)

    print()
    if rep.failures:
        print(f"doctor: {rep.failures} failure(s), {rep.warnings} warning(s)")
        return 1
    print(f"doctor: ok ({rep.warnings} warning(s))")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
