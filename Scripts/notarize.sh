#!/bin/bash
# Notarizes dist/Moorage.app and staples the ticket. Required: macOS refuses
# to let users enable a file system extension from an unnotarized app.
#
# Requires a stored notarytool keychain profile (same one as Envy).
# Usage: Scripts/notarize.sh [keychain-profile-name]

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/dist/Moorage.app"
PROFILE="${1:-envy-notary}"

[ -d "$APP" ] || { echo "Build first: Scripts/build-app.sh"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SUBMIT_ZIP="$WORK/Moorage.zip"

echo "==> Zipping for submission..."
ditto -c -k --keepParent "$APP" "$SUBMIT_ZIP"

echo "==> Submitting to notary service (waits for result)..."
xcrun notarytool submit "$SUBMIT_ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling ticket..."
xcrun stapler staple "$APP"

echo "==> Verifying..."
spctl --assess --type execute -vv "$APP"
echo "==> Notarized and stapled: $APP"
