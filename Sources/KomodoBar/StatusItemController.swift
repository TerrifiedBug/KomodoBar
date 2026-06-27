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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.behavior = .removalAllowed
        statusItem.autosaveName = "komodobar-main"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        updateButton()
        store.onChange = { [weak self] in self?.updateButton() }
    }

    // MARK: Status-bar button

    private func updateButton() {
        guard let button = statusItem.button else { return }

        let problems = store.needsAttention
        let attention = store.attentionCount
        let updates = store.updateCount

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
            title.append(NSAttributedString(string: " \(attention)", attributes: [.foregroundColor: NSColor.systemRed, .font: font]))
        }
        if updates > 0 {
            title.append(NSAttributedString(string: " ⬆\(updates)", attributes: [.foregroundColor: NSColor.systemOrange, .font: font]))
        }
        button.attributedTitle = title
        button.imagePosition = title.length > 0 ? .imageLeading : .imageOnly
        button.toolTip = statusTooltip()
    }

    /// One-line summary shown on hover, so the user gets the gist without opening
    /// the menu.
    private func statusTooltip() -> String {
        switch store.connection {
        case .unconfigured: return "KomodoBar — not connected"
        case .authFailed: return "KomodoBar — authentication failed"
        case .error(let message): return "KomodoBar — \(message)"
        case .ok:
            var parts: [String] = []
            if let stacks = store.stacksSummary { parts.append("\(stacks.running)/\(stacks.total) running") }
            if store.updateCount > 0 { parts.append("\(store.updateCount) update\(store.updateCount == 1 ? "" : "s")") }
            if store.attentionCount > 0 { parts.append("\(store.attentionCount) unhealthy") }
            if let servers = store.serversSummary { parts.append("servers \(servers.healthy)/\(servers.total)") }
            if let date = store.lastRefresh { parts.append("updated \(Self.timeFormatter.string(from: date))") }
            return parts.isEmpty ? "KomodoBar" : parts.joined(separator: " · ")
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        store.refreshNow() // freshen for next open; current open shows last snapshot

        addHeader(to: menu)
        menu.addItem(.separator())

        guard store.isConfigured else {
            addAction(to: menu, "Connect to Komodo…", #selector(openSettings))
            if case let .error(message) = store.connection { addInfo(to: menu, message, secondary: true) }
            addFooter(to: menu)
            return
        }

        if store.connection.isAuthFailed {
            addInfo(to: menu, "Authentication failed — check API key/secret in Settings.", secondary: true)
            addAction(to: menu, "Open Settings…", #selector(openSettings))
            addFooter(to: menu)
            return
        }

        addServers(to: menu)
        menu.addItem(.separator())
        addStacks(to: menu)
        menu.addItem(.separator())

        addAction(to: menu, "Check All Stacks for Updates", #selector(checkAll))
        addAction(to: menu, "Redeploy All Stacks…", #selector(redeployAll))
        addAction(to: menu, "Refresh Now", #selector(refresh))
        addFooter(to: menu)
    }

    private func addHeader(to menu: NSMenu) {
        let title = NSMenuItem()
        title.attributedTitle = NSAttributedString(
            string: "KomodoBar",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]
        )
        title.isEnabled = false
        menu.addItem(title)

        switch store.connection {
        case .ok:
            if let date = store.lastRefresh {
                addInfo(to: menu, "Updated \(Self.timeFormatter.string(from: date))", secondary: true)
            }
        case .error(let message):
            addInfo(to: menu, "⚠︎ \(message)", secondary: true)
        case .authFailed:
            addInfo(to: menu, "⚠︎ Authentication failed", secondary: true)
        case .unconfigured:
            addInfo(to: menu, "Not connected", secondary: true)
        }
        if let status = store.actionStatus {
            addInfo(to: menu, status, secondary: true)
        }
    }

    private func addServers(to menu: NSMenu) {
        let summary = store.serversSummary
        let header = summary.map { "Servers — \($0.healthy)/\($0.total) healthy" } ?? "Servers"
        addInfo(to: menu, header)
        if store.servers.isEmpty {
            addInfo(to: menu, "No servers", secondary: true)
        }
        for server in store.servers {
            var detail = server.state.displayName
            if let stats = store.serverStats[server.id] {
                detail += " · CPU \(Int(stats.cpuPerc.rounded()))%"
            } else if let region = server.info.region, !region.isEmpty {
                detail += " · \(region)"
            }
            let item = NSMenuItem()
            item.attributedTitle = row(server.state.severity, server.name, secondary: detail)
            item.submenu = serverSubmenu(for: server) // hover for CPU/mem/disk + sparkline
            menu.addItem(item)
        }
    }

    private func serverSubmenu(for server: ServerListItem) -> NSMenu {
        let submenu = NSMenu()
        let host = NSHostingView(rootView: ServerDetailView(
            version: server.info.version,
            address: server.info.address,
            stats: store.serverStats[server.id],
            cpuHistory: store.cpuHistory[server.id] ?? [],
            memHistory: store.memHistory[server.id] ?? [],
            diskHistory: store.diskHistory[server.id] ?? []
        ))
        host.frame = NSRect(x: 0, y: 0, width: 260, height: max(host.fittingSize.height, 60))
        let item = NSMenuItem()
        item.view = host
        submenu.addItem(item)
        return submenu
    }

    private func addStacks(to menu: NSMenu) {
        let summary = store.stacksSummary
        let header = summary.map { "Stacks — \($0.running)/\($0.total) running" } ?? "Stacks"
        addInfo(to: menu, header)

        // Surface pending updates prominently, above the (possibly filtered) list,
        // covering ALL stacks so a hidden one's update isn't missed.
        if store.updateCount > 0 {
            let plural = store.updateCount == 1 ? "" : "s"
            let parent = NSMenuItem()
            parent.attributedTitle = row(.warning, "⬆ \(store.updateCount) update\(plural) available", secondary: nil)
            let sub = NSMenu()
            for stack in store.stacksWithUpdates {
                let item = NSMenuItem()
                item.attributedTitle = row(stack.state.severity, stack.name, secondary: stack.servicesWithUpdate.joined(separator: ", "))
                item.submenu = stackSubmenu(for: stack)
                sub.addItem(item)
            }
            parent.submenu = sub
            menu.addItem(parent)
        }

        let visible = store.visibleStacks
        if visible.isEmpty {
            addInfo(to: menu, store.stacks.isEmpty ? "No stacks" : "All stacks hidden by filter", secondary: true)
        }
        for stack in visible {
            let item = NSMenuItem()
            var label = stack.state.displayName
            if stack.updateAvailable { label += " · ⬆ update" }
            item.attributedTitle = row(stack.state.severity, stack.name, secondary: label)
            item.submenu = stackSubmenu(for: stack)
            menu.addItem(item)
        }

        if store.hiddenStackCount > 0 {
            addInfo(to: menu, "\(store.hiddenStackCount) hidden (\(store.stackFilter.label.lowercased()))", secondary: true)
        }
    }

    private func stackSubmenu(for stack: StackListItem) -> NSMenu {
        let sub = NSMenu()
        if let status = stack.info.status, !status.isEmpty {
            addInfo(to: sub, status, secondary: true)
        }
        if stack.updateAvailable {
            addInfo(to: sub, "Updates: \(stack.servicesWithUpdate.joined(separator: ", "))", secondary: true)
        }
        if sub.numberOfItems > 0 { sub.addItem(.separator()) }

        for (title, selector) in [
            ("Redeploy…", #selector(stackDeploy(_:))),
            ("Pull Images", #selector(stackPull(_:))),
            ("Restart…", #selector(stackRestart(_:))),
            ("Check for Updates", #selector(stackCheck(_:))),
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = stack
            sub.addItem(item)
        }
        return sub
    }

    private func addFooter(to menu: NSMenu) {
        menu.addItem(.separator())
        if updater.canCheckForUpdates {
            addAction(to: menu, "Check for Updates…", #selector(checkAppUpdates))
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
        case .healthy: return .systemGreen
        case .warning: return .systemOrange
        case .error: return .systemRed
        case .unknown: return .systemGray
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: Actions

    /// Internal so AppDelegate can trigger it (e.g. for headless verification).
    func showSettings() { settingsWindow.show() }

    @objc private func openSettings() { showSettings() }

    @objc private func refresh() { store.refreshNow() }
    @objc private func checkAll() { store.checkAllForUpdates() }

    @objc private func redeployAll() {
        guard confirm("Redeploy all stacks?",
                      "This runs `docker compose up` on every stack and may cause brief downtime.",
                      "Redeploy All") else { return }
        store.redeployAll()
    }

    @objc private func stackDeploy(_ sender: NSMenuItem) {
        guard let stack = sender.representedObject as? StackListItem else { return }
        guard confirm("Redeploy \(stack.name)?", "Runs `docker compose up` and may cause brief downtime.", "Redeploy") else { return }
        store.deploy(stack)
    }

    @objc private func stackPull(_ sender: NSMenuItem) {
        guard let stack = sender.representedObject as? StackListItem else { return }
        store.pull(stack)
    }

    @objc private func stackRestart(_ sender: NSMenuItem) {
        guard let stack = sender.representedObject as? StackListItem else { return }
        guard confirm("Restart \(stack.name)?", "Runs `docker compose restart`.", "Restart") else { return }
        store.restart(stack)
    }

    @objc private func stackCheck(_ sender: NSMenuItem) {
        guard let stack = sender.representedObject as? StackListItem else { return }
        store.checkForUpdate(stack)
    }

    @objc private func checkAppUpdates() { updater.checkForUpdates() }

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
