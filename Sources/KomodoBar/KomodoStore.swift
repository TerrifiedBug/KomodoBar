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

    /// Deployments (single managed containers).
    private(set) var deployments: [DeploymentListItem] = []
    private(set) var deploymentsSummary: DeploymentsSummary?

    /// Runnable Komodo Procedures and Actions, for the Run launcher.
    private(set) var procedures: [ExecResourceItem] = []
    private(set) var actions: [ExecResourceItem] = []

    /// Recent operation history (newest first), for the Recent Activity feed.
    private(set) var recentUpdates: [UpdateListItem] = []

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

    /// Stacks worth a red alert: genuinely broken (unhealthy/dead) and not muted or
    /// snoozed. Excludes `down` — that's intentionally-off, not a problem.
    var attentionStacks: [StackListItem] {
        self.stacks.filter { $0.state.isProblem && !self.isSuppressed($0.id) }
    }

    var attentionServers: [ServerListItem] {
        self.servers.filter { $0.state == .notOk && !self.isSuppressed($0.id) }
    }

    var attentionDeployments: [DeploymentListItem] {
        self.deployments.filter { ($0.state == .unhealthy || $0.state == .dead) && !self.isSuppressed($0.id) }
    }

    /// Genuinely unhealthy things worth a red alert, computed from the live lists so
    /// muting/snoozing a resource removes it. Drives the icon tint + count.
    var attentionCount: Int {
        self.attentionStacks.count + self.attentionServers.count + self.attentionDeployments.count
    }

    /// An unresolved CRITICAL alert turns the icon red even when the summaries miss
    /// it — so the badge can't under-report a live incident. A muted/snoozed target
    /// is excluded so suppression also silences its alert.
    var hasCriticalAlert: Bool {
        self.alerts.contains {
            !$0.resolved && $0.level == .critical && !($0.targetId.map(self.isSuppressed) ?? false)
        }
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
        get { StackFilter(rawValue: UserDefaults.standard.string(forKey: "komodo.stackFilter") ?? "") ?? .hideOff }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "komodo.stackFilter"); self.notify() }
    }

    /// Group the stack list under per-server headers in the menu. Persisted; off by
    /// default so existing menus are unchanged until opted in.
    var groupStacksByServer: Bool {
        get { UserDefaults.standard.bool(forKey: "komodo.groupByServer") }
        set { UserDefaults.standard.set(newValue, forKey: "komodo.groupByServer"); self.notify() }
    }

    /// Hide "off" stacks (Komodo's `down` + `stopped`) from the menu entirely —
    /// visible and hidden. Persisted.
    var hideOffStacks: Bool {
        get { UserDefaults.standard.bool(forKey: "komodo.hideOff") }
        set { UserDefaults.standard.set(newValue, forKey: "komodo.hideOff"); self.notify() }
    }

    /// Stacks eligible for display, after the global `hideOffStacks` rule.
    private var displayStacks: [StackListItem] {
        self.hideOffStacks ? self.stacks.filter { !$0.state.isOff } : self.stacks
    }

    /// Stacks shown in the menu after applying `stackFilter`.
    var visibleStacks: [StackListItem] {
        self.displayStacks.filter { self.stackFilter.includes($0.state) }
    }

    /// Stacks grouped by server for the grouped layout. Groups hold the server's
    /// FULL display-stack set (so the rollup badge reflects true health); the menu
    /// applies `stackFilter` to decide which rows to list within each group.
    var stackGroups: [StackGroup] {
        let names = Dictionary(servers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return makeStackGroups(self.displayStacks, serverNames: names)
    }

    /// Stacks the current filter is hiding — surfaced under "Show N hidden" so the
    /// user can still act on (e.g. redeploy) a healthy stack the filter dropped.
    var hiddenStacks: [StackListItem] {
        self.displayStacks.filter { !self.stackFilter.includes($0.state) }
    }

    /// How many stacks the filter is hiding right now.
    var hiddenStackCount: Int {
        self.displayStacks.count - self.visibleStacks.count
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

    // MARK: Quick Access (pinned + recent stacks)

    private let recentLimit = 8

    /// Stack ids the user pinned to the top. Persisted.
    var pinnedIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "komodo.pinned") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "komodo.pinned"); self.notify() }
    }

    func isPinned(_ id: String) -> Bool {
        self.pinnedIds.contains(id)
    }

    func togglePin(_ id: String) {
        var pinned = self.pinnedIds
        if pinned.contains(id) { pinned.remove(id) } else { pinned.insert(id) }
        self.pinnedIds = pinned
    }

    /// Most-recently-acted-on stack ids, newest first. Captured on each action.
    private var recentIds: [String] {
        UserDefaults.standard.stringArray(forKey: "komodo.recent") ?? []
    }

    func noteRecent(_ id: String) {
        var recent = self.recentIds.filter { $0 != id }
        recent.insert(id, at: 0)
        UserDefaults.standard.set(Array(recent.prefix(self.recentLimit)), forKey: "komodo.recent")
    }

    /// Pinned stacks (stable name order) then recents, deduped and capped — the
    /// top-of-menu shortcut list. Pinned entries appear even if a filter hides them.
    var quickAccessStacks: [StackListItem] {
        let byId = Dictionary(self.stacks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let pinned = self.stacks.filter { self.pinnedIds.contains($0.id) }
        let recent = self.recentIds.compactMap { byId[$0] }.filter { !self.pinnedIds.contains($0.id) }
        return Array((pinned + recent).prefix(10))
    }

    // MARK: Mute & snooze (keep "red = unacknowledged" trustworthy)

    /// Resource ids muted indefinitely. Persisted.
    var mutedIds: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "komodo.muted") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "komodo.muted"); self.notify() }
    }

    /// Resource id → epoch seconds until which it's snoozed. Persisted.
    private var snoozeUntil: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: "komodo.snooze") as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "komodo.snooze") }
    }

    func isMuted(_ id: String) -> Bool {
        self.mutedIds.contains(id)
    }

    func isSnoozed(_ id: String) -> Bool {
        (self.snoozeUntil[id] ?? 0) > Date().timeIntervalSince1970
    }

    func isSuppressed(_ id: String) -> Bool {
        self.isMuted(id) || self.isSnoozed(id)
    }

    func toggleMute(_ id: String) {
        var muted = self.mutedIds
        if muted.contains(id) { muted.remove(id) } else { muted.insert(id) }
        self.mutedIds = muted
    }

    func snooze(_ id: String, seconds: TimeInterval) {
        var map = self.snoozeUntil
        map[id] = Date().addingTimeInterval(seconds).timeIntervalSince1970
        self.snoozeUntil = map
        self.notify()
    }

    func clearSnooze(_ id: String) {
        var map = self.snoozeUntil
        map[id] = nil
        self.snoozeUntil = map
        self.notify()
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
            self.deployments = []; self.deploymentsSummary = nil
            self.procedures = []; self.actions = []; self.recentUpdates = []
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
            // Tolerant extras: older Komodo builds / permissions can 404 these, and a
            // failure must not blank the servers/stacks we already loaded. Fetched
            // concurrently.
            async let dep = client.listDeployments()
            async let depSum = client.deploymentsSummary()
            async let procs = client.listProcedures()
            async let acts = client.listActions()
            async let upd = client.listUpdates()
            self.deployments = await ((try? dep) ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.deploymentsSummary = try? await depSum
            self.procedures = await ((try? procs) ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.actions = await ((try? acts) ?? [])
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.recentUpdates = await Array(((try? upd) ?? []).prefix(20))
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

        let fresh = self.alerts.filter {
            !$0.resolved && $0.ts > last && $0.level.rank >= self.notifyThreshold.rank
                && !($0.targetId.map(self.isSuppressed) ?? false)
        }
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

    func run(_ label: String, _ op: @escaping @Sendable (KomodoClient) async throws -> Void) {
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

    /// Run an op over many ids concurrently, reporting an honest success/failure
    /// tally. Unlike a bare `try?` fan-out, a partial failure is surfaced, not
    /// silently swallowed.
    func runBatch(
        _ label: String,
        _ ids: [String],
        _ op: @escaping @Sendable (KomodoClient, String) async throws -> Void,
    ) {
        guard let client, !ids.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            self.actionStatus = "\(label)…"
            self.notify()
            let (ok, total) = await withTaskGroup(of: Bool.self) { group in
                for id in ids {
                    group.addTask {
                        do { try await op(client, id); return true } catch { return false }
                    }
                }
                var succeeded = 0
                var count = 0
                for await success in group {
                    count += 1
                    if success { succeeded += 1 }
                }
                return (succeeded, count)
            }
            let failed = total - ok
            self.actionStatus = failed == 0 ? "\(label): \(ok) ✓" : "\(label): \(ok) ok, \(failed) failed"
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
