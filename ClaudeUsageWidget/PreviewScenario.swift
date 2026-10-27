import Foundation

/// Made-up usage for checking the menu bar and popover on a real Mac without signing in.
/// Launch with `open ClaudeUsageWidget.app --args -previewUsage amber`: no Keychain read, no WebKit, no network.
enum PreviewScenario: String, CaseIterable {
    case normal
    case amber
    case critical
    case limit
    case stale
    case signedOut

    static let launchArgumentKey = "previewUsage"

    /// `-previewUsage <name>` lands in UserDefaults' argument domain.
    static func fromLaunchArguments(_ defaults: UserDefaults = .standard) -> PreviewScenario? {
        defaults.string(forKey: launchArgumentKey).flatMap(PreviewScenario.init(rawValue:))
    }

    var state: AuthState {
        switch self {
        case .signedOut:
            return .signedOut(claudeCodeAvailable: true)
        default:
            return .signedIn(.ownToken, Profile(email: "preview@example.com", displayName: nil, organizationName: nil, organizationType: nil))
        }
    }

    func data(now: Date) -> UsageData? {
        func bucket(_ kind: BucketKind, _ used: Double, resetsIn seconds: TimeInterval) -> UsageBucket {
            UsageBucket(kind: kind, percentUsed: used, resetsAt: now.addingTimeInterval(seconds), lockedReason: nil)
        }
        let hour: TimeInterval = 3600
        switch self {
        case .normal:
            return UsageData(buckets: [bucket(.session, 0.12, resetsIn: 3 * hour + 600), bucket(.weeklyAll, 0.34, resetsIn: 4 * 24 * hour)], extraUsage: nil, lastUpdated: now)
        case .amber:
            return UsageData(buckets: [bucket(.session, 0.12, resetsIn: 3 * hour + 600), bucket(.weeklyAll, 0.74, resetsIn: 3 * hour + 49 * 60)], extraUsage: nil, lastUpdated: now)
        case .critical:
            return UsageData(buckets: [bucket(.session, 0.91, resetsIn: 42 * 60), bucket(.weeklyAll, 0.88, resetsIn: 2 * 24 * hour)], extraUsage: nil, lastUpdated: now)
        case .limit:
            return UsageData(buckets: [bucket(.session, 1.0, resetsIn: hour + 12 * 60), bucket(.weeklyAll, 0.74, resetsIn: 3 * hour + 49 * 60)], extraUsage: nil, lastUpdated: now)
        case .stale:
            return UsageData(buckets: [bucket(.session, 0.12, resetsIn: 3 * hour + 600), bucket(.weeklyAll, 0.34, resetsIn: 4 * 24 * hour)], extraUsage: nil, lastUpdated: now.addingTimeInterval(-20 * 60))
        case .signedOut:
            return nil
        }
    }
}
