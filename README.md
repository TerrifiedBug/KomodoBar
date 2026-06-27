# KomodoBar 🦎

> A macOS menu-bar control plane for [Komodo](https://komo.do).

[![CI](https://github.com/TerrifiedBug/KomodoBar/actions/workflows/ci.yml/badge.svg)](https://github.com/TerrifiedBug/KomodoBar/actions/workflows/ci.yml)

Glance at your Komodo fleet from the menu bar and act on it without opening the web UI:

- **Server health** — per-server state (healthy / unreachable / disabled) and a fleet rollup.
- **Stack health** — per-stack state (running / down / unhealthy / …) and a rollup.
- **Pending updates** — stacks with a newer image available are badged ⬆; "Check for Updates" forces a fresh registry check.
- **Actions** — redeploy, pull images, or restart a stack; "Redeploy All Stacks" in one click.
- **At-a-glance icon** — the menu-bar lizard turns red and shows a count when something needs attention.

Destructive actions (redeploy / restart) ask for confirmation first.

## Install

```bash
brew install --cask komodobar
```

Or download the latest build from [Releases](https://github.com/TerrifiedBug/KomodoBar/releases).
It's unsigned, so on first launch right-click the app → **Open** (or `xattr -dr com.apple.quarantine KomodoBar.app`).

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
