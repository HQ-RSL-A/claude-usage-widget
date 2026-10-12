import Foundation

// MARK: - RingColorState

public enum RingColorState: Equatable {
    case normal    // 0–59%
    case amber     // 60–84%
    case critical  // 85–100%

    public static func from(percent: Double) -> RingColorState {
        switch percent {
        case ..<0.60:
            return .normal
        case 0.60..<0.85:
            return .amber
        default:
            return .critical
        }
    }
}

// MARK: - RingMetricMode

public enum RingMetricMode: String {
    case session
    case weekly

    public static let `default`: RingMetricMode = .session

    /// UserDefaults key for persisting the preference
    public static let userDefaultsKey = "ringMetricMode"

    /// Read the saved preference, falling back to default
    public static var saved: RingMetricMode {
        guard let raw = UserDefaults.standard.string(forKey: userDefaultsKey) else {
            return .default
        }
        return RingMetricMode(rawValue: raw) ?? .default
    }

    /// Save the preference to UserDefaults
    public func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.userDefaultsKey)
    }
}

// MARK: - BucketKind

/// The usage buckets the widget knows how to show, in display order. Raw values are the API keys.
public enum BucketKind: String, CaseIterable {
    case session = "five_hour"
    case weeklyAll = "seven_day"
    case weeklyOpus = "seven_day_opus"
    case weeklySonnet = "seven_day_sonnet"

    public var label: String {
        switch self {
        case .session: return "Current Session"
        case .weeklyAll: return "Weekly (all models)"
        case .weeklyOpus: return "Weekly (Opus)"
        case .weeklySonnet: return "Weekly (Sonnet)"
        }
    }

    public var isWeekly: Bool { self != .session }
}

// MARK: - UsageBucket

public struct UsageBucket: Equatable {
    public let kind: BucketKind
    public let percentUsed: Double   // 0.0 to 1.0
    public let resetsAt: Date?
    public let lockedReason: String?

    public init(kind: BucketKind, percentUsed: Double, resetsAt: Date?, lockedReason: String?) {
        self.kind = kind
        self.percentUsed = percentUsed
        self.resetsAt = resetsAt
        self.lockedReason = lockedReason
    }

    /// "resets in 42m" or "resets in 1h 12m"; "–" if nil or past
    public var resetsInDisplay: String {
        guard let date = resetsAt else { return "–" }
        let remaining = date.timeIntervalSinceNow
        guard remaining > 0 else { return "–" }

        let totalMinutes = Int(remaining / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "resets in \(hours)h \(minutes)m"
        } else {
            return "resets in \(minutes)m"
        }
    }

    public var barColorState: RingColorState {
        .from(percent: percentUsed)
    }

    /// "Fri 9:00 AM"; nil if resetsAt is nil
    public var resetsAtDisplay: String? {
        guard let date = resetsAt else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - ExtraUsage

public struct ExtraUsage: Equatable {
    public let isEnabled: Bool
    public let percentUsed: Double?   // 0.0 to 1.0 when the API reports utilization

    public init(isEnabled: Bool, percentUsed: Double?) {
        self.isEnabled = isEnabled
        self.percentUsed = percentUsed
    }
}

// MARK: - UsageData

public struct UsageData {
    /// Only the buckets the API returned with a utilization, in BucketKind order.
    public let buckets: [UsageBucket]
    public let extraUsage: ExtraUsage?
    public var lastUpdated: Date

    public init(buckets: [UsageBucket], extraUsage: ExtraUsage?, lastUpdated: Date = Date()) {
        self.buckets = buckets
        self.extraUsage = extraUsage
        self.lastUpdated = lastUpdated
    }

    public func bucket(_ kind: BucketKind) -> UsageBucket? {
        buckets.first { $0.kind == kind }
    }

    /// Ring value for a metric mode; 0 when the account has no such bucket.
    public func ringValue(for mode: RingMetricMode) -> Double {
        switch mode {
        case .session:
            return bucket(.session)?.percentUsed ?? 0.0
        case .weekly:
            return buckets.filter { $0.kind.isWeekly }.map(\.percentUsed).max() ?? 0.0
        }
    }

    public func ringColorState(for mode: RingMetricMode) -> RingColorState {
        .from(percent: ringValue(for: mode))
    }
}

// MARK: - JSON Decoding

private struct RawBucket: Decodable {
    let utilization: Double?
    let resets_at: Date?
    let locked_reason: String?
}

private struct RawExtraUsage: Decodable {
    let is_enabled: Bool?
    let utilization: Double?
}

/// Every key optional: plans differ in which buckets they return, and unknown keys are ignored.
private struct RawUsageResponse: Decodable {
    let five_hour: RawBucket?
    let seven_day: RawBucket?
    let seven_day_opus: RawBucket?
    let seven_day_sonnet: RawBucket?
    let extra_usage: RawExtraUsage?
}

extension UsageData {
    /// Decode from raw API JSON; handles fractional and whole-second ISO8601 dates.
    public static func decode(from data: Data) throws -> UsageData {
        let decoder = JSONDecoder()

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]

        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = fractionalFormatter.date(from: string) { return date }
            if let date = plainFormatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date from: \(string)")
        }

        let raw = try decoder.decode(RawUsageResponse.self, from: data)

        let pairs: [(BucketKind, RawBucket?)] = [
            (.session, raw.five_hour),
            (.weeklyAll, raw.seven_day),
            (.weeklyOpus, raw.seven_day_opus),
            (.weeklySonnet, raw.seven_day_sonnet),
        ]
        var buckets: [UsageBucket] = []
        for (kind, rawBucket) in pairs {
            guard let rawBucket, let utilization = rawBucket.utilization else { continue }
            buckets.append(UsageBucket(
                kind: kind,
                percentUsed: utilization / 100.0,
                resetsAt: rawBucket.resets_at,
                lockedReason: rawBucket.locked_reason
            ))
        }

        let extra = raw.extra_usage.map {
            ExtraUsage(isEnabled: $0.is_enabled ?? false, percentUsed: $0.utilization.map { $0 / 100.0 })
        }

        return UsageData(buckets: buckets, extraUsage: extra, lastUpdated: Date())
    }
}
