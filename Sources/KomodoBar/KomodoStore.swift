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

        var isAuthFailed: Bool { if case .authFailed = self { return true } else { return false } }
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

    /// Called after any state change so the status-bar icon can repaint.
    var onChange: (@MainActor () -> Void)?

    private var client: KomodoClient?
    private var pollTask: Task<Void, Never>?

    /// Seconds between polls. Persisted in UserDefaults; defaults to 30.
    var pollInterval: TimeInterval {
        get {
            let v = UserDefaults.standard.double(forKey: "komodo.pollInterval")
            return v > 0 ? v : 30
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "komodo.pollInterval")
            restartPolling()
        }
    }

    var isConfigured: Bool { client != nil }

    /// Genuinely unhealthy things worth a red alert. Excludes `down` stacks —
    /// those are often intentionally off (the user hides them), so counting them
    /// would keep the icon permanently red. Drives the icon tint + count.
    var attentionCount: Int {
        (serversSummary?.unhealthy ?? 0) + (stacksSummary?.unhealthy ?? 0)
    }

    var needsAttention: Bool { attentionCount > 0 || connection.isAuthFailed }

    /// Menu filter for the stack list (display-only; persisted).
    var stackFilter: StackFilter {
        get { StackFilter(rawValue: UserDefaults.standard.string(forKey: "komodo.stackFilter") ?? "") ?? .hideDown }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "komodo.stackFilter"); notify() }
    }

    /// Stacks shown in the menu after applying `stackFilter`.
    var visibleStacks: [StackListItem] { stacks.filter { stackFilter.includes($0.state) } }

    /// How many stacks the filter is hiding right now.
    var hiddenStackCount: Int { stacks.count - visibleStacks.count }

    /// Stacks with a pending image update — surfaced regardless of the filter.
    var stacksWithUpdates: [StackListItem] { stacks.filter(\.updateAvailable) }
    var updateCount: Int { stacksWithUpdates.count }

    // MARK: Lifecycle

    func start() {
        reloadCredentials()
        restartPolling()
    }

    /// Re-read credentials from the store (after the user edits Settings).
    func reloadCredentials() {
        if let creds = CredentialStore.load() {
            client = KomodoClient(credentials: creds)
            if connection == .unconfigured || connection.isAuthFailed { connection = .ok }
        } else {
            client = nil
            connection = .unconfigured
            servers = []; stacks = []; serversSummary = nil; stacksSummary = nil
        }
        notify()
        restartPolling()
    }

    private func restartPolling() {
        pollTask?.cancel()
        guard client != nil else { return }
        pollTask = Task { [weak self] in
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

    func refreshNow() { Task { await refresh() } }

    func refresh() async {
        guard let client else { connection = .unconfigured; notify(); return }
        // Back off on auth failure — the menu calls this on every open, and each
        // 401 burns Komodo's lockout counter. Cleared by editing credentials.
        guard !connection.isAuthFailed else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        notify()

        do {
            async let ss = client.serversSummary()
            async let st = client.stacksSummary()
            async let sv = client.listServers()
            async let stk = client.listStacks()
            let (summary, stackSummary, serverList, stackList) = try await (ss, st, sv, stk)
            serversSummary = summary
            stacksSummary = stackSummary
            servers = serverList.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            stacks = stackList.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            connection = .ok
            lastRefresh = Date()
            await loadServerStats(for: serverList, using: client)
        } catch let error as KomodoError {
            if error.status == 401 {
                connection = .authFailed(error.message)
            } else {
                connection = .error(error.errorDescription ?? error.message)
            }
        } catch {
            connection = .error(error.localizedDescription)
        }

        isRefreshing = false
        notify()
    }

    /// Fetch CPU/mem/disk for each server concurrently and append CPU% to the
    /// per-server history ring buffer that feeds the sparkline.
    private func loadServerStats(for serverList: [ServerListItem], using client: KomodoClient) async {
        let results = await withTaskGroup(of: (String, SystemStats?).self) { group in
            for server in serverList {
                group.addTask { (server.id, try? await client.systemStats(server: server.id)) }
            }
            var accumulated: [String: SystemStats] = [:]
            for await (id, stats) in group where stats != nil { accumulated[id] = stats }
            return accumulated
        }
        serverStats = results
        for (id, stats) in results {
            append(&cpuHistory, id, stats.cpuPerc)
            append(&memHistory, id, stats.memPercent * 100)
            append(&diskHistory, id, (stats.primaryDisk?.percent ?? 0) * 100)
        }
    }

    private func append(_ buffer: inout [String: [Double]], _ id: String, _ value: Double) {
        var history = buffer[id] ?? []
        history.append(value)
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
        buffer[id] = history
    }

    // MARK: Actions (fire, then re-poll to observe the new state)

    func deploy(_ stack: StackListItem) { run("Redeploy \(stack.name)") { try await $0.deployStack(stack.id) } }
    func pull(_ stack: StackListItem) { run("Pull \(stack.name)") { try await $0.pullStack(stack.id) } }
    func restart(_ stack: StackListItem) { run("Restart \(stack.name)") { try await $0.restartStack(stack.id) } }
    func checkForUpdate(_ stack: StackListItem) { run("Check \(stack.name)") { _ = try await $0.checkStackForUpdate(stack.id) } }
    func redeployAll() { run("Redeploy all stacks") { try await $0.redeployAllStacks() } }

    func checkAllForUpdates() {
        let ids = stacks.map(\.id)
        run("Check all stacks") { client in
            await withTaskGroup(of: Void.self) { group in
                for id in ids { group.addTask { _ = try? await client.checkStackForUpdate(id) } }
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

    private func notify() { onChange?() }
}
