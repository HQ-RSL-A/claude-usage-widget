import Foundation

// MARK: - RingColorState

public enum RingColorState: Equatable {
    case normal    // under 60% used
    case amber     // 60 to 84% used
    case critical  // 85% used and up

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

// MARK: - MenuBarLayout

/// Which rings the menu bar item shows. Replaced the one-ring Session/Weekly toggle (`ringMetricMode`, v0.2.0 to v0.4.2).
public enum MenuBarLayout: String, CaseIterable {
    case both
    case session
    case week

    public static let userDefaultsKey = "menuBarShows"

    /// Keys earlier versions wrote. Not migrated: the old ring mode would hide the new two-ring layout.
    static let legacyKeys = ["ringMetricMode"]

    public static func load(from defaults: UserDefaults) -> MenuBarLayout {
        defaults.string(forKey: userDefaultsKey).flatMap(MenuBarLayout.init(rawValue:)) ?? .both
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.userDefaultsKey)
    }

    public static func removeLegacyKeys(from defaults: UserDefaults) {
        legacyKeys.forEach { defaults.removeObject(forKey: $0) }
    }

    public var menuTitle: String {
        switch self {
        case .both: return "Session and Week"
        case .session: return "Session Only"
        case .week: return "Week Only"
        }
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
        case .session: return "Current session"
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

    public var barColorState: RingColorState {
        .from(percent: percentUsed)
    }

    /// What's left, as a whole percent. 100 minus the rounded used percent, so it always adds up
    /// to 100 with the "% used" claude.ai shows.
    public var percentLeft: Int { Self.percentLeft(forUsed: percentUsed) }

    public static func percentLeft(forUsed used: Double) -> Int {
        max(0, min(100, 100 - Int((used * 100).rounded())))
    }

    public var isAtLimit: Bool { percentLeft == 0 }
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

    public var sessionBucket: UsageBucket? { bucket(.session) }

    /// The weekly limit closest to running out; on a tie, the first in BucketKind order.
    public var weekBucket: UsageBucket? {
        buckets.filter(\.kind.isWeekly).reduce(nil) { best, next in
            guard let best else { return next }
            return next.percentUsed > best.percentUsed ? next : best
        }
    }

    /// The earliest reset still ahead of `now`.
    public func nextReset(after now: Date) -> Date? {
        buckets.compactMap(\.resetsAt).filter { $0 > now }.min()
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
