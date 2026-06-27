import Foundation

// MARK: - Health severity (UI-agnostic)

/// A coarse health bucket the UI maps to a colour. Lives in Core so the CLI can
/// reuse it for text output.
public enum HealthSeverity: Sendable {
    case healthy, warning, error, unknown
}

// MARK: - Server / Stack state enums

//
// Decoded leniently: Komodo's OpenAPI spec serialises ServerState as
// `Ok/NotOk/Disabled` and StackState as snake_case, but the Rust source uses
// kebab-case for Display. Normalising (strip `-`/`_`, lowercase) survives either
// wire form and falls back to `.unknown` for anything new.

public enum ServerState: String, Sendable, CaseIterable, Decodable {
    case ok, notOk, disabled, unknown

    public init(from decoder: any Decoder) throws {
        // Lenient: a null / missing / non-string value becomes .unknown rather
        // than throwing — one bad element must not drop the whole list.
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = ServerState.normalize(raw)
    }

    static func normalize(_ raw: String) -> ServerState {
        switch raw.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "").lowercased() {
        case "ok": .ok
        case "notok": .notOk
        case "disabled": .disabled
        default: .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .ok: "Healthy"
        case .notOk: "Unreachable"
        case .disabled: "Disabled"
        case .unknown: "Unknown"
        }
    }

    public var severity: HealthSeverity {
        switch self {
        case .ok: .healthy
        case .notOk: .error
        case .disabled: .warning
        case .unknown: .unknown
        }
    }
}

public enum StackState: String, Sendable, CaseIterable, Decodable {
    case deploying, running, paused, stopped, created, restarting
    case dead, removing, unhealthy, down, unknown

    public init(from decoder: any Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        let key = raw.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "").lowercased()
        self = StackState.allCases.first { $0.rawValue == key } ?? .unknown
    }

    public var displayName: String {
        rawValue.capitalized
    }

    public var severity: HealthSeverity {
        switch self {
        case .running: .healthy
        case .dead, .down, .unhealthy: .error
        case .deploying, .paused, .stopped, .created, .restarting, .removing: .warning
        case .unknown: .unknown
        }
    }
}

// MARK: - Stack display filter

/// Which stacks appear in the menu. Down stacks are often intentionally off, so
/// hiding them cuts clutter. Pure logic over `StackState`, so it lives in Core
/// and is unit-tested.
public enum StackFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case hideDown
    case runningOnly

    public var id: String {
        rawValue
    }

    public var label: String {
        switch self {
        case .all: "All stacks"
        case .hideDown: "Hide down stacks"
        case .runningOnly: "Only running"
        }
    }

    public func includes(_ state: StackState) -> Bool {
        switch self {
        case .all: true
        case .hideDown: state != .down
        case .runningOnly: state == .running
        }
    }
}

// MARK: - Summaries (GetServersSummary / GetStacksSummary)

public struct ServersSummary: Decodable, Sendable {
    public let total: Int
    public let healthy: Int
    public let warning: Int
    public let unhealthy: Int
    public let disabled: Int

    /// Servers that are not healthy (warnings + unreachable). Disabled excluded.
    public var needsAttention: Int {
        self.warning + self.unhealthy
    }

    // Lenient: a count absent on an older Komodo build defaults to 0 instead of
    // throwing and blanking the whole UI.
    enum CodingKeys: String, CodingKey { case total, healthy, warning, unhealthy, disabled }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func n(_ key: CodingKeys) -> Int {
            (try? c.decodeIfPresent(Int.self, forKey: key)) ?? 0
        }
        self.total = n(.total); self.healthy = n(.healthy); self.warning = n(.warning)
        self.unhealthy = n(.unhealthy); self.disabled = n(.disabled)
    }
}

public struct StacksSummary: Decodable, Sendable {
    public let total: Int
    public let running: Int
    public let stopped: Int
    public let down: Int
    public let unhealthy: Int
    public let unknown: Int

    public var needsAttention: Int {
        self.down + self.unhealthy
    }

    enum CodingKeys: String, CodingKey { case total, running, stopped, down, unhealthy, unknown }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func n(_ key: CodingKeys) -> Int {
            (try? c.decodeIfPresent(Int.self, forKey: key)) ?? 0
        }
        self.total = n(.total); self.running = n(.running); self.stopped = n(.stopped)
        self.down = n(.down); self.unhealthy = n(.unhealthy); self.unknown = n(.unknown)
    }
}

// MARK: - Per-service update info (StackServiceWithUpdate)

public struct StackServiceWithUpdate: Decodable, Sendable, Identifiable {
    public let service: String
    public let image: String?
    public let updateAvailable: Bool

    public var id: String {
        self.service
    }

    enum CodingKeys: String, CodingKey { case service, image, updateAvailable }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.service = (try? c.decodeIfPresent(String.self, forKey: .service)) ?? ""
        self.image = try? c.decodeIfPresent(String.self, forKey: .image)
        self.updateAvailable = (try? c.decodeIfPresent(Bool.self, forKey: .updateAvailable)) ?? false
    }
}

// MARK: - List items (ResourceListItem<Info> => { id, name, info, ... })

// Extra keys (type, tags) are ignored — Codable only fails on missing required keys.

public struct ServerListItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let info: Info

    public struct Info: Decodable, Sendable {
        public let state: ServerState
        public let region: String?
        public let address: String?
        public let version: String?
    }

    public var state: ServerState {
        self.info.state
    }
}

public struct StackListItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let info: Info

    public struct Info: Decodable, Sendable {
        public let state: StackState
        public let status: String?
        public let services: [StackServiceWithUpdate]?
        public let serverId: String?
    }

    public var state: StackState {
        self.info.state
    }

    /// True if any service reported a newer image at the last update check.
    public var updateAvailable: Bool {
        self.info.services?.contains { $0.updateAvailable } ?? false
    }

    /// Names of services with a pending image update.
    public var servicesWithUpdate: [String] {
        self.info.services?.filter(\.updateAvailable).map(\.service) ?? []
    }
}

// MARK: - System stats (GetSystemStats)

public struct SystemStats: Decodable, Sendable {
    public let cpuPerc: Double
    public let memUsedGb: Double
    public let memTotalGb: Double
    public let disks: [DiskUsage]

    public struct DiskUsage: Decodable, Sendable {
        public let mount: String
        public let usedGb: Double
        public let totalGb: Double

        public var percent: Double {
            self.totalGb > 0 ? self.usedGb / self.totalGb : 0
        }
    }

    public var memPercent: Double {
        self.memTotalGb > 0 ? self.memUsedGb / self.memTotalGb : 0
    }

    /// The largest disk by capacity — the one worth showing at a glance.
    public var primaryDisk: DiskUsage? {
        self.disks.max { $0.totalGb < $1.totalGb }
    }
}

// MARK: - Misc responses

public struct KomodoVersion: Decodable, Sendable {
    public let version: String
}

/// Response for CheckStackForUpdate.
public struct CheckStackForUpdateResponse: Decodable, Sendable {
    public let stack: String
    public let services: [StackServiceWithUpdate]

    public var updateAvailable: Bool {
        self.services.contains { $0.updateAvailable }
    }
}
