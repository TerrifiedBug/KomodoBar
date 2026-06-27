import AppKit
import KomodoBarCore
import SwiftUI

/// Owns the menu-bar `NSStatusItem` and rebuilds its menu from `KomodoStore`
/// each time it opens.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let store: KomodoStore
    private let updater: any UpdaterProviding
    private let settingsWindow = SettingsWindowController()

    init(store: KomodoStore, updater: any UpdaterProviding) {
        self.store = store
        self.updater = updater
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        self.statusItem.behavior = .removalAllowed
        self.statusItem.autosaveName = "komodobar-main"

        let menu = NSMenu()
        menu.delegate = self
        self.statusItem.menu = menu

        self.updateButton()
        store.onChange = { [weak self] in self?.updateButton() }
    }

    // MARK: Status-bar button

    private func updateButton() {
        guard let button = statusItem.button else { return }

        let problems = self.store.needsAttention
        let attention = self.store.attentionCount
        let updates = self.store.updateCount

        // Colour the lizard by overall status: red problems > orange updates > green.
        // Palette config bakes the colour into the image so contentTintColor stays
        // out of the way and the title can use its own (readable) colours.
        let lizardColor: NSColor = problems ? .systemRed : (updates > 0 ? .systemOrange : .systemGreen)
        let base = NSImage(systemSymbolName: "lizard.fill", accessibilityDescription: "KomodoBar")
            ?? NSImage(systemSymbolName: "shippingbox.fill", accessibilityDescription: "KomodoBar")
        let colored = base?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [lizardColor]))
        colored?.isTemplate = false
        button.image = colored
        button.contentTintColor = nil

        // Title surfaces BOTH the attention count (red) and the update count (orange),
        // each with an explicit colour so it reads on light or dark menu bars.
        let title = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        if attention > 0 {
            title.append(NSAttributedString(
                string: " \(attention)",
                attributes: [.foregroundColor: NSColor.systemRed, .font: font],
            ))
        }
        if updates > 0 {
            title.append(NSAttributedString(
                string: " ⬆\(updates)",
                attributes: [.foregroundColor: NSColor.systemOrange, .font: font],
            ))
        }
        button.attributedTitle = title
        button.imagePosition = title.length > 0 ? .imageLeading : .imageOnly
        button.toolTip = self.statusTooltip()
    }

    /// One-line summary shown on hover, so the user gets the gist without opening
    /// the menu.
    private func statusTooltip() -> String {
        switch self.store.connection {
        case .unconfigured: return "KomodoBar — not connected"
        case .authFailed: return "KomodoBar — authentication failed"
        case let .error(message): return "KomodoBar — \(message)"
        case .ok:
            var parts: [String] = []
            if let stacks = store.stacksSummary { parts.append("\(stacks.running)/\(stacks.total) running") }
            if self.store
                .updateCount >
                0 { parts.append("\(self.store.updateCount) update\(self.store.updateCount == 1 ? "" : "s")") }
            if self.store.attentionCount > 0 { parts.append("\(self.store.attentionCount) unhealthy") }
            if let servers = store.serversSummary { parts.append("servers \(servers.healthy)/\(servers.total)") }
            if let date = store.lastRefresh { parts.append("updated \(Self.timeFormatter.string(from: date))") }
            return parts.isEmpty ? "KomodoBar" : parts.joined(separator: " · ")
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        self.store.refreshNow() // freshen for next open; current open shows last snapshot

        self.addHeader(to: menu)
        menu.addItem(.separator())

        guard self.store.isConfigured else {
            self.addAction(to: menu, "Connect to Komodo…", #selector(self.openSettings))
            if case let .error(message) = store.connection { self.addInfo(to: menu, message, secondary: true) }
            self.addFooter(to: menu)
            return
        }

        if self.store.connection.isAuthFailed {
            self.addInfo(to: menu, "Authentication failed — check API key/secret in Settings.", secondary: true)
            self.addAction(to: menu, "Open Settings…", #selector(self.openSettings))
            self.addFooter(to: menu)
            return
        }

        self.addServers(to: menu)
        menu.addItem(.separator())
        self.addStacks(to: menu)
        menu.addItem(.separator())

        self.addAction(to: menu, "Check All Stacks for Updates", #selector(self.checkAll))
        self.addAction(to: menu, "Redeploy All Stacks…", #selector(self.redeployAll))
        self.addAction(to: menu, "Refresh Now", #selector(self.refresh))
        self.addFooter(to: menu)
    }

    private func addHeader(to menu: NSMenu) {
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

    private func addServers(to menu: NSMenu) {
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

    private func addStacks(to menu: NSMenu) {
        let summary = self.store.stacksSummary
        let header = summary.map { "Stacks — \($0.running)/\($0.total) running" } ?? "Stacks"
        self.addInfo(to: menu, header)

        // Surface pending updates prominently, above the (possibly filtered) list,
        // covering ALL stacks so a hidden one's update isn't missed.
        if self.store.updateCount > 0 {
            let plural = self.store.updateCount == 1 ? "" : "s"
            let parent = NSMenuItem()
            parent.attributedTitle = self.row(
                .warning,
                "⬆ \(self.store.updateCount) update\(plural) available",
                secondary: nil,
            )
            let sub = NSMenu()
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

    /// One stack row: bare `title` for type-select, coloured `attributedTitle` for
    /// display, and the action submenu.
    private func addStackRow(_ stack: StackListItem, to menu: NSMenu) {
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
            ("Redeploy…", #selector(self.stackDeploy(_:))),
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

    private func addFooter(to menu: NSMenu) {
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

    // MARK: Menu-building helpers

    private func addInfo(to menu: NSMenu, _ text: String, secondary: Bool = false) {
        let item = NSMenuItem()
        if secondary {
            item.attributedTitle = NSAttributedString(string: text, attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            ])
        } else {
            item.title = text
        }
        item.isEnabled = false
        menu.addItem(item)
    }

    @discardableResult
    private func addAction(to menu: NSMenu, _ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func row(_ severity: HealthSeverity, _ text: String, secondary: String?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: Self.color(for: severity)]))
        result.append(NSAttributedString(string: text, attributes: [.foregroundColor: NSColor.labelColor]))
        if let secondary {
            result.append(NSAttributedString(string: "   \(secondary)", attributes: [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
            ]))
        }
        return result
    }

    private static func color(for severity: HealthSeverity) -> NSColor {
        switch severity {
        case .healthy: .systemGreen
        case .warning: .systemOrange
        case .error: .systemRed
        case .unknown: .systemGray
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: Actions

    /// Internal so AppDelegate can trigger it (e.g. for headless verification).
    func showSettings() {
        self.settingsWindow.show()
    }

    @objc private func openSettings() {
        self.showSettings()
    }

    @objc private func refresh() {
        self.store.refreshNow()
    }

    @objc private func checkAll() {
        self.store.checkAllForUpdates()
    }

    @objc private func redeployAll() {
        guard self.confirm(
            "Redeploy all stacks?",
            "This runs `docker compose up` on every stack and may cause brief downtime.",
            "Redeploy All",
        ) else { return }
        self.store.redeployAll()
    }

    @objc private func stackDeploy(_ sender: NSMenuItem) {
        guard let stack = sender.representedObject as? StackListItem else { return }
        guard self.confirm(
            "Redeploy \(stack.name)?",
            "Runs `docker compose up` and may cause brief downtime.",
            "Redeploy",
        ) else { return }
        self.store.deploy(stack)
    }

    @objc private func stackPull(_ sender: NSMenuItem) {
        guard let stack = sender.representedObject as? StackListItem else { return }
        self.store.pull(stack)
    }

    @objc private func stackRestart(_ sender: NSMenuItem) {
        guard let stack = sender.representedObject as? StackListItem else { return }
        guard self.confirm("Restart \(stack.name)?", "Runs `docker compose restart`.", "Restart") else { return }
        self.store.restart(stack)
    }

    @objc private func stackCheck(_ sender: NSMenuItem) {
        guard let stack = sender.representedObject as? StackListItem else { return }
        self.store.checkForUpdate(stack)
    }

    @objc private func checkAppUpdates() {
        self.updater.checkForUpdates()
    }

    @objc private func openStackInKomodo(_ sender: NSMenuItem) {
        guard let stack = sender.representedObject as? StackListItem else { return }
        self.open(path: "stacks/\(stack.id)")
    }

    @objc private func openServerInKomodo(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? ServerListItem else { return }
        self.open(path: "servers/\(server.id)")
    }

    @objc private func openDashboard() {
        self.open(path: nil)
    }

    /// Open a path on the connected Komodo instance in the default browser. Falls
    /// back to the dashboard root if the resource path can't be built (e.g. behind
    /// a reverse proxy that rewrites routes).
    private func open(path: String?) {
        guard let base = store.dashboardBaseURL else { return }
        let url = path.map { base.appendingPathComponent($0) } ?? base
        NSWorkspace.shared.open(url)
    }

    private func confirm(_ title: String, _ info: String, _ confirmButton: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmButton)
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
