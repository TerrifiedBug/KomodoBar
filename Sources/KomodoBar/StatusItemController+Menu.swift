import AppKit
import KomodoBarCore
import SwiftUI

/// Menu construction: the sections and submenus rebuilt on every open.
@MainActor
extension StatusItemController {
    func addHeader(to menu: NSMenu) {
        let title = NSMenuItem()
        title.attributedTitle = NSAttributedString(
            string: "KomodoBar",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)],
        )
        title.isEnabled = false
        menu.addItem(title)

        switch self.store.connection {
        case .ok:
            if let date = store.lastRefresh {
                self.addInfo(to: menu, "Updated \(Self.timeFormatter.string(from: date))", secondary: true)
            }
        case let .error(message):
            self.addInfo(to: menu, "⚠︎ \(message)", secondary: true)
        case .authFailed:
            self.addInfo(to: menu, "⚠︎ Authentication failed", secondary: true)
        case .unconfigured:
            self.addInfo(to: menu, "Not connected", secondary: true)
        }
        if let status = store.actionStatus {
            self.addInfo(to: menu, status, secondary: true)
        }
    }

    func addServers(to menu: NSMenu) {
        let summary = self.store.serversSummary
        let header = summary.map { "Servers — \($0.healthy)/\($0.total) healthy" } ?? "Servers"
        self.addInfo(to: menu, header)
        if self.store.servers.isEmpty {
            self.addInfo(to: menu, "No servers", secondary: true)
        }
        for server in self.store.servers {
            var detail = server.state.displayName
            if let stats = store.serverStats[server.id] {
                detail += " · CPU \(Int(stats.cpuPerc.rounded()))%"
            } else if let region = server.info.region, !region.isEmpty {
                detail += " · \(region)"
            }
            let item = NSMenuItem()
            item.title = server.name // bare name drives NSMenu type-select (jump-to by typing)
            let name = "\(self.suppressionPrefix(server.id))\(server.name)"
            item.attributedTitle = self.row(server.state.severity, name, secondary: detail)
            item.submenu = self.serverSubmenu(for: server) // hover for CPU/mem/disk + sparkline
            menu.addItem(item)
        }
    }

    private func serverSubmenu(for server: ServerListItem) -> NSMenu {
        let submenu = NSMenu()
        let host = NSHostingView(rootView: ServerDetailView(
            version: server.info.version,
            address: server.info.address,
            stats: self.store.serverStats[server.id],
            cpuHistory: self.store.cpuHistory[server.id] ?? [],
            memHistory: self.store.memHistory[server.id] ?? [],
            diskHistory: self.store.diskHistory[server.id] ?? [],
        ))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: max(host.fittingSize.height, 60))
        let item = NSMenuItem()
        item.view = host
        submenu.addItem(item)
        submenu.addItem(.separator())
        self.addMuteItems(forId: server.id, to: submenu)
        if self.store.dashboardBaseURL != nil {
            let open = NSMenuItem(
                title: "Open in Komodo",
                action: #selector(self.openServerInKomodo(_:)),
                keyEquivalent: "",
            )
            open.target = self
            open.representedObject = server
            submenu.addItem(open)
        }
        return submenu
    }

    /// Top-of-menu shortcuts: pinned stacks (★) and recently-acted-on stacks, so the
    /// handful you actually operate on stay one click away at 56-stack scale.
    func addQuickAccess(to menu: NSMenu) {
        let quick = self.store.quickAccessStacks
        guard !quick.isEmpty else { return }
        self.addInfo(to: menu, "Quick Access")
        for stack in quick {
            let item = NSMenuItem()
            item.title = stack.name
            let pin = self.store.isPinned(stack.id) ? "★ " : ""
            var label = stack.state.displayName
            if stack.updateAvailable { label += " · ⬆ update" }
            let name = "\(self.suppressionPrefix(stack.id))\(pin)\(stack.name)"
            item.attributedTitle = self.row(stack.state.severity, name, secondary: label)
            item.submenu = self.stackSubmenu(for: stack)
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    func addStacks(to menu: NSMenu) {
        let summary = self.store.stacksSummary
        let header = summary.map { "Stacks — \($0.running)/\($0.total) running" } ?? "Stacks"
        self.addInfo(to: menu, header)

        // Surface pending updates prominently, above the (possibly filtered) list,
        // covering ALL stacks so a hidden one's update isn't missed.
        if self.store.updateCount > 0 {
            self.addUpdatesSection(to: menu)
        }

        let visible = self.store.visibleStacks
        if visible.isEmpty {
            self.addInfo(to: menu, self.emptyStacksMessage(), secondary: true)
        } else if self.store.groupStacksByServer {
            for group in self.store.visibleStackGroups {
                self.addStackGroup(group, to: menu)
            }
        } else {
            for stack in visible {
                self.addStackRow(stack, to: menu)
            }
        }

        // Expand-all escape hatch: filtered-out stacks stay reachable (and actionable)
        // under a submenu, so the user can e.g. redeploy a healthy hidden stack.
        if self.store.hiddenStackCount > 0 {
            self.addHiddenSection(to: menu)
        }
    }

    /// "Show N hidden" — hidden non-running stacks (down/stopped/…) listed directly so
    /// problems surface, with the healthy/running ones tucked under a nested submenu.
    private func addHiddenSection(to menu: NSMenu) {
        let parent = NSMenuItem()
        parent.title = "Show \(self.store.hiddenStackCount) hidden"
        parent.attributedTitle = NSAttributedString(
            string: "Show \(self.store.hiddenStackCount) hidden",
            attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            ],
        )
        let sub = NSMenu()
        let hidden = self.store.hiddenStacks
        // Problems (down/dead/unhealthy/…) listed directly; the benign buckets —
        // stopped and running — collapse into their own nested submenus.
        for stack in hidden where stack.state != .running && stack.state != .stopped {
            self.addStackRow(stack, to: sub)
        }
        self.addNestedStackGroup("Stopped", .warning, hidden.filter { $0.state == .stopped }, to: sub)
        self.addNestedStackGroup("Running", .healthy, hidden.filter { $0.state == .running }, to: sub)
        parent.submenu = sub
        menu.addItem(parent)
    }

    /// Collapse a bucket of stacks into a "<Title> (N) ▸" nested submenu, prefixed by
    /// a separator when the parent already has rows. No-op for an empty bucket.
    private func addNestedStackGroup(
        _ title: String,
        _ severity: HealthSeverity,
        _ stacks: [StackListItem],
        to menu: NSMenu,
    ) {
        guard !stacks.isEmpty else { return }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        let parent = NSMenuItem()
        parent.title = "\(title) (\(stacks.count))"
        parent.attributedTitle = self.row(severity, "\(title) (\(stacks.count))", secondary: nil)
        let sub = NSMenu()
        for stack in stacks {
            self.addStackRow(stack, to: sub)
        }
        parent.submenu = sub
        menu.addItem(parent)
    }

    private func addUpdatesSection(to menu: NSMenu) {
        let plural = self.store.updateCount == 1 ? "" : "s"
        let parent = NSMenuItem()
        parent.attributedTitle = self.row(
            .warning,
            "⬆ \(self.store.updateCount) update\(plural) available",
            secondary: nil,
        )
        let sub = NSMenu()
        let updateAll = NSMenuItem(
            title: "Update All (\(self.store.updateCount))…",
            action: #selector(self.updateAll),
            keyEquivalent: "",
        )
        updateAll.target = self
        sub.addItem(updateAll)
        sub.addItem(.separator())
        for stack in self.store.stacksWithUpdates {
            let item = NSMenuItem()
            item.title = stack.name
            // Surface the server node alongside the services with a pending update.
            let server = self.store.servers.first { $0.id == stack.info.serverId }?.name
            let services = stack.servicesWithUpdate.joined(separator: ", ")
            let detail = [server, services.isEmpty ? nil : services].compactMap(\.self).joined(separator: " · ")
            item.attributedTitle = self.row(stack.state.severity, stack.name, secondary: detail.isEmpty ? nil : detail)
            item.submenu = self.stackSubmenu(for: stack)
            sub.addItem(item)
        }
        parent.submenu = sub
        menu.addItem(parent)
    }

    /// A per-server group header with a rollup badge, stacks nested in its submenu.
    private func addStackGroup(_ group: StackGroup, to menu: NSMenu) {
        let running = group.stacks.count(where: { $0.state == .running })
        let updates = group.stacks.filter(\.updateAvailable).count
        var badge = "\(running)/\(group.stacks.count)"
        if updates > 0 { badge += " ⬆\(updates)" }

        let severity: HealthSeverity = if group.stacks.contains(where: { $0.state.severity == .error }) {
            .error
        } else if group.stacks.allSatisfy({ $0.state == .running }) {
            .healthy
        } else {
            .warning
        }

        let parent = NSMenuItem()
        parent.title = group.serverName // type-select jumps to a server group
        parent.attributedTitle = self.row(severity, group.serverName, secondary: badge)
        let sub = NSMenu()
        if group.serverId != nil {
            let batch = NSMenuItem(
                title: "Redeploy all on \(group.serverName)…",
                action: #selector(self.redeployServerStacks(_:)),
                keyEquivalent: "",
            )
            batch.target = self
            batch.representedObject = group
            sub.addItem(batch)
            sub.addItem(.separator())
        }
        for stack in group.stacks {
            self.addStackRow(stack, to: sub)
        }
        parent.submenu = sub
        menu.addItem(parent)
    }

    /// One stack row: bare `title` for type-select, coloured `attributedTitle` for
    /// display, and the action submenu.
    func addStackRow(_ stack: StackListItem, to menu: NSMenu) {
        let item = NSMenuItem()
        item.title = stack.name // bare name drives NSMenu type-select
        var label = stack.state.displayName
        if stack.updateAvailable { label += " · ⬆ update" }
        let name = "\(self.suppressionPrefix(stack.id))\(stack.name)"
        item.attributedTitle = self.row(stack.state.severity, name, secondary: label)
        item.submenu = self.stackSubmenu(for: stack)
        menu.addItem(item)
    }

    /// Empty-stack-list copy, aware of why the list is empty.
    private func emptyStacksMessage() -> String {
        if self.store.stacks.isEmpty { return "No stacks" }
        if self.store.stackFilter == .onlyProblems { return "No problems — all stacks healthy" }
        return "All stacks hidden by filter"
    }

    private func stackSubmenu(for stack: StackListItem) -> NSMenu {
        let sub = NSMenu()
        if let status = stack.info.status, !status.isEmpty {
            self.addInfo(to: sub, status, secondary: true)
        }
        if stack.updateAvailable {
            self.addInfo(to: sub, "Updates: \(stack.servicesWithUpdate.joined(separator: ", "))", secondary: true)
        }
        if sub.numberOfItems > 0 { sub.addItem(.separator()) }

        for (title, selector) in [
            ("Update (deploy if changed)", #selector(self.stackUpdate(_:))),
            ("Force Redeploy…", #selector(self.stackDeploy(_:))),
            ("Pull Images", #selector(self.stackPull(_:))),
            ("Restart…", #selector(self.stackRestart(_:))),
            ("Check for Updates", #selector(self.stackCheck(_:))),
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = stack
            sub.addItem(item)
        }
        sub.addItem(.separator())
        let pin = NSMenuItem(
            title: self.store.isPinned(stack.id) ? "Unpin" : "Pin to Quick Access",
            action: #selector(self.stackTogglePin(_:)),
            keyEquivalent: "",
        )
        pin.target = self
        pin.representedObject = stack
        sub.addItem(pin)
        self.addMuteItems(forId: stack.id, to: sub)
        if self.store.dashboardBaseURL != nil {
            let open = NSMenuItem(
                title: "Open in Komodo",
                action: #selector(self.openStackInKomodo(_:)),
                keyEquivalent: "",
            )
            open.target = self
            open.representedObject = stack
            sub.addItem(open)
        }
        return sub
    }

    func addFooter(to menu: NSMenu) {
        menu.addItem(.separator())
        if self.store.dashboardBaseURL != nil {
            self.addAction(to: menu, "Open Komodo Dashboard", #selector(self.openDashboard))
        }
        if self.updater.canCheckForUpdates {
            self.addAction(to: menu, "Check for Updates…", #selector(self.checkAppUpdates))
        }
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(withTitle: "Quit KomodoBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}
