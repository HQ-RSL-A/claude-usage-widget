import Foundation

/// Made-up usage for checking the menu bar and popover on a real Mac without signing in.
/// Launch with `open ClaudeUsageWidget.app --args -previewUsage amber`: no Keychain read, no WebKit, no network.
/// Claude's numbers come from `state` and `data(now:)`; Grok Bot's and Codex's from `services(now:)`, with no file read.
enum PreviewScenario: String, CaseIterable {
    case fresh
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
        case .fresh:
            return UsageData(buckets: [bucket(.session, 0, resetsIn: 5 * hour), bucket(.weeklyAll, 0.34, resetsIn: 4 * 24 * hour)], extraUsage: nil, lastUpdated: now)
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

    /// The services that get a section in the panel. Every scenario shows all three except `signedOut`,
    /// which has no Codex section even though `services(now:)` still holds Codex's not-signed-in state.
    var setUpServices: [ServiceID] {
        switch self {
        case .signedOut: return [.claude, .grokBot]
        default: return [.claude, .grokBot, .codex]
        }
    }

    /// Made-up Grok Bot and Codex states, read at `now` unless a scenario says otherwise. Claude stays on `state` and `data(now:)`.
    func services(now: Date) -> [ServiceID: ServiceState] {
        let hour: TimeInterval = 3600
        let day = 24 * hour
        func limit(_ label: String, _ used: Double, resetsIn seconds: TimeInterval) -> ServiceLimit {
            ServiceLimit(label: label, percentUsed: used, resetsAt: now.addingTimeInterval(seconds))
        }
        // Grok Bot has one weekly limit.
        func grokBot(_ used: Double, resetsIn seconds: TimeInterval, readAt: Date? = nil) -> ServiceState {
            .reading(limits: [limit("Weekly", used, resetsIn: seconds)], readAt: readAt ?? now)
        }
        // Codex has a 5 hour session and a weekly limit. A reset a scenario doesn't set is 2 hr and 5 days.
        func codex(session: Double, week: Double, sessionResetsIn: TimeInterval = 2 * hour, weekResetsIn: TimeInterval = 5 * day) -> ServiceState {
            .reading(limits: [limit("5hr Session", session, resetsIn: sessionResetsIn), limit("Weekly", week, resetsIn: weekResetsIn)], readAt: now)
        }
        switch self {
        case .fresh:
            return [.grokBot: grokBot(0.05, resetsIn: 6 * day), .codex: codex(session: 0.0, week: 0.10)]
        case .normal:
            return [.grokBot: grokBot(0.07, resetsIn: 6 * day), .codex: codex(session: 0.20, week: 0.35)]
        case .amber:
            return [.grokBot: grokBot(0.65, resetsIn: 2 * day), .codex: codex(session: 0.30, week: 0.50)]
        case .critical:
            return [.grokBot: grokBot(0.90, resetsIn: day),
                    .codex: codex(session: 0.88, week: 0.70, sessionResetsIn: 40 * 60, weekResetsIn: 3 * day)]
        case .limit:
            return [.grokBot: grokBot(1.0, resetsIn: 20 * hour), .codex: codex(session: 0.20, week: 0.35)]
        case .stale:
            // Past Grok Bot's 24 hour limit for a current reading, so the panel has to say it is old.
            return [.grokBot: grokBot(0.07, resetsIn: 6 * day, readAt: now.addingTimeInterval(-26 * hour)),
                    .codex: .unavailable(reason: "Couldn't reach Codex")]
        case .signedOut:
            return [.grokBot: grokBot(0.07, resetsIn: 6 * day),
                    .codex: .notSignedIn(hint: "Open Codex and sign in with ChatGPT")]
        }
    }
}
