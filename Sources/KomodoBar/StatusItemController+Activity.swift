import AppKit
import KomodoBarCore

/// Recent Activity: a bounded, glanceable history of Komodo operations with a
/// success/failure dot — "what changed and when", which a live snapshot can't show.
@MainActor
extension StatusItemController {
    func addRecentActivity(to menu: NSMenu) {
        guard !self.store.recentUpdates.isEmpty else { return }
        menu.addItem(.separator())
        let parent = NSMenuItem(title: "Recent Activity", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for update in self.store.recentUpdates.prefix(15) {
            let operation = KomodoStore.humanize(update.operation)
            let name = self.store.resourceName(forType: update.targetType, id: update.targetId)
            let title = (name == "Resource" || name.isEmpty) ? operation : "\(operation) · \(name)"
            let item = NSMenuItem()
            item.attributedTitle = self.row(
                update.severity,
                title,
                secondary: Self.timeFormatter.string(from: update.date),
            )
            item.isEnabled = false
            sub.addItem(item)
        }
        parent.submenu = sub
        menu.addItem(parent)
    }
}
