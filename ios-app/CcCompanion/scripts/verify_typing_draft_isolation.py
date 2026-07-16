#!/usr/bin/env python3
"""Static regression gate for low-churn chat and terminal typing drafts."""

import sys
from pathlib import Path


SOURCE_DIR = Path(__file__).resolve().parent.parent / "CcCompanion"
CHAT_VIEW = SOURCE_DIR / "ChatView.swift"
TERMINAL_VIEW = SOURCE_DIR / "TerminalView.swift"
CONTENT_VIEW = SOURCE_DIR / "ContentView.swift"


def main() -> int:
    chat = CHAT_VIEW.read_text(encoding="utf-8")
    terminal = TERMINAL_VIEW.read_text(encoding="utf-8")
    content = CONTENT_VIEW.read_text(encoding="utf-8")
    failures = []

    if "vm.draft = newValue" in chat:
        failures.append("ChatInputBar still publishes draft on every character")
    if "private func handleSpeechTranscriptChange" in chat:
        failures.append("dead speech handler still writes transcript through ChatViewModel.draft")
    if "@Published var draft: String" in terminal:
        failures.append("TerminalViewModel still owns a per-character published draft")

    required_chat_fragments = {
        "@State private var chatDraftStore = ChatDraftStore()":
            "ContentView does not own the chat draft across tab replacement",
        "draftStore: chatDraftStore":
            "ContentView does not pass the durable draft owner into ChatView",
        "var draftStore: ChatDraftStore":
            "ChatView does not receive the durable draft owner",
        "draftStore: draftStore":
            "ChatView does not pass the durable draft owner into ChatInputBar",
        "let draftStore: ChatDraftStore":
            "ChatInputBar does not receive the durable draft owner",
    }
    for fragment, message in required_chat_fragments.items():
        haystack = content if fragment in {
            "@State private var chatDraftStore = ChatDraftStore()",
            "draftStore: chatDraftStore",
        } else chat
        if fragment not in haystack:
            failures.append(message)

    input_bar = chat.split("private struct ChatInputBar: View", 1)[-1]
    shared_body = input_bar.split("private var inputBarHStack", 1)[0]
    if "draftStore.restore(fallback: vm.draft)" not in shared_body:
        failures.append("ChatInputBar shared body does not restore the draft for both themes")
    if "draftStore.capture(draftLocal)" not in shared_body:
        failures.append("ChatInputBar shared body does not capture the draft for both themes")

    if chat.count("TextField(") < 2 or chat.count("text: $draftLocal") < 2:
        failures.append("both chat input themes must remain bound to the local typing draft")

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

    print("typing_draft_isolation: PASS (chat survives tab replacement without per-key VM writes; terminal stays local)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
