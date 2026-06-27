import Foundation
import KomodoBarCore

// Headless companion to the menu-bar app. Reads the same env vars as the official
// Komodo clients: KOMODO_ADDRESS, KOMODO_API_KEY, KOMODO_API_SECRET.
//
// Usage:
//   komodobar-cli status    # server + stack health summary (default)
//   komodobar-cli servers   # per-server state
//   komodobar-cli stacks    # per-stack state + pending updates
//   komodobar-cli version   # ping the server (unauthenticated)
//   komodobar-cli --version # print the CLI version

func env(_ key: String) -> String? {
    let value = ProcessInfo.processInfo.environment[key]
    return (value?.isEmpty == false) ? value : nil
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())

if args.first == "--version" {
    print(KomodoBarCore.fallbackVersion)
    exit(0)
}

guard let address = env("KOMODO_ADDRESS"),
      let key = env("KOMODO_API_KEY"),
      let secret = env("KOMODO_API_SECRET"),
      let credentials = KomodoCredentials(urlString: address, apiKey: key, apiSecret: secret)
else {
    fail("Set KOMODO_ADDRESS, KOMODO_API_KEY and KOMODO_API_SECRET (a valid URL).", code: 2)
}

let client = KomodoClient(credentials: credentials)

func badge(_ severity: HealthSeverity) -> String {
    switch severity {
    case .healthy: "OK "
    case .warning: "WARN"
    case .error: "DOWN"
    case .unknown: "??? "
    }
}

do {
    switch args.first {
    case "version":
        try await print(client.ping())

    case "servers":
        for server in try await client.listServers().sorted(by: { $0.name < $1.name }) {
            print("[\(badge(server.state.severity))] \(server.name) — \(server.state.displayName)")
        }

    case "stacks":
        for stack in try await client.listStacks().sorted(by: { $0.name < $1.name }) {
            let update = stack.updateAvailable ? "  ⬆ update" : ""
            print("[\(badge(stack.state.severity))] \(stack.name) — \(stack.state.displayName)\(update)")
        }

    case "status", nil:
        async let serversSummary = client.serversSummary()
        async let stacksSummary = client.stacksSummary()
        let (servers, stacks) = try await (serversSummary, stacksSummary)
        print(
            "Servers: \(servers.healthy)/\(servers.total) healthy, \(servers.unhealthy) down, \(servers.disabled) disabled",
        )
        print("Stacks:  \(stacks.running)/\(stacks.total) running, \(stacks.down) down, \(stacks.unhealthy) unhealthy")

    default:
        fail("Unknown command '\(args[0])'. Try: status | servers | stacks | version", code: 2)
    }
} catch let error as KomodoError {
    fail(error.errorDescription ?? error.message)
} catch {
    fail(error.localizedDescription)
}
