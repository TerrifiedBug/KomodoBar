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

// MARK: Credentials parsing

@Test func `credentials reject invalid UR ls`() {
    #expect(KomodoCredentials(urlString: "", apiKey: "k", apiSecret: "s") == nil)
    #expect(KomodoCredentials(urlString: "not a url", apiKey: "k", apiSecret: "s") == nil)
    #expect(KomodoCredentials(urlString: "https://komodo.example.com", apiKey: "k", apiSecret: "s") != nil)
}
