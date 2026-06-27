# Changelog

All notable changes to KomodoBar are documented here (Keep a Changelog style).

## 0.2.0
### Added
- **Find by name** — start typing in the menu to jump to a stack/server/deployment (NSMenu type-select).
- **Open in Komodo** — deep-link any stack, server, or deployment (and an "Open Komodo Dashboard" item) to the web UI.
- **"Only problems" filter** plus a "Show N hidden" submenu (problems listed directly; stopped and running collapse into nested groups), and an optional "Always hide stopped stacks" setting.
- **Update All** — apply pending updates with one click via deploy-if-changed (unchanged stacks keep running); per-stack "Update (deploy if changed)" alongside a force-redeploy.
- **Background notifications** — macOS notifications when Komodo raises a new alert, with an enable toggle + severity threshold; an Alerts section with one-tap Acknowledge.
- **Deployments** — a Deployments section (deploy/start/stop/restart), for container-only setups.
- **Per-server grouping** (optional) with running/updates rollup badges, and "Redeploy all on <server>".
- **Quick Access** — pinned (★) and recently-used stacks at the top of the menu.
- **Mute & snooze** — silence a noisy stack/server/deployment (🔕) so "red" means "unacknowledged".
- **Run launcher** — fire Komodo Procedures and Actions from the menu.
- **Recent Activity** — a feed of recent operations with success/failure dots.
- **Redeploy N Unhealthy** — one-click redeploy of every broken stack.
### Fixed
- Actions no longer report success on an HTTP 200 that actually failed — a completed-but-failed Update is surfaced as a failure.
- Batch actions report an honest "N ok, M failed" tally instead of silently swallowing per-item errors.

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
