# KomodoBar 🦎

> A macOS menu-bar control plane for [Komodo](https://komo.do).

[![CI](https://github.com/TerrifiedBug/KomodoBar/actions/workflows/ci.yml/badge.svg)](https://github.com/TerrifiedBug/KomodoBar/actions/workflows/ci.yml)

Glance at your Komodo fleet from the menu bar and act on it without opening the web UI:

- **Server, stack & deployment health** — per-resource state with fleet rollups, with Deployments support for container-only setups.
- **Find & focus** — type to jump to a resource by name; pin (★) or auto-surface recently-used stacks in a Quick Access section; optionally group stacks by server.
- **Filters** — hide "off" stacks (down + stopped), show only problems, and still reach hidden ones (grouped Off / Running) via "Show N hidden".
- **Updates** — pending image updates are badged ⬆; "Update All" applies them with deploy-if-changed (unchanged stacks keep running).
- **Actions** — update / redeploy / pull / restart per stack; deploy / start / stop / restart per deployment; "Redeploy N Unhealthy", "Redeploy all on <server>", and "Redeploy All". Run your Komodo Procedures & Actions from the menu.
- **Notifications** — get a macOS notification when Komodo raises a new alert (with a severity threshold); acknowledge alerts from the menu.
- **Mute & snooze** — silence a known-noisy resource (🔕) so the red icon means "unacknowledged".
- **Recent Activity** — a feed of recent operations with success/failure markers, plus deep-links to open anything in the Komodo web UI.
- **At-a-glance icon** — the menu-bar lizard turns red and shows a count when something genuinely needs attention.

Destructive actions (redeploy / restart / run) ask for confirmation first.

## Install

```bash
brew install --cask terrifiedbug/tap/komodobar
```

The build is unsigned (free), so macOS quarantines it. After install, clear it:
`xattr -dr com.apple.quarantine /Applications/KomodoBar.app` (or right-click the app → **Open** once).

Or download the latest build from [Releases](https://github.com/TerrifiedBug/KomodoBar/releases),
then right-click the app → **Open** (or `xattr -dr com.apple.quarantine KomodoBar.app`).
KomodoBar auto-updates itself via Sparkle for direct downloads; `brew upgrade` updates cask installs.

## Connect

In Komodo's web UI: **Settings → Users → (your user) → Api Keys → create key** (copy the secret — it's
shown once; a read-only service user is ideal for monitoring). Then in **KomodoBar → Settings → Connection**:

| Field | Example |
|-------|---------|
| Server URL | `https://komodo.example.com` (or `http://host:9120` direct) |
| API Key | the key id |
| API Secret | the secret (stored in your **Keychain**) |

"Test Connection" pings the server and validates the credentials. KomodoBar authenticates with the
`X-Api-Key` / `X-Api-Secret` headers and backs off if credentials are rejected (Komodo locks out repeated
bad auth).

## CLI

`komodobar-cli` exposes the same Core headlessly. It reads the standard Komodo env vars:

```bash
export KOMODO_ADDRESS="https://komodo.example.com"
export KOMODO_API_KEY="..."
export KOMODO_API_SECRET="..."

komodobar-cli status     # server + stack health rollup
komodobar-cli servers    # per-server state
komodobar-cli stacks     # per-stack state + pending updates
```

## Develop

```bash
make run      # build a debug .app and launch it in the menu bar
make check    # lint + test  (needs: brew install swiftformat swiftlint)
swift test    # unit tests only
```

Requires macOS 15+ and a Swift 6.2 toolchain.

## How it works

`KomodoBar` is an `LSUIElement` agent app — no Dock icon. The SwiftUI lifecycle hosts a hidden keepalive
window plus a `Settings` scene; the UI is an AppKit `NSStatusItem`. The Komodo API client and Codable
models live in `KomodoBarCore` (pure Foundation, shared with `komodobar-cli`); `KomodoStore` polls health
on a timer and runs actions. Auto-updates use Sparkle, disabled for dev and Homebrew installs.

`Spec/komodo-openapi.json` is the upstream OpenAPI spec the client was modelled against.

## License

MIT © 2026 Danny Feates
