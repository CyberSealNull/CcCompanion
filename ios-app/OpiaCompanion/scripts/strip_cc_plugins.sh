#!/bin/bash
# Phase 1.8 Try 2 — Strip OpiaShare + OpiaWidgetExtension from CcCompanion .app bundle.
# Runs as PBXShellScriptBuildPhase on OpiaCompanion target (after Embed Foundation Extensions).
# Only acts when CONFIGURATION == CcRelease. No-op for Debug/Release (主 build keeps extensions).
# Spec: 2026-05-10_cccompanion_phase1_8_remove_extension_dependencies.md

set -eu

if [ "${CONFIGURATION:-}" != "CcRelease" ]; then
    exit 0
fi

APP_BUNDLE="${CODESIGNING_FOLDER_PATH:-}"
if [ -z "$APP_BUNDLE" ] || [ ! -d "$APP_BUNDLE" ]; then
    echo "[strip_cc_plugins] no CODESIGNING_FOLDER_PATH; skipping" >&2
    exit 0
fi

PLUGINS_DIR="$APP_BUNDLE/PlugIns"
echo "[strip_cc_plugins] CONFIGURATION=$CONFIGURATION"
echo "[strip_cc_plugins] removing PlugIns/*.appex from $APP_BUNDLE"

rm -rf "$PLUGINS_DIR/OpiaShare.appex"
rm -rf "$PLUGINS_DIR/OpiaWidgetExtension.appex"

if [ -d "$PLUGINS_DIR" ]; then
    if [ -z "$(ls -A "$PLUGINS_DIR" 2>/dev/null || true)" ]; then
        rmdir "$PLUGINS_DIR"
        echo "[strip_cc_plugins] removed empty PlugIns dir"
    fi
fi

# Re-sign the .app bundle if signing is enabled (after we mutated bundle contents).
if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" ]; then
    echo "[strip_cc_plugins] re-signing $APP_BUNDLE after PlugIns removal"
    /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
        --preserve-metadata=identifier,entitlements --timestamp=none \
        "$APP_BUNDLE"
fi

echo "[strip_cc_plugins] done"
