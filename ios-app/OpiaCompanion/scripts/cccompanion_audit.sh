#!/bin/bash
# cccompanion_audit.sh — 检查 OTS_LITE build 有没有私人模块泄漏
# 在 CcCompanion target build phase 里调用

PRIVATE_SYMBOLS=(
  "GroupChatView"
  "GroupChatStore"
  "GroupMessageRow"
  "GroupRoster"
  "DiaryView"
  "FavoritesView"
  "TimelineView"
  "HandyClawdView"
  "HandyClawdViewModel"
  "StudyRoomView"
  "StudyRoomStore"
  "RPChatView"
  "RPSessionListView"
)

SRC_DIR="${SRCROOT}/OpiaCompanion"
FOUND_LEAKS=0

for sym in "${PRIVATE_SYMBOLS[@]}"; do
  # Check if symbol appears in OTS_LITE-gated Swift files without guard
  # A leak = the class/struct is defined or referenced OUTSIDE #if !OTS_LITE blocks
  matches=$(grep -rl "$sym" "$SRC_DIR" --include="*.swift" 2>/dev/null | \
    xargs grep -l "^#if !OTS_LITE" 2>/dev/null | wc -l)

  unguarded=$(grep -rl "$sym" "$SRC_DIR" --include="*.swift" 2>/dev/null | \
    xargs grep -L "OTS_LITE" 2>/dev/null | grep -v "cccompanion_audit")

  if [ -n "$unguarded" ]; then
    echo "⚠️  POTENTIAL LEAK: $sym found in unguarded file(s): $unguarded"
    FOUND_LEAKS=1
  fi
done

if [ "$FOUND_LEAKS" = "1" ]; then
  echo "❌ CcCompanion audit FAILED: private symbols may be leaking. Check #if !OTS_LITE guards."
  exit 1
else
  echo "✅ CcCompanion audit PASSED: no unguarded private symbols detected."
  exit 0
fi
