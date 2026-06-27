# Changelog

All notable changes to KomodoBar are documented here (Keep a Changelog style).

## 0.1.0
- First release. Menu-bar control plane for Komodo:
  - Server + stack health with fleet rollups; per-server CPU/mem/disk sparklines on hover.
  - Pending image updates surfaced in the menu and the menu-bar badge.
  - Actions: redeploy / pull / restart per stack, redeploy-all.
  - Stack filter (hide intentionally-down stacks); configurable poll interval.
  - Keychain-stored credentials with 401 back-off.
  - Headless `komodobar-cli` over the same Core.
