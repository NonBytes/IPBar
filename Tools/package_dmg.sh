#!/bin/bash
# Build IPBar.app and wrap it in a distributable IPBar.dmg.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh

STAGING="$(mktemp -d)"
cp -R IPBar.app "$STAGING/IPBar.app"
ln -s /Applications "$STAGING/Applications"     # drag-to-install target

rm -f IPBar.dmg
hdiutil create -volname "IPBar" -srcfolder "$STAGING" -ov -format UDZO IPBar.dmg >/dev/null
rm -rf "$STAGING"

echo "✓ Created IPBar.dmg"
echo

cat <<'NOTES'
This DMG is ad-hoc signed (runs on THIS Mac). To share it with other Macs
without Gatekeeper warnings, notarize with your Apple Developer ID:

  # 1) Sign the app with a Developer ID Application cert + hardened runtime
  codesign --force --deep --options runtime \
      --sign "Developer ID Application: YOUR NAME (TEAMID)" IPBar.app

  # 2) Re-create the DMG, then submit it for notarization
  xcrun notarytool submit IPBar.dmg \
      --apple-id "you@example.com" \
      --team-id  "TEAMID" \
      --password "APP_SPECIFIC_PASSWORD" \
      --wait

  # 3) Staple the ticket so it verifies offline
  xcrun stapler staple IPBar.dmg
NOTES
