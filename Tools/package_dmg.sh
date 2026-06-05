#!/bin/bash
# Build IPBar.app and wrap it in a distributable IPBar.dmg.
#
# If a "Developer ID Application" certificate is installed AND notary credentials
# are exported, the app is re-signed with hardened runtime and the DMG is
# notarized + stapled automatically (so it opens cleanly on any Mac):
#
#   export NOTARY_APPLE_ID="you@example.com"
#   export NOTARY_TEAM_ID="TEAMID"
#   export NOTARY_PASSWORD="app-specific-password"
#   ./Tools/package_dmg.sh
#
# Otherwise it falls back to the existing (ad-hoc / Apple Development) signature
# and just prints the manual notarization steps.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh

APP="IPBar.app"

# Re-sign with Developer ID + hardened runtime if such a cert is available.
DEVID="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
if [ -n "${DEVID:-}" ]; then
    echo "  Re-signing with: $DEVID (hardened runtime)"
    codesign --force --deep --options runtime --timestamp \
        --sign "$DEVID" --identifier com.nonbytes.ipbar "$APP"
fi

STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/$APP"
ln -s /Applications "$STAGING/Applications"     # drag-to-install target

rm -f IPBar.dmg
hdiutil create -volname "IPBar" -srcfolder "$STAGING" -ov -format UDZO IPBar.dmg >/dev/null
rm -rf "$STAGING"
echo "✓ Created IPBar.dmg"

# Notarize automatically when a Developer ID cert + credentials are present.
if [ -n "${DEVID:-}" ] && [ -n "${NOTARY_APPLE_ID:-}" ] \
   && [ -n "${NOTARY_TEAM_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ]; then
    echo "  Submitting for notarization…"
    xcrun notarytool submit IPBar.dmg \
        --apple-id "$NOTARY_APPLE_ID" \
        --team-id  "$NOTARY_TEAM_ID" \
        --password "$NOTARY_PASSWORD" \
        --wait
    xcrun stapler staple IPBar.dmg
    echo "✓ Notarized + stapled — opens cleanly on any Mac"
    exit 0
fi

echo
cat <<'NOTES'
This DMG is NOT notarized (runs on Macs that trust this signature). To share it
without Gatekeeper warnings, install a Developer ID Application cert, then either
re-run with the NOTARY_* env vars set (see the header of this script) or run:

  codesign --force --deep --options runtime \
      --sign "Developer ID Application: YOUR NAME (TEAMID)" IPBar.app
  xcrun notarytool submit IPBar.dmg \
      --apple-id "you@example.com" --team-id "TEAMID" \
      --password "APP_SPECIFIC_PASSWORD" --wait
  xcrun stapler staple IPBar.dmg
NOTES
