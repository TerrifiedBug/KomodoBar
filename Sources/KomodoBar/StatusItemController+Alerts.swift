import AppKit
import KomodoBarCore

/// The Alerts section: unresolved Komodo alerts with one-tap Acknowledge.
@MainActor
extension StatusItemController {
    func addAlerts(to menu: NSMenu) {
        let unresolved = self.store.alerts.filter { !$0.resolved }
        guard !unresolved.isEmpty else { return }

        self.addInfo(to: menu, "Alerts — \(unresolved.count)")
        // Cap the inline list; the rest are reachable in the Komodo web UI. The
        // count above is honest about the full total.
        for alert in unresolved.prefix(10) {
            let name = self.store.resourceName(forType: alert.targetType, id: alert.targetId)
            let detail = KomodoStore.humanize(alert.kind)
            let item = NSMenuItem()
            item.title = name
            item.attributedTitle = self.row(alert.level.severity, name, secondary: detail)
            item.submenu = self.alertSubmenu(for: alert)
            menu.addItem(item)
        }
        if unresolved.count > 10 {
            self.addInfo(to: menu, "+\(unresolved.count - 10) more in Komodo", secondary: true)
        }
        menu.addItem(.separator())
    }

    private func alertSubmenu(for alert: AlertItem) -> NSMenu {
        let sub = NSMenu()
        self.addInfo(
            to: sub,
            "\(alert.level.displayName) · \(Self.timeFormatter.string(from: alert.date))",
            secondary: true,
        )
        sub.addItem(.separator())
        if !alert.id.isEmpty {
            let ack = NSMenuItem(title: "Acknowledge", action: #selector(self.acknowledgeAlert(_:)), keyEquivalent: "")
            ack.target = self
            ack.representedObject = alert
            sub.addItem(ack)
        }
        let linkable = alert.targetType == "Stack" || alert.targetType == "Server"
        if linkable, alert.targetId != nil, self.store.dashboardBaseURL != nil {
            let open = NSMenuItem(
                title: "Open in Komodo",
                action: #selector(self.openAlertTarget(_:)),
                keyEquivalent: "",
            )
            open.target = self
            open.representedObject = alert
            sub.addItem(open)
        }
        return sub
    }

    @objc func acknowledgeAlert(_ sender: NSMenuItem) {
        guard let alert = sender.representedObject as? AlertItem else { return }
        self.store.acknowledge(alert)
    }

    @objc func openAlertTarget(_ sender: NSMenuItem) {
        guard let alert = sender.representedObject as? AlertItem,
              let type = alert.targetType, let id = alert.targetId else { return }
        let path = type == "Server" ? "servers/\(id)" : "stacks/\(id)"
        self.openKomodo(path: path)
    }
}
