#!/bin/bash
# Builds, signs, and notarizes Moorage.app, then packages it as Moorage.dmg —
# the file for the GitHub release / download button. Mounts as a normal disk
# image with a shortcut to /Applications: the standard drag-to-install flow.
#
# Usage: Scripts/make-dmg.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/Moorage.app"
DMG_PATH="$DIST_DIR/Moorage.dmg"
STAGING_DIR="$DIST_DIR/dmg-staging"

echo "==> Building Moorage.app..."
"$ROOT_DIR/Scripts/build-app.sh"

if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  "$ROOT_DIR/Scripts/notarize.sh"
else
  echo "==> No Developer ID certificate found, skipping notarization."
  echo "    (This dmg will trigger Gatekeeper's 'unidentified developer' warning.)"
fi

echo "==> Assembling disk image contents..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Building Moorage.dmg..."
rm -f "$DMG_PATH"
hdiutil create -volname "Moorage" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGING_DIR"

# The dmg wrapper isn't itself notarized/stapled — Gatekeeper checks the .app
# once it's dragged out and opened, and the app carries its own staple from
# notarize.sh above.

echo "==> Done: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
