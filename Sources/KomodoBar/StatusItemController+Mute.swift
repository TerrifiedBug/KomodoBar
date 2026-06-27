import AppKit

/// Per-resource Mute / Snooze, so the red icon means "unacknowledged" rather than
/// "that one box you know about is still down".
@MainActor
extension StatusItemController {
    /// Append Mute/Unmute + Snooze (or Clear snooze) items for a resource id.
    func addMuteItems(forId id: String, to menu: NSMenu) {
        let mute = NSMenuItem(
            title: self.store.isMuted(id) ? "Unmute" : "Mute",
            action: #selector(self.toggleMute(_:)),
            keyEquivalent: "",
        )
        mute.target = self
        mute.representedObject = id
        menu.addItem(mute)

        if self.store.isSnoozed(id) {
            let clear = NSMenuItem(title: "Clear snooze", action: #selector(self.clearSnooze(_:)), keyEquivalent: "")
            clear.target = self
            clear.representedObject = id
            menu.addItem(clear)
        } else {
            let parent = NSMenuItem(title: "Snooze", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (label, seconds) in [("1 hour", 3600), ("8 hours", 28800), ("1 day", 86400)] {
                let item = NSMenuItem(title: label, action: #selector(self.snoozeResource(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
                item.tag = seconds
                sub.addItem(item)
            }
            parent.submenu = sub
            menu.addItem(parent)
        }
    }

    /// A bell glyph for muted/snoozed rows, so suppression is never hidden.
    func suppressionPrefix(_ id: String) -> String {
        self.store.isSuppressed(id) ? "🔕 " : ""
    }

    @objc func toggleMute(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        self.store.toggleMute(id)
    }

    @objc func clearSnooze(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        self.store.clearSnooze(id)
    }

    @objc func snoozeResource(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        self.store.snooze(id, seconds: TimeInterval(sender.tag))
    }
}
