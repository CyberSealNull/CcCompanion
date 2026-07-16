#!/usr/bin/env python3
"""verify_chatstore_scope_freeze.py

二审(P0-1)结构性回归闸: bootstrapHistory / refreshRecent / loadEarlier / searchServer /
jumpToMessage 这五个函数, 跨基座 review 两轮都抓到同一类 bug —— 函数体内网络 await 之后
重新读 ambient `chatStore.xxx()` facade(它按当时的全局 DirectAPIConfig.mode 现算队列), 而不是
沿用函数入口就该冻结好的 `chatStore.snapshot(mode)` scope。修复后这五个函数体内除了那一次
`chatStore.snapshot(...)` 调用(用来拿冻结的 scope)之外, 不应该再出现任何其它 `chatStore.` 调用。

这个脚本把"不能回归"这条钉成可复跑的红绿检查, 不依赖人工每次重新读一遍全部五个函数体。
不需要编译、不需要模拟器, `python3 verify_chatstore_scope_freeze.py` 秒出结果。

用法: python3 verify_chatstore_scope_freeze.py
退出码: 0 = PASS, 1 = FAIL(五个函数里有任何一个仍读 ambient chatStore.)
"""

import re
import sys
from pathlib import Path

CHAT_VIEW_SWIFT = Path(__file__).resolve().parent.parent / "CcCompanion" / "ChatView.swift"

# 这五个函数名跟 xxxTracked() 包装方法只差一个后缀 —— 用 `func {name}\(` 精确匹配签名,
# "func jumpToMessageTracked(" 后面紧跟的是 "Tracked(" 不是 "(", 天然不会误命中包装方法。
FUNCTIONS = [
    "bootstrapHistory",
    "refreshRecent",
    "loadEarlier",
    "searchServer",
    "jumpToMessage",
]

# 唯一允许出现的 chatStore. 调用: 拿冻结 scope 本身。
ALLOWED_PATTERN = re.compile(r"chatStore\.snapshot\(")
# 排除前面是"字母数字下划线"的情况(防止误命中形如 xxxChatStore. 的其它标识符), 但不能排除
# 前面是"."的情况——回炉一审的真实 bug 写法正是 `self.chatStore.upsert(...)`,
# 排除"."会让检查器连它想抓的那个模式都抓不到(已用注入式负例验证过这条).
ANY_CHATSTORE_CALL = re.compile(r"(?<![\w])chatStore\.")


def extract_function_body(text: str, name: str) -> str:
    m = re.search(rf"func {name}\([^)]*\)[^{{]*\{{", text)
    if not m:
        raise SystemExit(f"chatstore_scope_freeze: FAIL — could not locate `func {name}(` in {CHAT_VIEW_SWIFT}")
    start = m.end() - 1  # 定位到那个开括号本身
    depth = 0
    i = start
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
        i += 1
    raise SystemExit(f"chatstore_scope_freeze: FAIL — unbalanced braces while scanning `func {name}(`")


def offending_lines(body: str) -> list:
    bad = []
    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith("//"):
            continue  # 纯注释行(哪怕文字里提到 chatStore.xxx 也不是活代码), 跳过.
        if not ANY_CHATSTORE_CALL.search(stripped):
            continue
        if ALLOWED_PATTERN.search(stripped):
            continue  # chatStore.snapshot(...) 是拿冻结 scope 本身, 允许.
        bad.append(stripped)
    return bad


def main() -> int:
    if not CHAT_VIEW_SWIFT.exists():
        print(f"chatstore_scope_freeze: FAIL — {CHAT_VIEW_SWIFT} not found")
        return 1

    text = CHAT_VIEW_SWIFT.read_text(encoding="utf-8")
    failures = []
    for name in FUNCTIONS:
        body = extract_function_body(text, name)
        bad_lines = offending_lines(body)
        if bad_lines:
            failures.append((name, bad_lines))

    if failures:
        print("chatstore_scope_freeze: FAIL")
        for name, bad_lines in failures:
            print(f"  {name}() still reads ambient chatStore. after its entry point:")
            for line in bad_lines:
                print(f"    {line}")
        return 1

    print(f"chatstore_scope_freeze: PASS ({len(FUNCTIONS)} functions checked — "
          f"only chatStore.snapshot() at entry, zero ambient chatStore. calls)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
