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
    case onlyProblems

    public var id: String {
        rawValue
    }

    public var label: String {
        switch self {
        case .all: "All stacks"
        case .hideDown: "Hide down stacks"
        case .runningOnly: "Only running"
        case .onlyProblems: "Only problems"
        }
    }

    public func includes(_ state: StackState) -> Bool {
        switch self {
        case .all: true
        case .hideDown: state != .down
        case .runningOnly: state == .running
        // Genuine problems only — matches the red-lizard definition, which treats
        // `down` as intentionally-off (not a problem) and ignores it.
        case .onlyProblems: state == .unhealthy || state == .dead
        }
    }
}

// MARK: - Deployment state (single managed containers, distinct from Stacks)

public enum DeploymentState: String, Sendable, CaseIterable, Decodable {
    case deploying, running, created, restarting, stopping, removing
    case paused, exited, dead, unhealthy, unknown
    case notDeployed = "notdeployed"

    public init(from decoder: any Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        let key = raw.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "").lowercased()
        self = DeploymentState.allCases.first { $0.rawValue == key } ?? .unknown
    }

    public var displayName: String {
        switch self {
        case .notDeployed: "Not deployed"
        default: rawValue.capitalized
        }
    }

    public var severity: HealthSeverity {
        switch self {
        case .running: .healthy
        case .dead, .unhealthy: .error
        case .deploying, .created, .restarting, .stopping, .removing, .paused, .exited, .notDeployed: .warning
        case .unknown: .unknown
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

public struct DeploymentsSummary: Decodable, Sendable {
    public let total: Int
    public let running: Int
    public let stopped: Int
    public let notDeployed: Int
    public let unhealthy: Int
    public let unknown: Int

    public var needsAttention: Int {
        self.unhealthy
    }

    enum CodingKeys: String, CodingKey { case total, running, stopped, notDeployed, unhealthy, unknown }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func n(_ key: CodingKeys) -> Int {
            (try? c.decodeIfPresent(Int.self, forKey: key)) ?? 0
        }
        self.total = n(.total); self.running = n(.running); self.stopped = n(.stopped)
        self.notDeployed = n(.notDeployed); self.unhealthy = n(.unhealthy); self.unknown = n(.unknown)
    }
}

/// Rollup across all raw Docker containers on all connected servers.
public struct DockerContainersSummary: Decodable, Sendable {
    public let total: Int
    public let running: Int
    public let stopped: Int
    public let unhealthy: Int
    public let unknown: Int

    enum CodingKeys: String, CodingKey { case total, running, stopped, unhealthy, unknown }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func n(_ key: CodingKeys) -> Int {
            (try? c.decodeIfPresent(Int.self, forKey: key)) ?? 0
        }
        self.total = n(.total); self.running = n(.running); self.stopped = n(.stopped)
        self.unhealthy = n(.unhealthy); self.unknown = n(.unknown)
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

public struct DeploymentListItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let info: Info

    public struct Info: Decodable, Sendable {
        public let state: DeploymentState
        public let status: String?
        public let image: String?
        public let serverId: String?
    }

    public var state: DeploymentState {
        self.info.state
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

// MARK: - Alerts (ListAlerts)

/// Komodo alert severity. Wire form is `OK` / `WARNING` / `CRITICAL`.
public enum SeverityLevel: String, Sendable, CaseIterable, Decodable {
    case ok, warning, critical, unknown

    public init(from decoder: any Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = SeverityLevel(rawValue: raw.lowercased()) ?? .unknown
    }

    /// Ordering for "notify at this level and above". `unknown` ranks high so a new
    /// wire value is surfaced rather than silently suppressed by a threshold.
    public var rank: Int {
        switch self {
        case .ok: 0
        case .warning: 1
        case .critical: 2
        case .unknown: 2
        }
    }

    public var displayName: String {
        switch self {
        case .ok: "OK"
        case .warning: "Warning"
        case .critical: "Critical"
        case .unknown: "Alert"
        }
    }

    public var severity: HealthSeverity {
        switch self {
        case .ok: .healthy
        case .warning: .warning
        case .critical: .error
        case .unknown: .unknown
        }
    }
}

/// One Komodo alert. The `data` union carries per-variant fields we don't model;
/// we keep the variant name (`kind`) and the target so the UI can build a label.
public struct AlertItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let ts: Double // epoch milliseconds
    public let level: SeverityLevel
    public let resolved: Bool
    public let targetType: String?
    public let targetId: String?
    public let kind: String? // AlertData variant, e.g. "StackStateChange"

    public var date: Date {
        Date(timeIntervalSince1970: self.ts / 1000)
    }

    enum CodingKeys: String, CodingKey { case id = "_id", ts, level, resolved, target, data }
    private struct Target: Decodable { let type: String?; let id: String? }
    private struct DataBlock: Decodable { let type: String? }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `_id` is usually a hex string but can arrive as { "$oid": "…" }.
        if let s = try? c.decode(String.self, forKey: .id) {
            self.id = s
        } else if let oid = try? c.decode([String: String].self, forKey: .id) {
            self.id = oid["$oid"] ?? ""
        } else {
            self.id = ""
        }
        self.ts = (try? c.decode(Double.self, forKey: .ts)) ?? 0
        self.level = (try? c.decode(SeverityLevel.self, forKey: .level)) ?? .unknown
        self.resolved = (try? c.decode(Bool.self, forKey: .resolved)) ?? false
        let target = try? c.decode(Target.self, forKey: .target)
        self.targetType = target?.type
        self.targetId = target?.id
        self.kind = (try? c.decode(DataBlock.self, forKey: .data))?.type
    }
}

/// Response for ListAlerts.
public struct AlertsPage: Decodable, Sendable {
    public let alerts: [AlertItem]

    enum CodingKeys: String, CodingKey { case alerts }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.alerts = (try? c.decode([AlertItem].self, forKey: .alerts)) ?? []
    }
}
