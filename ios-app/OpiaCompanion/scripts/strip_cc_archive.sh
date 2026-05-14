#!/bin/bash
# Phase 1.8 — strip OpiaShare + OpiaWidgetExtension from CcCompanion .xcarchive
# Runs as ArchiveAction PostAction on CcCompanion scheme.
# Mutates the produced .xcarchive: deletes embedded .appex from Products/Applications/<app>.app/PlugIns
# Re-signs the .app bundle if signing is enabled (so Apple won't reject the archive).

set -eu

ARCHIVE_PATH="${ARCHIVE_PATH:-}"
if [ -z "$ARCHIVE_PATH" ] || [ ! -d "$ARCHIVE_PATH" ]; then
    echo "[strip_cc_archive] no ARCHIVE_PATH; skipping" >&2
    exit 0
fi

APP_BUNDLE=$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 2 -name "*.app" -type d | head -1)
if [ -z "$APP_BUNDLE" ] || [ ! -d "$APP_BUNDLE" ]; then
    echo "[strip_cc_archive] no .app bundle found in $ARCHIVE_PATH" >&2
    exit 0
fi

echo "[strip_cc_archive] target: $APP_BUNDLE"

PLUGINS_DIR="$APP_BUNDLE/PlugIns"
if [ -d "$PLUGINS_DIR" ]; then
    rm -rf "$PLUGINS_DIR/OpiaShare.appex"
    rm -rf "$PLUGINS_DIR/OpiaWidgetExtension.appex"
    if [ -z "$(ls -A "$PLUGINS_DIR" 2>/dev/null || true)" ]; then
        rmdir "$PLUGINS_DIR"
        echo "[strip_cc_archive] removed empty PlugIns dir"
    fi
else
    echo "[strip_cc_archive] no PlugIns dir; nothing to strip"
fi

# dSYMs cleanup — extension dSYMs no longer needed
DSYMS_DIR="$ARCHIVE_PATH/dSYMs"
if [ -d "$DSYMS_DIR" ]; then
    rm -rf "$DSYMS_DIR/OpiaShare.appex.dSYM"
    rm -rf "$DSYMS_DIR/OpiaWidgetExtension.appex.dSYM"
    echo "[strip_cc_archive] removed extension dSYMs"
fi

# Re-sign the .app bundle if a code-sign identity was used.
# Look up signing identity from the original CcCompanion target build settings.
# Use the same identity that signed the .app originally (preserve metadata).
SIGNING_INFO=$(/usr/bin/codesign -dvv "$APP_BUNDLE" 2>&1 | grep "Authority=" | head -1 || true)
if [ -n "$SIGNING_INFO" ] && [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
    IDENTITY=$(echo "$SIGNING_INFO" | sed -E 's/^Authority=//')
    echo "[strip_cc_archive] re-signing $APP_BUNDLE with identity '$IDENTITY'"
    /usr/bin/codesign --force --sign "$IDENTITY" \
        --preserve-metadata=identifier,entitlements --timestamp=none \
        "$APP_BUNDLE" || {
        echo "[strip_cc_archive] re-sign failed (ok if archive will be re-signed by export step)" >&2
    }
fi

echo "[strip_cc_archive] done"
