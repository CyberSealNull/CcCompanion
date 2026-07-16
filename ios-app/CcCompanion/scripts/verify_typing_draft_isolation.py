#!/usr/bin/env python3
"""Static regression gate for view-local chat and terminal typing drafts."""

import sys
from pathlib import Path


SOURCE_DIR = Path(__file__).resolve().parent.parent / "CcCompanion"
CHAT_VIEW = SOURCE_DIR / "ChatView.swift"
TERMINAL_VIEW = SOURCE_DIR / "TerminalView.swift"


def main() -> int:
    chat = CHAT_VIEW.read_text(encoding="utf-8")
    terminal = TERMINAL_VIEW.read_text(encoding="utf-8")
    failures = []

    if "vm.draft = newValue" in chat:
        failures.append("ChatInputBar still publishes draft on every character")
    if "private func handleSpeechTranscriptChange" in chat:
        failures.append("dead speech handler still writes transcript through ChatViewModel.draft")
    if "@Published var draft: String" in terminal:
        failures.append("TerminalViewModel still owns a per-character published draft")

    required_terminal_fragments = {
        '@State private var draftLocal: String = ""': "TerminalView has no view-local draft",
        'TextField("", text: $draftLocal': "Terminal TextField is not bound to the local draft",
        "func send(keys: String": "TerminalViewModel does not accept the send-time draft snapshot",
        "await vm.send(keys: keys)": "Terminal send path does not pass the local snapshot",
    }
    for fragment, message in required_terminal_fragments.items():
        if fragment not in terminal:
            failures.append(message)

    if failures:
        print("typing_draft_isolation: FAIL")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("typing_draft_isolation: PASS (chat + terminal drafts stay view-local until send)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
