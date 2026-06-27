#!/usr/bin/env bash
# Build + package an UNSIGNED (ad-hoc) release — NO Apple Developer ID required.
# Produces build/KomodoBar-<version>.zip, and refreshes the EdDSA-signed
# appcast.xml so Sparkle auto-update still works (if a Sparkle key is set).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT/version.env"

APP_NAME="KomodoBar"
BUNDLE="$ROOT/build/$APP_NAME.app"
ZIP="$ROOT/build/$APP_NAME-$MARKETING_VERSION.zip"

# Universal, ad-hoc-signed .app (package_app.sh already does `codesign --sign -`).
"$ROOT/Scripts/package_app.sh" release

echo "==> zip"
ditto -c -k --keepParent "$BUNDLE" "$ZIP"

# Refresh the appcast only if a real Sparkle public key has been set.
if [[ -f "$ROOT/Resources/Info.plist" ]] && grep -q 'REPLACE_WITH_YOUR_SPARKLE' "$ROOT/Resources/Info.plist"; then
  echo "==> skipping appcast (no Sparkle key in Resources/Info.plist yet)"
elif [[ ! -f "$ROOT/Resources/Info.plist" ]]; then
  echo "==> no Info.plist; skipping appcast"
else
  "$ROOT/Scripts/make_appcast.sh" || echo "==> appcast step failed; run Scripts/make_appcast.sh manually"
fi

cat <<EOF

built (unsigned): $ZIP

⚠️  Unsigned app: macOS Gatekeeper quarantines it after download. To open it,
   end users must either:
     • right-click the app in Finder → Open → Open, OR
     • run: xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app"
   (Apps you build & run locally yourself are not quarantined.)
EOF
