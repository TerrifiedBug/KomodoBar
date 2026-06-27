import AppKit
import KomodoBarCore
import SwiftUI

/// Owns the menu-bar `NSStatusItem` and rebuilds its menu from `KomodoStore`
/// each time it opens.
///
/// Menu construction lives in `StatusItemController+Menu`; action handlers in
/// `StatusItemController+Actions`. Shared menu primitives (`addInfo`, `addAction`,
/// `row`) and the stored dependencies are module-internal so those extensions can
/// reach them across files.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    let statusItem: NSStatusItem
    let store: KomodoStore
    let updater: any UpdaterProviding
    let settingsWindow = SettingsWindowController()

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

        self.addAlerts(to: menu) // adds its own trailing separator when non-empty
        self.addQuickAccess(to: menu) // adds its own trailing separator when non-empty
        self.addServers(to: menu)
        menu.addItem(.separator())
        self.addStacks(to: menu)
        menu.addItem(.separator())
        self.addDeployments(to: menu) // self-guards + adds its own trailing separator
        self.addContainersRollup(to: menu)
        self.addRunMenu(to: menu)

        self.addAction(to: menu, "Check All Stacks for Updates", #selector(self.checkAll))
        self.addAction(to: menu, "Redeploy All Stacks…", #selector(self.redeployAll))
        self.addAction(to: menu, "Refresh Now", #selector(self.refresh))
        self.addFooter(to: menu)
    }

    // MARK: Shared menu primitives

    func addInfo(to menu: NSMenu, _ text: String, secondary: Bool = false) {
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
    func addAction(to menu: NSMenu, _ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    /// A coloured status dot + label, with an optional secondary detail string.
    func row(_ severity: HealthSeverity, _ text: String, secondary: String?) -> NSAttributedString {
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

    static func color(for severity: HealthSeverity) -> NSColor {
        switch severity {
        case .healthy: .systemGreen
        case .warning: .systemOrange
        case .error: .systemRed
        case .unknown: .systemGray
        }
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
