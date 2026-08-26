#!/usr/bin/env python3
"""Source-level contract checks for grouped bubbles and safe row pop-in."""

from pathlib import Path
import re
import sys


SOURCE = Path(__file__).resolve().parents[1] / "CcCompanion" / "ChatView.swift"
text = SOURCE.read_text(encoding="utf-8")
failures: list[str] = []


def require(pattern: str, label: str) -> None:
    if re.search(pattern, text, re.MULTILINE | re.DOTALL) is None:
        failures.append(label)


def reject(pattern: str, label: str) -> None:
    if re.search(pattern, text, re.MULTILINE | re.DOTALL) is not None:
        failures.append(label)


require(
    r"enum BubbleGroupPos\s*\{\s*case lone, top, middle, bottom\s*\}",
    "four grouped-bubble positions are declared",
)
require(
    r"private func groupPos\(for row: ChatRowItem, previous: ChatRowItem\?\) -> BubbleGroupPos",
    "row grouping derives position from adjacent rendered rows",
)
require(
    r"case \(true, true\):\s*return \.lone.*case \(true, false\):\s*return \.top.*case \(false, false\):\s*return \.middle.*case \(false, true\):\s*return \.bottom",
    "all first/last grouping combinations are mapped",
)
require(
    r"struct ChatBubbleShape: Shape.*switch pos.*case \.lone:.*case \.top:.*case \.middle:.*case \.bottom:.*let hasTail = tailEnabled && isTailPos",
    "bubble geometry handles every position and limits tails to group ends",
)
require(
    r"ChatMessageListRow\(.*showTime: showTime,\s*isLastInGroup: showTime,.*WeChatBubbleRow\(message: message, showTime: showTime, isLastInGroup: isLastInGroup,",
    "compact chat theme limits its tail to the group end",
)
require(
    r"freshPopInRowIds\.insert\(msg\.id\).*displayedRowsCache\.append\(\.message\(msg, showTime: true\)\)",
    "only a newly appended message is marked for pop-in",
)
require(
    r"modifier\(BubblePopIn\(\s*isFresh: vm\.freshPopInRowIds\.contains\(msg\.id\).*onPlayed: \{ vm\.freshPopInRowIds\.remove\(msg\.id\) \}",
    "each fresh row consumes its pop-in marker after playing",
)
reject(
    r"withAnimation\s*\([^)]*\)\s*\{[^}]*displayedRowsCache\.append",
    "cache append must stay outside list-level animation",
)
require(
    r"private\(set\) var assistantTurnEndsTs: Set<String> = \[\].*private func recomputeAssistantTurnEnds\(\)",
    "turn-end lookups are cached instead of recomputed per rendered row",
)
require(
    r"@Published var messages: \[ChatMessage\] = \[\] \{\s*didSet \{\s*recomputeAssistantTurnEnds\(\)",
    "turn-end cache refreshes whenever messages change",
)
reject(r"translateAction\s*:", "no translation action is introduced")
reject(r"translateTurnText\s*:", "no translation-turn state is introduced")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    raise SystemExit(1)

print("PASS: grouped bubble UI contract")
