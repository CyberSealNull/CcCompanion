#!/usr/bin/env python3
"""Compare key request/response shapes between monolith and split handlers."""
from __future__ import annotations

import argparse
import importlib.util
import json
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from http.server import ThreadingHTTPServer
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
AUTH_TOKEN = "smoke-secret"


@dataclass(frozen=True)
class SmokeCase:
    method: str
    path: str
    body: dict[str, Any]


SMOKE_CASES = [
    SmokeCase("POST", "/chat/send", {"text": "smoke hello"}),
    SmokeCase("POST", "/push", {"event": "update", "state": "spoken", "preview": "smoke"}),
    SmokeCase("POST", "/chain/abort", {}),
    SmokeCase("POST", "/tmux/send", {"keys": "hello", "enter": False}),
    SmokeCase("POST", "/register-device-token", {"token": "device-token-smoke"}),
]


class FakeChat:
    def append(self, **kwargs: Any) -> dict[str, Any]:
        return {
            "id": "chat-smoke",
            "ts": "2026-01-01T00:00:00.000+00:00",
            "role": kwargs.get("role", "user"),
            "text": kwargs.get("text", ""),
            "source": kwargs.get("source", "ios-app"),
            "quoted_text": None,
            "location": kwargs.get("location"),
        }


class FakeDeviceTokens:
    def __init__(self) -> None:
        self.tokens: set[str] = set()

    def register(self, token: str) -> bool:
        is_new = token not in self.tokens
        self.tokens.add(token)
        return is_new

    def __len__(self) -> int:
        return len(self.tokens)


class FakeSettings:
    def get(self, _key: str, default: Any = None) -> Any:
        return default

    def snapshot(self) -> dict[str, Any]:
        return {}


class FakeTasks:
    def snapshot(self) -> dict[str, Any]:
        return {"active": None, "history": []}


class FakeTokens:
    def all_active(self) -> list[Any]:
        return []


class FakeState:
    def __init__(self) -> None:
        self.allowed_ips = []
        self.shared_secret = AUTH_TOKEN
        self.strict_auth = True
        self.allow_remote_control = True
        self.apns_enabled = False
        self.sandbox = False
        self.bundle_id = ""
        self.tokens = FakeTokens()
        self.device_tokens = FakeDeviceTokens()
        self.chat = FakeChat()
        self.settings = FakeSettings()
        self.tasks = FakeTasks()
        self.typing_state: dict[str, Any] = {"is_typing": False, "since": None}
        self.active_session = "cc"
        self.default_session = "cc"
        self.config: dict[str, Any] = {}


def load_split_handler() -> type:
    sys.path.insert(0, str(ROOT))
    from server.handler import PushHandler

    return PushHandler


def load_monolith_handler(base_ref: str) -> type:
    try:
        source = subprocess.check_output(
            ["git", "-C", str(ROOT.parent), "show", f"{base_ref}:apns-server/push.py"],
            text=True,
            stderr=subprocess.PIPE,
        )
    except subprocess.CalledProcessError as exc:
        raise RuntimeError(exc.stderr.strip() or f"could not read {base_ref}:apns-server/push.py") from exc

    tmpdir = tempfile.TemporaryDirectory()
    # Keep the TemporaryDirectory alive for the imported module lifetime.
    load_monolith_handler._tmpdir = tmpdir  # type: ignore[attr-defined]
    path = Path(tmpdir.name) / "push.py"
    path.write_text(source)

    sys.path.insert(0, str(ROOT))
    spec = importlib.util.spec_from_file_location("cc_smoke_monolith_push", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not create import spec for monolith push.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.PushHandler


def response_shape(value: Any) -> Any:
    if isinstance(value, dict):
        return {key: response_shape(value[key]) for key in sorted(value)}
    if isinstance(value, list):
        return ["list", response_shape(value[0]) if value else "empty"]
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int"
    if isinstance(value, float):
        return "float"
    if isinstance(value, str):
        return "str"
    return type(value).__name__


def request(handler_cls: type, case: SmokeCase) -> tuple[int, Any]:
    original_inject = getattr(handler_cls, "_inject_to_session", None)
    original_run = subprocess.run
    original_popen = subprocess.Popen
    handler_cls.state = FakeState()
    handler_cls._inject_to_session = lambda self, *args, **kwargs: (True, "")

    def fake_run(args: Any, *run_args: Any, **run_kwargs: Any) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(args=args, returncode=0, stdout="", stderr="")

    class FakePopen:
        def __init__(self, args: Any, *popen_args: Any, **popen_kwargs: Any) -> None:
            self.args = args
            self.returncode = 0

        def communicate(self, input: bytes | None = None, timeout: float | None = None) -> tuple[str, str]:
            return "", ""

        def kill(self) -> None:
            self.returncode = -9

    server = ThreadingHTTPServer(("127.0.0.1", 0), handler_cls)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        subprocess.run = fake_run  # type: ignore[assignment]
        subprocess.Popen = FakePopen  # type: ignore[assignment]
        url = f"http://127.0.0.1:{server.server_address[1]}{case.path}"
        data = json.dumps(case.body).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            method=case.method,
            headers={
                "Content-Type": "application/json",
                "X-Auth-Token": AUTH_TOKEN,
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=3) as resp:
                raw = resp.read().decode("utf-8")
                status = resp.status
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8")
            status = exc.code
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            body = raw
        return status, body
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)
        if original_inject is not None:
            handler_cls._inject_to_session = original_inject
        subprocess.run = original_run  # type: ignore[assignment]
        subprocess.Popen = original_popen  # type: ignore[assignment]
        time.sleep(0.01)


def compare_case(monolith_handler: type, split_handler: type, case: SmokeCase) -> list[str]:
    mono_status, mono_body = request(monolith_handler, case)
    split_status, split_body = request(split_handler, case)
    failures: list[str] = []
    if mono_status != split_status:
        failures.append(f"status monolith={mono_status} split={split_status}")
    mono_shape = response_shape(mono_body)
    split_shape = response_shape(split_body)
    if mono_shape != split_shape:
        failures.append(
            "shape mismatch\n"
            f"  monolith={json.dumps(mono_shape, ensure_ascii=False, sort_keys=True)}\n"
            f"  split={json.dumps(split_shape, ensure_ascii=False, sort_keys=True)}"
        )
    return failures


def resolve_base_ref(preferred: str | None) -> str:
    candidates = [preferred] if preferred else []
    candidates.extend(["upstream/main", "origin/main", "main"])
    for ref in candidates:
        if not ref:
            continue
        result = subprocess.run(
            ["git", "-C", str(ROOT.parent), "rev-parse", "--verify", f"{ref}^{{commit}}"],
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            return ref
    raise RuntimeError("could not resolve base ref; pass --base-ref explicitly")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-ref", help="monolith base ref, for example origin/main")
    args = parser.parse_args(argv)

    base_ref = resolve_base_ref(args.base_ref)
    print(f"base_ref={base_ref}")
    monolith_handler = load_monolith_handler(base_ref)
    split_handler = load_split_handler()

    failure_count = 0
    for case in SMOKE_CASES:
        failures = compare_case(monolith_handler, split_handler, case)
        if failures:
            failure_count += 1
            print(f"[FAIL] {case.method} {case.path}")
            for failure in failures:
                print(f"  {failure}")
        else:
            print(f"[OK]   {case.method} {case.path}")

    print()
    if failure_count:
        print(f"smoke_test: {failure_count} failure(s)")
        return 1
    print("smoke_test: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
