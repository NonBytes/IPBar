#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="IPBar"
BUILD_CONFIG="release"

echo "▶ Building $APP_NAME ($BUILD_CONFIG)…"
swift build -c "$BUILD_CONFIG"

BIN=".build/$BUILD_CONFIG/$APP_NAME"
APP="$APP_NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Info.plist "$APP/Contents/Info.plist"
[ -f IPBar.icns ] && cp IPBar.icns "$APP/Contents/Resources/IPBar.icns"

# Code signature. Prefer a stable Apple Development identity so the app keeps a
# consistent Team ID / designated requirement across rebuilds — this is what lets
# macOS persist the Location grant (needed for Wi-Fi SSID/BSSID). Falls back to
# ad-hoc if no developer identity is present.
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
if [ -n "${SIGN_ID:-}" ]; then
    echo "  Signing with: $SIGN_ID"
    codesign --force --sign "$SIGN_ID" --identifier com.nonbytes.ipbar "$APP" \
        >/dev/null 2>&1 || codesign --force --sign - --identifier com.nonbytes.ipbar "$APP" >/dev/null 2>&1 || true
else
    codesign --force --sign - --identifier com.nonbytes.ipbar "$APP" >/dev/null 2>&1 || true
fi

echo "✓ Built $APP"
echo "  Run with:   open $APP"
echo "  Install to: cp -R $APP /Applications/"
