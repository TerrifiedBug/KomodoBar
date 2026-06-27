#!/usr/bin/env bash
# Build a universal release .app, Developer-ID codesign with hardened runtime,
# notarize, staple, and zip. Produces build/KomodoBar-<version>.zip.
#
# Requires:
#   • A "Developer ID Application" cert in your keychain.
#   • An App Store Connect API key exported as env:
#       APP_STORE_CONNECT_API_KEY_P8  (the .p8 contents)
#       APP_STORE_CONNECT_KEY_ID
#       APP_STORE_CONNECT_ISSUER_ID
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/version.env"

APP_NAME="KomodoBar"
TEAM_ID="CHANGEME000"
BUNDLE="$ROOT/build/$APP_NAME.app"
ZIP="$ROOT/build/$APP_NAME-$MARKETING_VERSION.zip"

: "${APPLE_SIGN_IDENTITY:=Developer ID Application: Danny Feates ($TEAM_ID)}"
: "${APP_STORE_CONNECT_API_KEY_P8:?set the App Store Connect API key env to notarize}"
: "${APP_STORE_CONNECT_KEY_ID:?set APP_STORE_CONNECT_KEY_ID}"
: "${APP_STORE_CONNECT_ISSUER_ID:?set APP_STORE_CONNECT_ISSUER_ID}"

"$ROOT/Scripts/package_app.sh" release

echo "==> codesign (hardened runtime)"
# Sign nested Sparkle.framework first, then the app bundle.
if [[ -d "$BUNDLE/Contents/Frameworks/Sparkle.framework" ]]; then
  codesign --force --options runtime --timestamp \
    --sign "$APPLE_SIGN_IDENTITY" \
    "$BUNDLE/Contents/Frameworks/Sparkle.framework"
fi
codesign --force --deep --options runtime --timestamp \
  --sign "$APPLE_SIGN_IDENTITY" "$BUNDLE"

echo "==> zip"
ditto -c -k --keepParent "$BUNDLE" "$ZIP"

echo "==> notarize"
KEY_FILE="$(mktemp)"
trap 'rm -f "$KEY_FILE"' EXIT
printf '%s' "$APP_STORE_CONNECT_API_KEY_P8" > "$KEY_FILE"
xcrun notarytool submit "$ZIP" \
  --key "$KEY_FILE" \
  --key-id "$APP_STORE_CONNECT_KEY_ID" \
  --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
  --wait

echo "==> staple"
xcrun stapler staple "$BUNDLE"
ditto -c -k --keepParent "$BUNDLE" "$ZIP" # re-zip the now-stapled app
spctl --assess --type execute -vv "$BUNDLE"

echo "notarized: $ZIP"
