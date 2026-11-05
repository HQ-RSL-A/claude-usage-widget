import Foundation

// MARK: - StatusItemContent

/// What the menu bar item shows: one service's logo, a short title beside it, a badge dot on the logo when that
/// limit is running low, and whether the number is dimmed because it may not be current.
struct StatusItemContent: Equatable {
    var logo: ServiceID
    var title: String
    var badge: RingColorState
    var isDimmed: Bool
}

// MARK: - StatusPresentation

/// Everything the menu bar item says, worked out from each service's numbers, which services are shown and what
/// the menu bar is set to show. Pure, so AppDelegate only applies it.
struct StatusPresentation: Equatable {
    var content: StatusItemContent
    var toolTip: String
    var accessibilityValue: String

    /// The tooltip says how old a reading is once it is older than this: three missed polls of Claude or Codex.
    static let ageShownAfter: TimeInterval = 15 * 60

    /// The item shows the limit closest to running out across the shown services, or the pinned service's own
    /// lowest one. A reading that is not current never takes the place of one that is, so an old number is never
    /// passed off as new; alone, it shows dimmed. The one thing that takes the place of an old number is a shown
    /// Claude that is signed out (see below).
    static func make(services: [ServiceID: ServiceState], visible: [ServiceID], choice: MenuBarChoice, text: UsageText) -> StatusPresentation {
        // In the panel's order, whatever order the caller lists them in. A service with no state has nothing to show.
        let shown: [(id: ServiceID, state: ServiceState)] = ServiceID.allCases.compactMap { id in
            guard visible.contains(id), let state = services[id] else { return nil }
            return (id, state)
        }
        let everyLimit = shown.flatMap { candidates(of: $0.id, in: $0.state, now: text.now) }
        let toolTip = shown.flatMap { toolTipLines(for: $0.id, state: $0.state, text: text) }.joined(separator: "\n")

        // A sign-out has to be seen ("it always stays signed in" is why the bar is trusted). With no current number
        // anywhere, a shown Claude that is signed out says "Sign in", not an old number from another service,
        // whatever is pinned. A current number of any shown service still wins: it is true.
        if isSignedOut(.claude, in: shown), everyLimit.allSatisfy(\.isStale) {
            return noNumbers(for: .claude, shown: shown, toolTip: toolTip, text: text)
        }

        let pinned: ServiceID? = {
            guard case .service(let id) = choice, shown.contains(where: { $0.id == id }) else { return nil }
            return id
        }()

        // A pinned service with numbers is the only one considered. Without numbers it would be a dead item, and
        // one that is hidden is not shown at all: both fall back to the lowest across the shown services.
        var pool = everyLimit
        if let pinned, everyLimit.contains(where: { $0.service == pinned }) {
            pool = everyLimit.filter { $0.service == pinned }
        }
        let current = pool.filter { !$0.isStale }
        guard let pick = lowest(in: current.isEmpty ? pool : current) else {
            return noNumbers(for: pinned ?? shown.first?.id ?? .claude, shown: shown, toolTip: toolTip, text: text)
        }

        let isDimmed = current.isEmpty
        let content = StatusItemContent(logo: pick.service, title: text.percentRemain(pick.limit.percentLeft),
                                        badge: pick.limit.colorState, isDimmed: isDimmed)
        // VoiceOver has no dimming to hear, so it says so in words.
        let value = "\(pick.service.displayName) \(pick.limit.label), \(pick.limit.percentLeft)% remaining" + (isDimmed ? ", out of date" : "")
        return StatusPresentation(content: content, toolTip: toolTip, accessibilityValue: value)
    }

    // MARK: - Choosing

    /// One limit of one service that the menu bar could show.
    private struct Candidate {
        var service: ServiceID
        var limit: ServiceLimit
        var isStale: Bool
    }

    /// The limits of a reading that can run out, with when it was read. A budget (Claude's extra usage) is left out:
    /// it is spending, never the thing that is about to run out. Nil for a state with no such limit.
    private static func rateReading(_ state: ServiceState) -> (limits: [ServiceLimit], readAt: Date)? {
        guard case .reading(let limits, let readAt) = state else { return nil }
        let rateLimits = limits.filter { !$0.isBudget }
        return rateLimits.isEmpty ? nil : (rateLimits, readAt)
    }

    /// Whether this service is among the shown ones and is not signed in.
    private static func isSignedOut(_ service: ServiceID, in shown: [(id: ServiceID, state: ServiceState)]) -> Bool {
        guard case .notSignedIn? = shown.first(where: { $0.id == service })?.state else { return false }
        return true
    }

    private static func candidates(of service: ServiceID, in state: ServiceState, now: Date) -> [Candidate] {
        guard let reading = rateReading(state) else { return [] }
        // Old by the service's own clock, or from before a reset: either way the number may no longer be true.
        // The panel asks the same question of the same reading (`ServiceState.isCurrent`), so the two always agree.
        let isStale = !state.isCurrent(service, now: now)
        return reading.limits.map { Candidate(service: service, limit: $0, isStale: isStale) }
    }

    /// The limit with the least left. Limits that read the same are a tie, and a tie goes to the earlier service,
    /// then the earlier limit.
    private static func lowest(in candidates: [Candidate]) -> Candidate? {
        candidates.reduce(nil) { best, next in
            guard let best else { return next }
            return next.limit.percentLeft < best.limit.percentLeft ? next : best
        }
    }

    // MARK: - No numbers

    /// No service has a number to show. The item stands for one service and says what is wrong with it. "Sign in" is
    /// a call to action, so it is drawn at full strength (dimmed it was 2.6:1 on a light menu bar), and it is only
    /// Claude's: the panel has Claude's sign-in buttons. Grok Bot and Codex are signed in from their own apps, which
    /// nothing here can do anything about, so theirs says "No data". "Updating", "Offline" and "No data" say there is
    /// nothing to act on, and stay dimmed like an old number.
    private static func noNumbers(for service: ServiceID, shown: [(id: ServiceID, state: ServiceState)], toolTip: String, text: UsageText) -> StatusPresentation {
        let state = shown.first { $0.id == service }?.state ?? .loading
        let title: String
        var isDimmed = true
        switch state {
        case .notSignedIn:
            if service == .claude {
                title = "Sign in"
                isDimmed = false
            } else {
                title = "No data"
            }
        case .loading: title = "Updating"
        case .unavailable: title = "Offline"
        case .reading: title = "No data"   // a reading with no limit in it
        }
        return StatusPresentation(
            content: StatusItemContent(logo: service, title: title, badge: .normal, isDimmed: isDimmed),
            toolTip: toolTip,
            accessibilityValue: "\(service.displayName), \(text.lowercasedFirst(note(for: state)))"
        )
    }

    /// Why a service has no number, in the service's own words.
    private static func note(for state: ServiceState) -> String {
        switch state {
        case .loading: return "Updating"
        case .notSignedIn(let hint): return hint
        case .unavailable(let reason): return reason
        case .reading: return "No usage limits reported"
        }
    }

    // MARK: - Tooltip

    /// One line per limit with what is left and when it resets, then how old the reading is when it is not fresh.
    /// A service with no numbers gets one line saying why.
    private static func toolTipLines(for service: ServiceID, state: ServiceState, text: UsageText) -> [String] {
        let name = service.displayName
        guard let reading = rateReading(state) else { return ["\(name): \(note(for: state))"] }
        var lines = reading.limits.map { limit -> String in
            let line = "\(name) \(limit.label): \(limit.percentLeft)% left"
            return text.reset(limit.resetsAt).map { line + ", " + text.lowercasedFirst($0) } ?? line
        }
        if text.now.timeIntervalSince(reading.readAt) > ageShownAfter {
            lines.append("\(name) updated \(text.age(of: reading.readAt))")
        }
        return lines
    }
}
