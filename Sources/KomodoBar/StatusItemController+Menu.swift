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
            item.attributedTitle = self.row(server.state.severity, server.name, secondary: detail)
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
        if self.store.dashboardBaseURL != nil {
            submenu.addItem(.separator())
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
        }
        for stack in visible {
            self.addStackRow(stack, to: menu)
        }

        // Expand-all escape hatch: filtered-out stacks stay reachable (and actionable)
        // under a submenu, so the user can e.g. redeploy a healthy hidden stack.
        if self.store.hiddenStackCount > 0 {
            let parent = NSMenuItem()
            parent.title = "Show \(self.store.hiddenStackCount) hidden"
            parent.attributedTitle = NSAttributedString(
                string: "Show \(self.store.hiddenStackCount) hidden (\(self.store.stackFilter.label.lowercased()))",
                attributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                ],
            )
            let sub = NSMenu()
            for stack in self.store.hiddenStacks {
                self.addStackRow(stack, to: sub)
            }
            parent.submenu = sub
            menu.addItem(parent)
        }
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
            item.attributedTitle = self.row(
                stack.state.severity,
                stack.name,
                secondary: stack.servicesWithUpdate.joined(separator: ", "),
            )
            item.submenu = self.stackSubmenu(for: stack)
            sub.addItem(item)
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
        item.attributedTitle = self.row(stack.state.severity, stack.name, secondary: label)
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
        if self.store.dashboardBaseURL != nil {
            sub.addItem(.separator())
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
