import AppKit
import KomodoBarCore

/// The "Run ▸" launcher: fire Komodo Procedures and Actions from the menu bar,
/// each with a leading ok/running/failed dot from its last run.
@MainActor
extension StatusItemController {
    func addRunMenu(to menu: NSMenu) {
        guard !self.store.procedures.isEmpty || !self.store.actions.isEmpty else { return }
        let parent = NSMenuItem(title: "Run", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if !self.store.procedures.isEmpty {
            self.addInfo(to: sub, "Procedures")
            for procedure in self.store.procedures {
                sub.addItem(self.runItem(procedure, selector: #selector(self.runProcedure(_:))))
            }
        }
        if !self.store.actions.isEmpty {
            if sub.numberOfItems > 0 { sub.addItem(.separator()) }
            self.addInfo(to: sub, "Actions")
            for action in self.store.actions {
                sub.addItem(self.runItem(action, selector: #selector(self.runAction(_:))))
            }
        }
        parent.submenu = sub
        menu.addItem(parent)
        menu.addItem(.separator())
    }

    private func runItem(_ item: ExecResourceItem, selector: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: item.name, action: selector, keyEquivalent: "")
        menuItem.attributedTitle = self.row(item.state.severity, item.name, secondary: nil)
        menuItem.title = item.name // type-select
        menuItem.target = self
        menuItem.representedObject = item
        return menuItem
    }

    @objc func runProcedure(_ sender: NSMenuItem) {
        guard let procedure = sender.representedObject as? ExecResourceItem else { return }
        guard self.confirm("Run \(procedure.name)?", "Runs this Komodo procedure now.", "Run") else { return }
        self.store.runProcedure(procedure)
    }

    @objc func runAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ExecResourceItem else { return }
        guard self.confirm("Run \(action.name)?", "Runs this Komodo action now.", "Run") else { return }
        self.store.runAction(action)
    }
}
