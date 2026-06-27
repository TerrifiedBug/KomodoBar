import AppKit
import KomodoBarCore

/// Deployments (single managed containers) section + the raw-container rollup.
/// Both close the "container-only user" gap without rendering hundreds of rows.
@MainActor
extension StatusItemController {
    func addDeployments(to menu: NSMenu) {
        guard !self.store.deployments.isEmpty else { return }
        let summary = self.store.deploymentsSummary
        let header = summary.map { "Deployments — \($0.running)/\($0.total) running" } ?? "Deployments"
        self.addInfo(to: menu, header)
        for deployment in self.store.deployments {
            let item = NSMenuItem()
            item.title = deployment.name // type-select
            item.attributedTitle = self.row(
                deployment.state.severity,
                deployment.name,
                secondary: deployment.state.displayName,
            )
            item.submenu = self.deploymentSubmenu(for: deployment)
            menu.addItem(item)
        }
        menu.addItem(.separator())
    }

    /// A single glanceable rollup of every raw Docker container across servers — at
    /// hundreds-of-containers scale the answer is the count + broken bucket, not a list.
    func addContainersRollup(to menu: NSMenu) {
        guard let summary = self.store.containersSummary, summary.total > 0 else { return }
        var detail = "\(summary.running)/\(summary.total) running"
        if summary.unhealthy > 0 { detail += " · \(summary.unhealthy) unhealthy" }
        let severity: HealthSeverity = summary.unhealthy > 0 ? .error : .healthy
        let item = NSMenuItem()
        item.attributedTitle = self.row(severity, "Containers", secondary: detail)
        item.isEnabled = false
        menu.addItem(item)
        menu.addItem(.separator())
    }

    private func deploymentSubmenu(for deployment: DeploymentListItem) -> NSMenu {
        let sub = NSMenu()
        if let status = deployment.info.status, !status.isEmpty {
            self.addInfo(to: sub, status, secondary: true)
        }
        if let image = deployment.info.image, !image.isEmpty {
            self.addInfo(to: sub, image, secondary: true)
        }
        if sub.numberOfItems > 0 { sub.addItem(.separator()) }

        for (title, selector) in [
            ("Deploy…", #selector(self.deploymentDeploy(_:))),
            ("Start", #selector(self.deploymentStart(_:))),
            ("Stop…", #selector(self.deploymentStop(_:))),
            ("Restart…", #selector(self.deploymentRestart(_:))),
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = deployment
            sub.addItem(item)
        }
        if self.store.dashboardBaseURL != nil {
            sub.addItem(.separator())
            let open = NSMenuItem(
                title: "Open in Komodo",
                action: #selector(self.openDeploymentInKomodo(_:)),
                keyEquivalent: "",
            )
            open.target = self
            open.representedObject = deployment
            sub.addItem(open)
        }
        return sub
    }

    // MARK: Actions

    @objc func deploymentDeploy(_ sender: NSMenuItem) {
        guard let deployment = sender.representedObject as? DeploymentListItem else { return }
        guard self.confirm(
            "Deploy \(deployment.name)?",
            "Recreates the container and may cause brief downtime.",
            "Deploy",
        )
        else { return }
        self.store.deploy(deployment)
    }

    @objc func deploymentStart(_ sender: NSMenuItem) {
        guard let deployment = sender.representedObject as? DeploymentListItem else { return }
        self.store.start(deployment)
    }

    @objc func deploymentStop(_ sender: NSMenuItem) {
        guard let deployment = sender.representedObject as? DeploymentListItem else { return }
        guard self.confirm("Stop \(deployment.name)?", "Stops the running container.", "Stop") else { return }
        self.store.stop(deployment)
    }

    @objc func deploymentRestart(_ sender: NSMenuItem) {
        guard let deployment = sender.representedObject as? DeploymentListItem else { return }
        guard self.confirm("Restart \(deployment.name)?", "Restarts the running container.", "Restart") else { return }
        self.store.restart(deployment)
    }

    @objc func openDeploymentInKomodo(_ sender: NSMenuItem) {
        guard let deployment = sender.representedObject as? DeploymentListItem else { return }
        self.openKomodo(path: "deployments/\(deployment.id)")
    }
}
