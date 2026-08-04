#!/bin/bash
# Builds Moorage.app — a single-binary menu bar app. The WebDAV server and MTP
# stack live in the app process; mounting uses macOS's built-in mount_webdav.
# No extensions, no kexts, no provisioning profiles.
#
# Usage: Scripts/build-app.sh [--install]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Moorage"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

echo "==> Building release binary..."
swift build -c release --product Moorage
BIN_PATH="$(swift build -c release --product Moorage --show-bin-path)"

# Assemble under /tmp, not the project dir: ~/Documents is iCloud-synced and
# fileproviderd re-tags bundle directories mid-signing, which makes codesign
# fail with "resource fork / detritus" errors. Same lesson as Envy.
BUILD_TMP="$(mktemp -d)"
trap 'rm -rf "$BUILD_TMP"' EXIT
TMP_APP="$BUILD_TMP/$APP_NAME.app"

echo "==> Assembling $APP_NAME.app..."
mkdir -p "$TMP_APP/Contents/MacOS" "$TMP_APP/Contents/Resources"
cp "$BIN_PATH/Moorage" "$TMP_APP/Contents/MacOS/Moorage"
cp "$ROOT_DIR/build-resources/Info.plist" "$TMP_APP/Contents/Info.plist"
cp "$ROOT_DIR/build-resources/AppIcon.icns" "$TMP_APP/Contents/Resources/AppIcon.icns"

echo "==> Signing..."
SIGNING_IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
if [ -z "$SIGNING_IDENTITY" ]; then
  echo "    No Developer ID identity found; ad-hoc signing (local test only)."
  SIGNING_IDENTITY="-"
else
  echo "    Using: $SIGNING_IDENTITY"
fi
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$TMP_APP"
codesign --verify --strict "$TMP_APP"
echo "==> Signature verified."

mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE"
ditto "$TMP_APP" "$APP_BUNDLE"
echo "==> Built: $APP_BUNDLE"

if [ "${1:-}" = "--install" ]; then
  echo "==> Installing to /Applications..."
  # Quit cleanly rather than killall: a hard kill terminates the app while it
  # holds an open USB pipe mid-transfer, which leaves the MTP device's endpoint
  # wedged until it's physically replugged. A graceful quit runs the app's
  # unmount + USB-disconnect path first.
  osascript -e 'tell application "Moorage" to quit' 2>/dev/null || true
  for _ in 1 2 3 4 5; do pgrep -x Moorage >/dev/null || break; sleep 1; done
  killall Moorage 2>/dev/null || true   # fallback if it didn't quit
  rm -rf "/Applications/$APP_NAME.app"
  ditto "$APP_BUNDLE" "/Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
  echo "==> Installed and launched."
fi
