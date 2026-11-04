import Foundation

// MARK: - ServiceID

/// The AI services the panel can show. Declaration order is panel order.
enum ServiceID: String, CaseIterable, Codable {
    case claude
    case grokBot
    case codex

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .grokBot: return "Grok Bot"
        case .codex: return "Codex"
        }
    }

    /// The Mac app whose icon the panel shows.
    var bundleIdentifier: String {
        switch self {
        case .claude: return "com.anthropic.claudefordesktop"
        case .grokBot: return "com.anysphere.sand"
        case .codex: return "com.openai.codex"
        }
    }

    /// How old a reading can be and still count as current. Claude and Codex are polled every five minutes,
    /// so 15 minutes is three missed polls. Grok Bot's numbers only change when its Mac app refreshes them,
    /// and the reading it saves expires after 24 hours.
    var staleAfter: TimeInterval {
        switch self {
        case .claude, .codex: return 15 * 60
        case .grokBot: return 24 * 3600
        }
    }
}

// MARK: - ServiceLimit

/// One limit of one service, in the terms the menu bar and the panel both show.
struct ServiceLimit: Equatable {
    var label: String
    var percentUsed: Double   // 0.0 to 1.0
    var resetsAt: Date?
    /// A spending budget (Claude's extra usage) rather than a rate limit. The panel shows it; the menu bar never picks it.
    var isBudget: Bool = false

    /// What's left, as a whole percent. The same rounding as `UsageBucket`, so it adds up with "% used".
    var percentLeft: Int { UsageBucket.percentLeft(forUsed: percentUsed) }
    var colorState: RingColorState { .from(percent: percentUsed) }
}

// MARK: - ServiceState

/// What one service has to show right now.
enum ServiceState: Equatable {
    case loading
    case reading(limits: [ServiceLimit], readAt: Date)
    case notSignedIn(hint: String)
    case unavailable(reason: String)
}

extension ServiceState {
    /// Claude keeps its own sign-in and polling (`AuthManager`, `UsageService`); this maps what they report onto the shared model.
    /// Numbers count only while signed in, so nothing left over from before a sign-out or an expiry is ever shown.
    static func claude(state: AuthState, data: UsageData?) -> ServiceState {
        switch state {
        case .signedIn:
            guard let data else { return .loading }
            return .reading(limits: data.serviceLimits, readAt: data.lastUpdated)
        case .unknown, .signingIn:
            return .loading
        case .signedOut:
            return .notSignedIn(hint: "Not signed in")
        case .sessionExpired:
            return .notSignedIn(hint: "Session expired")
        case .noChatOrg:
            return .notSignedIn(hint: "No Claude plan on this account")
        case .unreachable:
            return .unavailable(reason: "Can't reach claude.ai")
        }
    }
}

extension UsageData {
    /// The limits in display order: the buckets in `BucketKind` order, then the monthly budget
    /// when extra usage is on and the API reports how much of it is used.
    var serviceLimits: [ServiceLimit] {
        var limits = buckets.map {
            ServiceLimit(label: $0.kind.label, percentUsed: $0.percentUsed, resetsAt: $0.resetsAt)
        }
        if let extra = extraUsage, extra.isEnabled, let used = extra.percentUsed {
            limits.append(ServiceLimit(label: "Extra usage", percentUsed: used, resetsAt: nil, isBudget: true))
        }
        return limits
    }
}

// MARK: - Menu bar choice and settings

/// What the menu bar item shows: the limit closest to running out across the shown services, or one pinned service.
enum MenuBarChoice: Equatable {
    case lowest
    case service(ServiceID)
}

/// The two panel choices, kept in UserDefaults: which services are hidden, and what the menu bar shows.
struct ServiceSettings {
    static let hiddenServicesKey = "hiddenServices"
    static let menuBarServiceKey = "menuBarService"
    private static let lowestValue = "lowest"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func isHidden(_ id: ServiceID) -> Bool {
        hiddenRawValues.contains(id.rawValue)
    }

    func setHidden(_ hidden: Bool, for id: ServiceID) {
        var raw = hiddenRawValues
        raw.removeAll { $0 == id.rawValue }
        if hidden { raw.append(id.rawValue) }
        defaults.set(raw, forKey: Self.hiddenServicesKey)
    }

    /// A missing or unrecognized value reads as `.lowest`.
    var menuBarChoice: MenuBarChoice {
        get {
            guard let raw = defaults.string(forKey: Self.menuBarServiceKey), let id = ServiceID(rawValue: raw) else { return .lowest }
            return .service(id)
        }
        nonmutating set {
            switch newValue {
            case .lowest: defaults.set(Self.lowestValue, forKey: Self.menuBarServiceKey)
            case .service(let id): defaults.set(id.rawValue, forKey: Self.menuBarServiceKey)
            }
        }
    }

    /// Raw values as stored, including any this version does not know. Anything that is not an array of strings reads as empty.
    private var hiddenRawValues: [String] {
        defaults.stringArray(forKey: Self.hiddenServicesKey) ?? []
    }
}

// MARK: - ServiceReader

/// A service the app reads by itself beside Claude (Grok Bot, Codex). Claude is mapped from its own sign-in instead.
@MainActor
protocol ServiceReader: AnyObject {
    var service: ServiceID { get }
    /// True when the service's files are on this Mac, so it is worth reading. Only set-up readers are polled.
    func isSetUp() -> Bool
    func read() async -> ServiceState
}
