import Foundation
import KomodoBarCore

/// Resource actions — each fires through `run`/`runBatch` (defined on the store)
/// and re-polls so the new state is observed. Kept here so the core view-model
/// stays under the type-length limit.
@MainActor
extension KomodoStore {
    // MARK: Stack actions

    func deploy(_ stack: StackListItem) {
        self.noteRecent(stack.id)
        self.run("Redeploy \(stack.name)") { try await $0.deployStack(stack.id) }
    }

    /// Apply a pending update to one stack — deploys only if its content changed,
    /// so an already-current stack is left untouched (no downtime).
    func deployIfChanged(_ stack: StackListItem) {
        self.noteRecent(stack.id)
        self.run("Update \(stack.name)") { try await $0.deployStackIfChanged(stack.id) }
    }

    /// Apply all pending updates in one shot — Core redeploys only the stacks whose
    /// content actually changed, leaving the rest running.
    func updateAll() {
        self.run("Update all stacks") { try await $0.batchDeployStackIfChanged() }
    }

    func pull(_ stack: StackListItem) {
        self.noteRecent(stack.id)
        self.run("Pull \(stack.name)") { try await $0.pullStack(stack.id) }
    }

    func restart(_ stack: StackListItem) {
        self.noteRecent(stack.id)
        self.run("Restart \(stack.name)") { try await $0.restartStack(stack.id) }
    }

    func checkForUpdate(_ stack: StackListItem) {
        self.noteRecent(stack.id)
        self.run("Check \(stack.name)") { _ = try await $0.checkStackForUpdate(stack.id) }
    }

    /// Mark an alert resolved in Komodo, then re-poll so it drops off the list.
    func acknowledge(_ alert: AlertItem) {
        guard !alert.id.isEmpty else { return }
        self.run("Acknowledge alert") { try await $0.closeAlert(alert.id) }
    }

    func redeployAll() {
        self.run("Redeploy all stacks") { try await $0.redeployAllStacks() }
    }

    // MARK: Deployment actions (single managed containers)

    func deploy(_ deployment: DeploymentListItem) {
        self.run("Deploy \(deployment.name)") { try await $0.deployDeployment(deployment.id) }
    }

    func start(_ deployment: DeploymentListItem) {
        self.run("Start \(deployment.name)") { try await $0.startDeployment(deployment.id) }
    }

    func stop(_ deployment: DeploymentListItem) {
        self.run("Stop \(deployment.name)") { try await $0.stopDeployment(deployment.id) }
    }

    func restart(_ deployment: DeploymentListItem) {
        self.run("Restart \(deployment.name)") { try await $0.restartDeployment(deployment.id) }
    }

    // MARK: Procedure / Action launcher

    func runProcedure(_ item: ExecResourceItem) {
        self.run("Run \(item.name)") { try await $0.runProcedure(item.id) }
    }

    func runAction(_ item: ExecResourceItem) {
        self.run("Run \(item.name)") { try await $0.runAction(item.id) }
    }

    // MARK: Batch actions

    func checkAllForUpdates() {
        self.runBatch("Check all stacks", self.stacks.map(\.id)) { try await $0.checkStackForUpdate($1) }
    }

    /// Stacks genuinely broken right now — the targets for "Redeploy unhealthy".
    var unhealthyStacks: [StackListItem] {
        self.stacks.filter { $0.state == .unhealthy || $0.state == .dead }
    }

    func redeployUnhealthy() {
        self.runBatch("Redeploy unhealthy", self.unhealthyStacks.map(\.id)) { try await $0.deployStack($1) }
    }

    func redeployStacks(onServer serverId: String, named serverName: String) {
        let ids = self.stacks.filter { $0.info.serverId == serverId }.map(\.id)
        self.runBatch("Redeploy on \(serverName)", ids) { try await $0.deployStack($1) }
    }
}
