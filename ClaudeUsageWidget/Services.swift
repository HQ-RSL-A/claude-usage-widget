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

extension ServiceState {
    /// Whether the numbers may be shown as current. The menu bar and the panel both ask this, so they always agree.
    /// A reading is current until it is older than its service keeps it current, and it stops being current once a
    /// limit that can run out has reset: the reading may be from before the reset. A budget (Claude's extra
    /// usage) is spending, not a rate limit, so it never counts. The other states have no numbers to be current.
    func isCurrent(_ service: ServiceID, now: Date) -> Bool {
        guard case .reading(let limits, let readAt) = self else { return false }
        if now.timeIntervalSince(readAt) > service.staleAfter { return false }
        return !limits.contains { limit in !limit.isBudget && (limit.resetsAt.map { $0 <= now } ?? false) }
    }

    /// What every service that is set up on this Mac has to show: Claude's from its own sign-in, the others from
    /// `others` (the poller's states). A set-up service with no state yet is loading, and a service that is not set up
    /// has none at all, whatever `others` still holds for it. Never derived from `others`' keys: the shown services
    /// come from what is set up.
    static func merged(claude: ServiceState, others: [ServiceID: ServiceState], setUp: [ServiceID]) -> [ServiceID: ServiceState] {
        var states: [ServiceID: ServiceState] = [:]
        for service in setUp {
            states[service] = service == .claude ? claude : others[service] ?? .loading
        }
        return states
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

    /// The services with a section in the panel: the set-up ones that are not hidden, in the order they are given
    /// (panel order). Never empty, because an empty panel is a dead end: when every set-up service is hidden (a
    /// stored choice that no longer fits what is installed) the first of them is shown anyway.
    func shownServices(among setUp: [ServiceID]) -> [ServiceID] {
        let shown = setUp.filter { !isHidden($0) }
        return shown.isEmpty ? [setUp.first ?? .claude] : shown
    }

    /// Keys earlier versions wrote: `ringMetricMode` (v0.2.0 to v0.4.2, one ring) and `menuBarShows` (v0.5.0 and v0.5.1,
    /// which rings the menu bar drew). Deleted at launch, not migrated: neither means anything now.
    static let legacyKeys = ["ringMetricMode", "menuBarShows"]

    static func removeLegacyKeys(from defaults: UserDefaults) {
        legacyKeys.forEach { defaults.removeObject(forKey: $0) }
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
