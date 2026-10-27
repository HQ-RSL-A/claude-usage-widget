import Foundation

/// Everything the menu bar item says, worked out from the sign-in state, the latest numbers and the layout
/// preference. Pure, so AppDelegate only applies it.
struct StatusPresentation: Equatable {
    var icon: StatusIconModel
    var toolTip: String
    var accessibilityValue: String

    /// Three missed polls: the numbers are dimmed so they never look current when they are not.
    static let staleAfter: TimeInterval = 15 * 60

    static func make(state: AuthState, data: UsageData?, layout: MenuBarLayout, text: UsageText) -> StatusPresentation {
        let slots = layout == .both ? 2 : 1
        guard case .signedIn = state else { return noNumbers(slots: slots, phrase: phrase(for: state)) }
        guard let data else { return noNumbers(slots: slots, phrase: "updating") }

        func ring(_ bucket: UsageBucket?) -> StatusIconModel.Ring {
            bucket.map { .usage(left: $0.percentLeft, used: $0.percentUsed, color: $0.barColorState) } ?? .noData
        }
        // A missing bucket keeps its slot, so the item's width never changes.
        let rings: [StatusIconModel.Ring]
        switch layout {
        case .both: rings = [ring(data.sessionBucket), ring(data.weekBucket)]
        case .session: rings = [ring(data.sessionBucket)]
        case .week: rings = [ring(data.weekBucket)]
        }
        let isStale = text.now.timeIntervalSince(data.lastUpdated) > staleAfter
        let hasNoNumbers = rings.allSatisfy { $0 == .noData }
        return StatusPresentation(
            icon: StatusIconModel(rings: rings, isDimmed: isStale || hasNoNumbers),
            toolTip: text.tooltip(for: data),
            accessibilityValue: text.accessibilityValue(for: data)
        )
    }

    private static func noNumbers(slots: Int, phrase: String) -> StatusPresentation {
        StatusPresentation(
            icon: StatusIconModel(rings: Array(repeating: .noData, count: slots), isDimmed: true),
            toolTip: "Claude Usage: \(phrase)",
            accessibilityValue: phrase.prefix(1).uppercased() + phrase.dropFirst()
        )
    }

    private static func phrase(for state: AuthState) -> String {
        switch state {
        case .unknown: return "checking sign-in"
        case .unreachable: return "can't reach claude.ai"
        case .signedOut: return "not signed in"
        case .signingIn: return "waiting for your browser"
        case .sessionExpired: return "session expired"
        case .noChatOrg: return "no Claude plan on this account"
        case .signedIn: return "updating"
        }
    }
}
