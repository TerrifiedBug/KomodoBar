#!/usr/bin/env bash
# Generate/refresh appcast.xml from the signed zips in build/ using Sparkle's
# generate_appcast tool. It EdDSA-signs each update with the private key in your
# Keychain (no Apple Developer ID involved).
#
# It first looks for generate_appcast on PATH, then inside .build/artifacts
# (downloaded automatically by `swift build` because Sparkle is an SPM dep), then
# at $SPARKLE_BIN. The first run creates the keypair if you don't have one and
# prints the public key — paste it into Resources/Info.plist (SUPublicEDKey).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GEN="$(command -v generate_appcast 2>/dev/null || true)"
[[ -z "$GEN" ]] && GEN="$(find "$ROOT/.build/artifacts" -name generate_appcast -type f 2>/dev/null | head -1)"
[[ -z "$GEN" && -n "${SPARKLE_BIN:-}" ]] && GEN="$SPARKLE_BIN/generate_appcast"
[[ -n "$GEN" && -x "$GEN" ]] || {
  echo "generate_appcast not found. Run 'swift build' first (downloads Sparkle's" >&2
  echo "tools into .build/artifacts), or set SPARKLE_BIN to Sparkle's bin dir." >&2
  exit 1
}

"$GEN" "$ROOT/build" -o "$ROOT/appcast.xml"
echo "wrote $ROOT/appcast.xml"
