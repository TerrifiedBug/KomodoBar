# Changelog

All notable changes to KomodoBar are documented here (Keep a Changelog style).

## 0.1.3
- Releases are now built and published by CI on a `vX.Y.Z` tag (build → signed appcast → GitHub Release → Homebrew cask). No functional app changes since 0.1.2.

## 0.1.2
- Fixed Sparkle update detection: the build number (`CFBundleVersion`) now comes from the git commit count, so it always increases and updates are detected.

## 0.1.1
- Added the app icon.

## 0.1.0
- First release. Menu-bar control plane for Komodo:
  - Server + stack health with fleet rollups; per-server CPU/mem/disk sparklines on hover.
  - Pending image updates surfaced in the menu and the menu-bar badge.
  - Actions: redeploy / pull / restart per stack, redeploy-all.
  - Stack filter (hide intentionally-down stacks); configurable poll interval.
  - Keychain-stored credentials with 401 back-off.
  - Headless `komodobar-cli` over the same Core.
