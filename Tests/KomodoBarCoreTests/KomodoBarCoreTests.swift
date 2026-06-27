import Foundation
@testable import KomodoBarCore
import Testing

/// Decoder configured exactly like `KomodoClient` (snake_case → camelCase).
private func decode<T: Decodable>(_: T.Type, _ json: String) throws -> T {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(T.self, from: Data(json.utf8))
}

// MARK: State normalisation (survives Ok/NotOk vs ok/not-ok wire forms)

@Test func `server state normalises both wire forms`() {
    #expect(ServerState.normalize("Ok") == .ok)
    #expect(ServerState.normalize("ok") == .ok)
    #expect(ServerState.normalize("NotOk") == .notOk)
    #expect(ServerState.normalize("not-ok") == .notOk)
    #expect(ServerState.normalize("Disabled") == .disabled)
    #expect(ServerState.normalize("something-new") == .unknown)
}

@Test func `server state severity mapping`() {
    #expect(ServerState.ok.severity == .healthy)
    #expect(ServerState.notOk.severity == .error)
    #expect(ServerState.disabled.severity == .warning)
}

@Test func `stack state decodes snake case and falls back`() throws {
    #expect(try decode(StackState.self, "\"running\"") == .running)
    #expect(try decode(StackState.self, "\"down\"") == .down)
    #expect(try decode(StackState.self, "\"brand_new_state\"") == .unknown)
    #expect(StackState.running.severity == .healthy)
    #expect(StackState.down.severity == .error)
    #expect(StackState.restarting.severity == .warning)
}

// MARK: List items

@Test func `server list item decodes ignoring extra keys`() throws {
    let json = """
    { "id": "abc", "type": "Server", "name": "prod-1", "tags": ["eu"],
      "info": { "state": "Ok", "region": "eu-west", "address": "http://10.0.0.2:8120",
                "external_address": "x", "version": "1.18.4", "public_ip": "1.2.3.4" } }
    """
    let item = try decode(ServerListItem.self, json)
    #expect(item.id == "abc")
    #expect(item.name == "prod-1")
    #expect(item.state == .ok)
    #expect(item.info.region == "eu-west")
    #expect(item.info.version == "1.18.4")
}

@Test func `stack list item surfaces pending updates`() throws {
    let json = """
    { "id": "s1", "type": "Stack", "name": "web", "tags": [],
      "info": { "state": "running", "status": "Up 3 days", "server_id": "srv1",
                "services": [
                  { "service": "app", "image": "nginx:latest", "update_available": true },
                  { "service": "db", "image": "postgres:16", "update_available": false }
                ],
                "deployed_hash": "aaa", "latest_hash": "bbb" } }
    """
    let stack = try decode(StackListItem.self, json)
    #expect(stack.name == "web")
    #expect(stack.state == .running)
    #expect(stack.info.serverId == "srv1")
    #expect(stack.updateAvailable == true)
    #expect(stack.servicesWithUpdate == ["app"])
}

@Test func `stack without services has no update`() throws {
    let json = """
    { "id": "s2", "name": "cache", "info": { "state": "stopped" } }
    """
    let stack = try decode(StackListItem.self, json)
    #expect(stack.updateAvailable == false)
    #expect(stack.servicesWithUpdate.isEmpty)
}

// MARK: Summaries & responses

@Test func `summaries decode`() throws {
    let servers = try decode(
        ServersSummary.self,
        "{\"total\":5,\"healthy\":4,\"warning\":0,\"unhealthy\":1,\"disabled\":0}",
    )
    #expect(servers.total == 5)
    #expect(servers.needsAttention == 1)

    let stacks = try decode(
        StacksSummary.self,
        "{\"total\":10,\"running\":8,\"stopped\":1,\"down\":1,\"unhealthy\":0,\"unknown\":0}",
    )
    #expect(stacks.running == 8)
    #expect(stacks.needsAttention == 1)
}

@Test func `check stack for update response decodes`() throws {
    let json = """
    { "stack": "s1", "services": [ { "service": "app", "image": "nginx", "update_available": true } ] }
    """
    let response = try decode(CheckStackForUpdateResponse.self, json)
    #expect(response.stack == "s1")
    #expect(response.updateAvailable == true)
}

// MARK: Stack filter

@Test func `stack filter hide down hides only down`() {
    let filter = StackFilter.hideDown
    #expect(filter.includes(.running))
    #expect(filter.includes(.stopped)) // stopped stays — it's not "down"
    #expect(filter.includes(.unhealthy))
    #expect(!filter.includes(.down))
}

@Test func `stack filter running only`() {
    let filter = StackFilter.runningOnly
    #expect(filter.includes(.running))
    #expect(!filter.includes(.stopped))
    #expect(!filter.includes(.down))
}

@Test func `stack filter all shows everything`() {
    #expect(StackState.allCases.allSatisfy { StackFilter.all.includes($0) })
}

@Test func `stack filter only problems shows unhealthy and dead`() {
    let filter = StackFilter.onlyProblems
    #expect(filter.includes(.unhealthy))
    #expect(filter.includes(.dead))
    #expect(!filter.includes(.running))
    #expect(!filter.includes(.stopped))
    #expect(!filter.includes(.down)) // intentionally-off, not a problem
}

// MARK: Alerts

@Test func `severity level normalises and ranks`() throws {
    #expect(try decode(SeverityLevel.self, "\"CRITICAL\"") == .critical)
    #expect(try decode(SeverityLevel.self, "\"Warning\"") == .warning)
    #expect(try decode(SeverityLevel.self, "\"ok\"") == .ok)
    #expect(try decode(SeverityLevel.self, "\"NEW_LEVEL\"") == .unknown)
    // Threshold logic relies on rank ordering; unknown ranks high so it isn't hidden.
    #expect(SeverityLevel.critical.rank > SeverityLevel.warning.rank)
    #expect(SeverityLevel.warning.rank > SeverityLevel.ok.rank)
    #expect(SeverityLevel.unknown.rank >= SeverityLevel.warning.rank)
}

@Test func `alert item decodes id target and kind`() throws {
    let json = """
    { "_id": "alert123", "ts": 1735689600000, "level": "CRITICAL", "resolved": false,
      "target": { "type": "Stack", "id": "s1" },
      "data": { "type": "StackStateChange", "data": { "from": "running", "to": "down" } } }
    """
    let alert = try decode(AlertItem.self, json)
    #expect(alert.id == "alert123")
    #expect(alert.level == .critical)
    #expect(alert.resolved == false)
    #expect(alert.targetType == "Stack")
    #expect(alert.targetId == "s1")
    #expect(alert.kind == "StackStateChange")
}

@Test func `alert item tolerates oid object and missing data`() throws {
    let json = """
    { "_id": { "$oid": "abc" }, "ts": 1, "level": "WARNING", "resolved": true,
      "target": { "type": "Server", "id": "srv1" } }
    """
    let alert = try decode(AlertItem.self, json)
    #expect(alert.id == "abc")
    #expect(alert.resolved == true)
    #expect(alert.kind == nil)
}

@Test func `alerts page decodes and tolerates absent list`() throws {
    let page = try decode(AlertsPage.self, "{ \"alerts\": [], \"next_page\": null }")
    #expect(page.alerts.isEmpty)
    let empty = try decode(AlertsPage.self, "{}")
    #expect(empty.alerts.isEmpty)
}

// MARK: Credentials parsing

@Test func `credentials reject invalid UR ls`() {
    #expect(KomodoCredentials(urlString: "", apiKey: "k", apiSecret: "s") == nil)
    #expect(KomodoCredentials(urlString: "not a url", apiKey: "k", apiSecret: "s") == nil)
    #expect(KomodoCredentials(urlString: "https://komodo.example.com", apiKey: "k", apiSecret: "s") != nil)
}
