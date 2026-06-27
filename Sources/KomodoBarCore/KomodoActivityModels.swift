import Foundation

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

// MARK: - Updates (operation history)

/// The Update an execute endpoint returns. Used to tell whether an operation that
/// returned HTTP 200 actually *completed successfully*, vs reported a failure.
public struct KomodoUpdate: Decodable, Sendable {
    public let success: Bool
    public let status: String?

    enum CodingKeys: String, CodingKey { case success, status }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Absent success must NOT fabricate a failure (some endpoints return NoData).
        self.success = (try? c.decode(Bool.self, forKey: .success)) ?? true
        self.status = try? c.decode(String.self, forKey: .status)
    }

    /// Only a finished update can be judged failed; in-progress ones aren't failures.
    public var completed: Bool {
        (self.status ?? "").replacingOccurrences(of: "_", with: "").lowercased() == "complete"
    }
}

/// One row of the operation history (ListUpdates).
public struct UpdateListItem: Decodable, Sendable, Identifiable {
    public let id: String
    public let operation: String?
    public let success: Bool
    public let status: String?
    public let startTs: Double
    public let targetType: String?
    public let targetId: String?

    public var date: Date {
        Date(timeIntervalSince1970: self.startTs / 1000)
    }

    /// Healthy when it succeeded, error on a completed failure, warning while running.
    public var severity: HealthSeverity {
        if self.success { return .healthy }
        let done = (self.status ?? "").replacingOccurrences(of: "_", with: "").lowercased() == "complete"
        return done ? .error : .warning
    }

    enum CodingKeys: String, CodingKey { case id, operation, success, status, startTs, target }
    private struct Target: Decodable { let type: String?; let id: String? }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decode(String.self, forKey: .id)) ?? ""
        self.operation = try? c.decode(String.self, forKey: .operation)
        self.success = (try? c.decode(Bool.self, forKey: .success)) ?? false
        self.status = try? c.decode(String.self, forKey: .status)
        self.startTs = (try? c.decode(Double.self, forKey: .startTs)) ?? 0
        let target = try? c.decode(Target.self, forKey: .target)
        self.targetType = target?.type
        self.targetId = target?.id
    }
}

/// Response for ListUpdates.
public struct UpdatesPage: Decodable, Sendable {
    public let updates: [UpdateListItem]

    enum CodingKeys: String, CodingKey { case updates }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.updates = (try? c.decode([UpdateListItem].self, forKey: .updates)) ?? []
    }
}
