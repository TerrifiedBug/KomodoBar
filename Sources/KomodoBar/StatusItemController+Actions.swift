import AppKit
import KomodoBarCore

/// Menu action handlers. Selectors are referenced via `#selector` from the menu
/// builders in other files, so these are module-internal rather than `private`.
@MainActor
extension StatusItemController {
    /// Internal so AppDelegate can trigger it (e.g. for headless verification).
    func showSettings() {
        self.settingsWindow.show()
    }

    @objc func openSettings() {
        self.showSettings()
    }

    @objc func refresh() {
        self.store.refreshNow()
    }

    @objc func checkAll() {
        self.store.checkAllForUpdates()
    }

    @objc func redeployAll() {
        guard self.confirm(
            "Redeploy all stacks?",
            "This runs `docker compose up` on every stack and may cause brief downtime.",
            "Redeploy All",
        ) else { return }
        self.store.redeployAll()
    }

    @objc func updateAll() {
        guard self.confirm(
            "Update all stacks with pending updates?",
            "Redeploys only the stacks whose images/compose changed — others keep running. The changed ones may have brief downtime.",
            "Update All",
        ) else { return }
        self.store.updateAll()
    }

    /// Apply a pending update to one stack. No confirmation: it's the safe path —
    /// an unchanged stack is a no-op, so it can't cause surprise downtime.
    @objc func stackUpdate(_ sender: NSMenuItem) {
        guard let stack = sender.representedObject as? StackListItem else { return }
        self.store.deployIfChanged(stack)
    }

    @objc func stackDeploy(_ sender: NSMenuItem) {
        guard let stack = sender.representedObject as? StackListItem else { return }
        guard self.confirm(
            "Force redeploy \(stack.name)?",
            "Runs `docker compose up` and may cause brief downtime.",
            "Redeploy",
        ) else { return }
        self.store.deploy(stack)
    }

    @objc func stackPull(_ sender: NSMenuItem) {
        guard let stack = sender.representedObject as? StackListItem else { return }
        self.store.pull(stack)
    }

    @objc func stackRestart(_ sender: NSMenuItem) {
        guard let stack = sender.representedObject as? StackListItem else { return }
        guard self.confirm("Restart \(stack.name)?", "Runs `docker compose restart`.", "Restart") else { return }
        self.store.restart(stack)
    }

    @objc func stackCheck(_ sender: NSMenuItem) {
        guard let stack = sender.representedObject as? StackListItem else { return }
        self.store.checkForUpdate(stack)
    }

    @objc func stackTogglePin(_ sender: NSMenuItem) {
        guard let stack = sender.representedObject as? StackListItem else { return }
        self.store.togglePin(stack.id)
    }

    @objc func checkAppUpdates() {
        self.updater.checkForUpdates()
    }

    @objc func openStackInKomodo(_ sender: NSMenuItem) {
        guard let stack = sender.representedObject as? StackListItem else { return }
        self.openKomodo(path: "stacks/\(stack.id)")
    }

    @objc func openServerInKomodo(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? ServerListItem else { return }
        self.openKomodo(path: "servers/\(server.id)")
    }

    @objc func openDashboard() {
        self.openKomodo(path: nil)
    }

    /// Open a path on the connected Komodo instance in the default browser. Falls
    /// back to the dashboard root if the resource path can't be built (e.g. behind
    /// a reverse proxy that rewrites routes).
    func openKomodo(path: String?) {
        guard let base = store.dashboardBaseURL else { return }
        let url = path.map { base.appendingPathComponent($0) } ?? base
        NSWorkspace.shared.open(url)
    }

    func confirm(_ title: String, _ info: String, _ confirmButton: String) -> Bool {
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
