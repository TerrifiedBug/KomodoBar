import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Credentials + base URL for a Komodo Core instance.
public struct KomodoCredentials: Sendable, Equatable {
    public var baseURL: URL
    public var apiKey: String
    public var apiSecret: String

    public init(baseURL: URL, apiKey: String, apiSecret: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.apiSecret = apiSecret
    }

    /// Build from a user-entered URL string. Trailing slashes are trimmed so
    /// `appendingPathComponent` produces clean `/read/...` paths.
    public init?(urlString: String, apiKey: String, apiSecret: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            return nil
        }
        self.init(baseURL: url, apiKey: apiKey, apiSecret: apiSecret)
    }
}

/// An error returned by the Komodo API (non-2xx) or a transport failure.
public struct KomodoError: Error, LocalizedError, Sendable {
    public let status: Int
    public let message: String
    public var errorDescription: String? {
        self.status > 0 ? "Komodo error \(self.status): \(self.message)" : self.message
    }
}

/// A thin typed client over Komodo Core's `POST /<group>/<RequestName>` API.
///
/// Auth is via the `X-Api-Key` / `X-Api-Secret` headers. Every request is a POST
/// with a JSON body of params (empty `{}` for parameterless reads). Read requests
/// decode a typed response; execute/write requests that return an `Update` are
/// fired and the body ignored (the app re-polls to observe the new state).
public struct KomodoClient: Sendable {
    public let credentials: KomodoCredentials
    private let session: URLSession

    public init(credentials: KomodoCredentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    // MARK: Reads

    /// Unauthenticated reachability probe (`GET /version`). Confirms the base URL
    /// points at a Komodo Core before credentials are checked. Returns the version
    /// string. Tolerates either a JSON `{ "version": ... }` body or a bare string.
    public func ping() async throws -> String {
        let url = self.credentials.baseURL.appendingPathComponent("version")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            throw KomodoError(status: -1, message: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw KomodoError(status: status, message: Self.extractMessage(from: data, status: status))
        }
        if let v = try? JSONDecoder().decode(KomodoVersion.self, from: data) { return v.version }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public func version() async throws -> KomodoVersion {
        try await self.read("GetVersion")
    }

    public func serversSummary() async throws -> ServersSummary {
        try await self.read("GetServersSummary")
    }

    public func stacksSummary() async throws -> StacksSummary {
        try await self.read("GetStacksSummary")
    }

    public func listServers() async throws -> [ServerListItem] {
        try await self.read("ListServers")
    }

    public func listStacks() async throws -> [StackListItem] {
        try await self.read("ListStacks")
    }

    public func listDeployments() async throws -> [DeploymentListItem] {
        try await self.read("ListDeployments")
    }

    public func deploymentsSummary() async throws -> DeploymentsSummary {
        try await self.read("GetDeploymentsSummary")
    }

    /// Rollup of all raw Docker containers across servers — for the at-a-glance count.
    public func dockerContainersSummary() async throws -> DockerContainersSummary {
        try await self.read("GetDockerContainersSummary")
    }

    public func listProcedures() async throws -> [ExecResourceItem] {
        try await self.read("ListProcedures")
    }

    public func listActions() async throws -> [ExecResourceItem] {
        try await self.read("ListActions")
    }

    /// The latest page of the operation history (newest first).
    public func listUpdates() async throws -> [UpdateListItem] {
        let page: UpdatesPage = try await self.call("read", "ListUpdates", [:])
        return page.updates
    }

    /// Realtime CPU/mem/disk for one server. Served from Core's in-memory cache.
    public func systemStats(server idOrName: String) async throws -> SystemStats {
        try await self.call("read", "GetSystemStats", ["server": idOrName])
    }

    /// Open (unresolved) alerts, newest first as returned by Core. Pass
    /// `unresolvedOnly: false` to include resolved history.
    public func listAlerts(unresolvedOnly: Bool = true) async throws -> [AlertItem] {
        let query: [String: Any] = unresolvedOnly ? ["resolved": false] : [:]
        let page: AlertsPage = try await self.call("read", "ListAlerts", ["query": query])
        return page.alerts
    }

    // MARK: Writes

    /// Actively poll registries for newer images for a single stack and refresh
    /// its cache. `skip_auto_update` keeps this read-only (no auto redeploy).
    public func checkStackForUpdate(_ idOrName: String) async throws -> CheckStackForUpdateResponse {
        try await self.call("write", "CheckStackForUpdate", ["stack": idOrName, "skip_auto_update": true])
    }

    /// Mark an alert resolved (acknowledged) by its id.
    public func closeAlert(_ id: String) async throws {
        _ = try await self.perform("write", "CloseAlert", ["id": id])
    }

    // MARK: Executes (fire-and-refresh)

    public func deployStack(_ idOrName: String) async throws {
        try await self.fire("DeployStack", ["stack": idOrName])
    }

    /// Deploy a stack only if its compose/image content changed since last deploy —
    /// a no-op (no downtime) for unchanged stacks. The safe way to apply updates.
    public func deployStackIfChanged(_ idOrName: String) async throws {
        try await self.fire("DeployStackIfChanged", ["stack": idOrName])
    }

    /// Deploy every stack matching a pattern, but only those whose content changed.
    /// `"*"` = all stacks; unchanged ones are skipped server-side (no downtime).
    public func batchDeployStackIfChanged(pattern: String = "*") async throws {
        try await self.fire("BatchDeployStackIfChanged", ["pattern": pattern])
    }

    public func pullStack(_ idOrName: String) async throws {
        try await self.fire("PullStack", ["stack": idOrName])
    }

    public func restartStack(_ idOrName: String) async throws {
        try await self.fire("RestartStack", ["stack": idOrName])
    }

    /// Redeploy every stack matching a pattern. `"*"` = all stacks.
    public func redeployAllStacks(pattern: String = "*") async throws {
        try await self.fire("BatchDeployStack", ["pattern": pattern])
    }

    // Deployment actions (single managed containers). All take the `deployment` param.

    public func deployDeployment(_ idOrName: String) async throws {
        try await self.fire("Deploy", ["deployment": idOrName])
    }

    public func startDeployment(_ idOrName: String) async throws {
        try await self.fire("StartDeployment", ["deployment": idOrName])
    }

    public func stopDeployment(_ idOrName: String) async throws {
        try await self.fire("StopDeployment", ["deployment": idOrName])
    }

    public func restartDeployment(_ idOrName: String) async throws {
        try await self.fire("RestartDeployment", ["deployment": idOrName])
    }

    public func runProcedure(_ idOrName: String) async throws {
        try await self.fire("RunProcedure", ["procedure": idOrName])
    }

    public func runAction(_ idOrName: String) async throws {
        try await self.fire("RunAction", ["action": idOrName])
    }

    /// Admin-only global poll for updates on poll/auto-update-enabled resources.
    /// `skipAutoUpdate: true` only raises UpdateAvailable alerts instead of deploying.
    public func globalAutoUpdate(skipAutoUpdate: Bool) async throws {
        try await self.fire("GlobalAutoUpdate", ["skip_auto_update": skipAutoUpdate])
    }

    // MARK: - Plumbing

    private func read<T: Decodable>(_ name: String) async throws -> T {
        try await self.call("read", name, [:])
    }

    private func fire(_ name: String, _ body: [String: Any]) async throws {
        let data = try await self.perform("execute", name, body)
        // Komodo returns the resulting Update on a 200 even when the operation itself
        // failed. Surface a *completed* failure as an error so the UI stops claiming
        // success on a 200 that actually failed. Batch responses are arrays and won't
        // decode here, so they're left to their own (future) handling.
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let update = try? decoder.decode(KomodoUpdate.self, from: data), update.completed, !update.success {
            throw KomodoError(status: 0, message: "Komodo reported the operation failed")
        }
    }

    private func call<T: Decodable>(_ group: String, _ name: String, _ body: [String: Any]) async throws -> T {
        let data = try await perform(group, name, body)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw KomodoError(status: 0, message: "Failed to decode \(name): \(error.localizedDescription)")
        }
    }

    private func perform(_ group: String, _ name: String, _ body: [String: Any]) async throws -> Data {
        let url = self.credentials.baseURL.appendingPathComponent(group).appendingPathComponent(name)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(self.credentials.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(self.credentials.apiSecret, forHTTPHeaderField: "X-Api-Secret")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.session.data(for: request)
        } catch {
            throw KomodoError(status: -1, message: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw KomodoError(status: -1, message: "No HTTP response from \(url.absoluteString)")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw KomodoError(
                status: http.statusCode,
                message: Self.extractMessage(from: data, status: http.statusCode),
            )
        }
        return data
    }

    /// Komodo errors come back as `{ "error": "..." }`; fall back to the raw body.
    private static func extractMessage(from data: Data, status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let err = obj["error"] as? String { return err }
            if let msg = obj["message"] as? String { return msg }
        }
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty { return raw }
        return HTTPURLResponse.localizedString(forStatusCode: status)
    }
}
