import Foundation
import KomodoBarCore
import Observation

/// Observable view-model that owns the Komodo client, polls health on a timer,
/// and runs actions. All mutable state is `@MainActor`; network work hops off the
/// main actor inside `KomodoClient`.
@MainActor
@Observable
final class KomodoStore {
    /// Shared instance used by both the menu (AppDelegate) and the Settings scene.
    static let shared = KomodoStore()

    enum Connection: Equatable {
        case unconfigured
        case ok
        case authFailed(String) // 401 — stop polling so we don't trip the lockout
        case error(String)

        var isAuthFailed: Bool {
            if case .authFailed = self { true } else { false }
        }
    }

    private(set) var connection: Connection = .unconfigured
    private(set) var serversSummary: ServersSummary?
    private(set) var stacksSummary: StacksSummary?
    private(set) var servers: [ServerListItem] = []
    private(set) var stacks: [StackListItem] = []
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    /// Transient feedback for the most recent action (shown in the menu).
    private(set) var actionStatus: String?
    /// Latest CPU/mem/disk per server id.
    private(set) var serverStats: [String: SystemStats] = [:]
    /// Rolling samples per server id, built from polls, for the sparklines.
    private(set) var cpuHistory: [String: [Double]] = [:]
    private(set) var memHistory: [String: [Double]] = [:]
    private(set) var diskHistory: [String: [Double]] = [:]
    private let historyLimit = 40

    /// Open (unresolved) Komodo alerts, newest first.
    private(set) var alerts: [AlertItem] = []

    /// Called after any state change so the status-bar icon can repaint.
    var onChange: (@MainActor () -> Void)?

    private var client: KomodoClient?
    private var pollTask: Task<Void, Never>?
    private var notifier: any NotifierProviding = DisabledNotifier()
    private let lastSeenAlertKey = "komodo.alerts.lastSeenTs"

    /// Seconds between polls. Persisted in UserDefaults; defaults to 30.
    var pollInterval: TimeInterval {
        get {
            let v = UserDefaults.standard.double(forKey: "komodo.pollInterval")
            return v > 0 ? v : 30
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "komodo.pollInterval")
            self.restartPolling()
        }
    }

    var isConfigured: Bool {
        self.client != nil
    }

    /// Genuinely unhealthy things worth a red alert. Excludes `down` stacks —
    /// those are often intentionally off (the user hides them), so counting them
    /// would keep the icon permanently red. Drives the icon tint + count.
    var attentionCount: Int {
        (self.serversSummary?.unhealthy ?? 0) + (self.stacksSummary?.unhealthy ?? 0)
    }

    /// An unresolved CRITICAL alert turns the icon red even when the summaries miss
    /// it — so the badge can't under-report a live incident.
    var hasCriticalAlert: Bool {
        self.alerts.contains { !$0.resolved && $0.level == .critical }
    }

    var needsAttention: Bool {
        self.attentionCount > 0 || self.connection.isAuthFailed || self.hasCriticalAlert
    }

    /// Whether to post macOS notifications for new alerts. Persisted; default on.
    var notificationsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "komodo.notify.enabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "komodo.notify.enabled"); self.notify() }
    }

    /// Only notify for alerts at this level and above. Persisted; default warning.
    var notifyThreshold: SeverityLevel {
        get {
            SeverityLevel(rawValue: UserDefaults.standard.string(forKey: "komodo.notify.threshold") ?? "") ?? .warning
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "komodo.notify.threshold"); self.notify() }
    }

    /// Resolve an alert target to a human name using the loaded stacks/servers.
    func resourceName(forType type: String?, id: String?) -> String {
        if let id {
            if let stack = stacks.first(where: { $0.id == id }) { return stack.name }
            if let server = servers.first(where: { $0.id == id }) { return server.name }
        }
        return type ?? id ?? "Resource"
    }

    /// Menu filter for the stack list (display-only; persisted).
    var stackFilter: StackFilter {
        get { StackFilter(rawValue: UserDefaults.standard.string(forKey: "komodo.stackFilter") ?? "") ?? .hideDown }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "komodo.stackFilter"); self.notify() }
    }

    /// Stacks shown in the menu after applying `stackFilter`.
    var visibleStacks: [StackListItem] {
        self.stacks.filter { self.stackFilter.includes($0.state) }
    }

    /// Stacks the current filter is hiding — surfaced under "Show N hidden" so the
    /// user can still act on (e.g. redeploy) a healthy stack the filter dropped.
    var hiddenStacks: [StackListItem] {
        self.stacks.filter { !self.stackFilter.includes($0.state) }
    }

    /// How many stacks the filter is hiding right now.
    var hiddenStackCount: Int {
        self.stacks.count - self.visibleStacks.count
    }

    /// Base URL of the connected Komodo instance, for "Open in Komodo" deep-links.
    var dashboardBaseURL: URL? {
        self.client?.credentials.baseURL
    }

    /// Stacks with a pending image update — surfaced regardless of the filter.
    var stacksWithUpdates: [StackListItem] {
        self.stacks.filter(\.updateAvailable)
    }

    var updateCount: Int {
        self.stacksWithUpdates.count
    }

    // MARK: Lifecycle

    func start() {
        self.notifier = makeNotifier()
        if self.notificationsEnabled { self.notifier.requestAuthorization() }
        self.reloadCredentials()
        self.restartPolling()
    }

    /// Re-read credentials from the store (after the user edits Settings).
    func reloadCredentials() {
        if let creds = CredentialStore.load() {
            self.client = KomodoClient(credentials: creds)
            if self.connection == .unconfigured || self.connection.isAuthFailed { self.connection = .ok }
        } else {
            self.client = nil
            self.connection = .unconfigured
            self.servers = []; self.stacks = []; self.serversSummary = nil; self.stacksSummary = nil
            self.alerts = []
        }
        self.notify()
        self.restartPolling()
    }

    private func restartPolling() {
        self.pollTask?.cancel()
        guard self.client != nil else { return }
        self.pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                // Back off on auth failure: re-polling burns the lockout counter.
                if self.connection.isAuthFailed { return }
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    // MARK: Refresh

    func refreshNow() {
        Task { await self.refresh() }
    }

    func refresh() async {
        guard let client else { self.connection = .unconfigured; self.notify(); return }
        // Back off on auth failure — the menu calls this on every open, and each
        // 401 burns Komodo's lockout counter. Cleared by editing credentials.
        guard !self.connection.isAuthFailed else { return }
        guard !self.isRefreshing else { return }
        self.isRefreshing = true
        self.notify()

        do {
            async let ss = client.serversSummary()
            async let st = client.stacksSummary()
            async let sv = client.listServers()
            async let stk = client.listStacks()
            let (summary, stackSummary, serverList, stackList) = try await (ss, st, sv, stk)
            self.serversSummary = summary
            self.stacksSummary = stackSummary
            self.servers = serverList.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.stacks = stackList.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.connection = .ok
            self.lastRefresh = Date()
            await self.loadServerStats(for: serverList, using: client)
            // Tolerant: an alerts fetch failure (older Komodo, perms) must not blank
            // the servers/stacks we already loaded.
            if let fetched = try? await client.listAlerts() {
                self.alerts = fetched.sorted { $0.ts > $1.ts }
                self.processAlertNotifications()
            }
        } catch let error as KomodoError {
            if error.status == 401 {
                connection = .authFailed(error.message)
            } else {
                connection = .error(error.errorDescription ?? error.message)
            }
        } catch {
            self.connection = .error(error.localizedDescription)
        }

        self.isRefreshing = false
        self.notify()
    }

    /// Fetch CPU/mem/disk for each server concurrently and append CPU% to the
    /// per-server history ring buffer that feeds the sparkline.
    private func loadServerStats(for serverList: [ServerListItem], using client: KomodoClient) async {
        let results = await withTaskGroup(of: (String, SystemStats?).self) { group in
            for server in serverList {
                group.addTask { await (server.id, try? client.systemStats(server: server.id)) }
            }
            var accumulated: [String: SystemStats] = [:]
            for await (id, stats) in group where stats != nil {
                accumulated[id] = stats
            }
            return accumulated
        }
        self.serverStats = results
        for (id, stats) in results {
            self.append(&self.cpuHistory, id, stats.cpuPerc)
            self.append(&self.memHistory, id, stats.memPercent * 100)
            self.append(&self.diskHistory, id, (stats.primaryDisk?.percent ?? 0) * 100)
        }
    }

    /// Fire a macOS notification for each alert newer than the last seen one that
    /// clears the severity threshold. First run only sets the baseline (no flood).
    private func processAlertNotifications() {
        guard self.notificationsEnabled else { return }
        let last = UserDefaults.standard.double(forKey: self.lastSeenAlertKey)
        let maxTs = self.alerts.map(\.ts).max() ?? last
        defer { if maxTs > last { UserDefaults.standard.set(maxTs, forKey: self.lastSeenAlertKey) } }
        guard last > 0 else { return } // baseline the first time so we don't replay history

        let fresh = self.alerts.filter { !$0.resolved && $0.ts > last && $0.level.rank >= self.notifyThreshold.rank }
        for alert in fresh {
            let name = self.resourceName(forType: alert.targetType, id: alert.targetId)
            self.notifier.notify(
                id: alert.id.isEmpty ? "\(alert.ts)" : alert.id,
                title: "\(alert.level.displayName): \(name)",
                body: Self.humanize(alert.kind),
                critical: alert.level == .critical,
            )
        }
    }

    /// "StackStateChange" → "Stack State Change" for readable notification bodies.
    static func humanize(_ kind: String?) -> String {
        guard let kind, !kind.isEmpty else { return "Alert" }
        var out = ""
        for ch in kind {
            if ch.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    private func append(_ buffer: inout [String: [Double]], _ id: String, _ value: Double) {
        var history = buffer[id] ?? []
        history.append(value)
        if history.count > self.historyLimit { history.removeFirst(history.count - self.historyLimit) }
        buffer[id] = history
    }

    // MARK: Actions (fire, then re-poll to observe the new state)

    func deploy(_ stack: StackListItem) {
        self.run("Redeploy \(stack.name)") { try await $0.deployStack(stack.id) }
    }

    /// Apply a pending update to one stack — deploys only if its content changed,
    /// so an already-current stack is left untouched (no downtime).
    func deployIfChanged(_ stack: StackListItem) {
        self.run("Update \(stack.name)") { try await $0.deployStackIfChanged(stack.id) }
    }

    /// Apply all pending updates in one shot — Core redeploys only the stacks whose
    /// content actually changed, leaving the rest running.
    func updateAll() {
        self.run("Update all stacks") { try await $0.batchDeployStackIfChanged() }
    }

    func pull(_ stack: StackListItem) {
        self.run("Pull \(stack.name)") { try await $0.pullStack(stack.id) }
    }

    func restart(_ stack: StackListItem) {
        self.run("Restart \(stack.name)") { try await $0.restartStack(stack.id) }
    }

    func checkForUpdate(_ stack: StackListItem) {
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

    func checkAllForUpdates() {
        let ids = self.stacks.map(\.id)
        self.run("Check all stacks") { client in
            await withTaskGroup(of: Void.self) { group in
                for id in ids {
                    group.addTask { _ = try? await client.checkStackForUpdate(id) }
                }
            }
        }
    }

    private func run(_ label: String, _ op: @escaping @Sendable (KomodoClient) async throws -> Void) {
        guard let client else { return }
        Task { [weak self] in
            guard let self else { return }
            self.actionStatus = "\(label)…"
            self.notify()
            do {
                try await op(client)
                self.actionStatus = "\(label) ✓"
            } catch let error as KomodoError {
                self.actionStatus = "\(label) failed: \(error.message)"
            } catch {
                self.actionStatus = "\(label) failed"
            }
            self.notify()
            await self.refresh()
            try? await Task.sleep(for: .seconds(5))
            if self.actionStatus?.hasPrefix(label) == true {
                self.actionStatus = nil
                self.notify()
            }
        }
    }

    private func notify() {
        self.onChange?()
    }
}
