import XCTest
@testable import ClaudeUsageWidget

final class StatusPresentationTests: XCTestCase {

    /// Wednesday 4 November 2026, 21:00 UTC. The zone is UTC and the locale US English, so every string is exact.
    private let now = ISO8601DateFormatter().date(from: "2026-11-04T21:00:00Z")!

    private func usageText(at time: Date) -> UsageText {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return UsageText(now: time, calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
    }

    private var text: UsageText { usageText(at: now) }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// The system formatter puts a narrow no-break space (U+202F) before "AM" and "PM"; either space reads the same.
    private func plain(_ string: String) -> String { string.replacingOccurrences(of: "\u{202F}", with: " ") }

    // MARK: - Fixtures

    private func limit(_ label: String, used: Double, resets: Date? = nil, isBudget: Bool = false) -> ServiceLimit {
        ServiceLimit(label: label, percentUsed: used, resetsAt: resets, isBudget: isBudget)
    }

    /// Claude's 5 hour session resets in 3 hr 10 min and its week on Tuesday at 2:00 AM.
    private func claude(session: Double = 0.17, weekly: Double = 0.10, minutesAgo: Double = 1) -> ServiceState {
        .reading(limits: [
            limit("5hr Session", used: session, resets: now.addingTimeInterval(3 * 3600 + 10 * 60)),
            limit("Weekly", used: weekly, resets: date("2026-11-10T02:00:00Z")),
        ], readAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    /// Grok Bot has one weekly limit and only changes when its Mac app refreshes, so its reading is usually a while old.
    private func grokBot(weekly: Double = 0.0704, minutesAgo: Double = 40) -> ServiceState {
        .reading(limits: [limit("Weekly", used: weekly, resets: date("2026-11-10T13:21:00Z"))],
                 readAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    /// One limit, for the tests that only care about the number or the age.
    private func oneLimit(_ used: Double = 0.5, minutesAgo: Double = 1) -> ServiceState {
        .reading(limits: [limit("Weekly", used: used, resets: now.addingTimeInterval(7 * 24 * 3600))],
                 readAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    /// Every service that has a state is shown unless `visible` says otherwise.
    private func make(_ services: [ServiceID: ServiceState], visible: [ServiceID]? = nil, choice: MenuBarChoice = .lowest) -> StatusPresentation {
        StatusPresentation.make(services: services,
                                visible: visible ?? ServiceID.allCases.filter { services[$0] != nil },
                                choice: choice, text: text)
    }

    // MARK: - Which number

    func testLowestAcrossServicesWins() {
        let presentation = make([.claude: claude(session: 0.17, weekly: 0.10), .grokBot: grokBot(weekly: 0.60)])
        XCTAssertEqual(presentation.content, StatusItemContent(logo: .grokBot, title: "40% remain", badge: .amber, isDimmed: false))
    }

    func testTieGoesToEarlierServiceAndLimit() {
        // Every limit has 50% left. The earlier service wins, and inside it the earlier limit.
        let tied: [ServiceID: ServiceState] = [.claude: claude(session: 0.5, weekly: 0.5), .grokBot: grokBot(weekly: 0.5)]
        let presentation = make(tied)
        XCTAssertEqual(presentation.content.logo, .claude)
        XCTAssertEqual(presentation.accessibilityValue, "Claude 5hr Session, 50% remaining")
        // The panel's order decides, whatever order the caller lists the services in.
        XCTAssertEqual(make(tied, visible: [.grokBot, .claude]), presentation)
        // Without Claude there is no tie left.
        XCTAssertEqual(make(tied, visible: [.grokBot]).content.logo, .grokBot)
    }

    func testTwoLimitsThatReadTheSameAreATie() {
        // 0.504 used and 0.496 used both read "50% remain", so the earlier limit wins even though the week is a hair lower.
        let presentation = make([.claude: claude(session: 0.496, weekly: 0.504)])
        XCTAssertEqual(presentation.content, StatusItemContent(logo: .claude, title: "50% remain", badge: .normal, isDimmed: false))
        XCTAssertEqual(presentation.accessibilityValue, "Claude 5hr Session, 50% remaining")
    }

    func testBudgetNeverDrivesMenuBar() {
        let withBudget = ServiceState.reading(limits: [
            limit("5hr Session", used: 0.30, resets: now.addingTimeInterval(3600)),
            limit("Weekly", used: 0.20, resets: date("2026-11-10T02:00:00Z")),
            limit("Extra usage", used: 0.99, isBudget: true),
        ], readAt: now)
        let presentation = make([.claude: withBudget])
        XCTAssertEqual(presentation.content, StatusItemContent(logo: .claude, title: "70% remain", badge: .normal, isDimmed: false))
        XCTAssertFalse(presentation.toolTip.contains("Extra usage"))
        // A budget alone is nothing to show.
        let onlyBudget = ServiceState.reading(limits: [limit("Extra usage", used: 0.99, isBudget: true)], readAt: now)
        XCTAssertEqual(make([.claude: onlyBudget]).content, StatusItemContent(logo: .claude, title: "No data", badge: .normal, isDimmed: true))
    }

    func testHiddenServiceIsLeftOutOfEverything() {
        let services: [ServiceID: ServiceState] = [.claude: claude(), .grokBot: grokBot(weekly: 0.60)]
        let onlyClaude = make(services, visible: [.claude])
        XCTAssertEqual(onlyClaude.content, StatusItemContent(logo: .claude, title: "83% remain", badge: .normal, isDimmed: false))
        XCTAssertFalse(onlyClaude.toolTip.contains("Grok Bot"))
        XCTAssertFalse(onlyClaude.accessibilityValue.contains("Grok Bot"))
    }

    // MARK: - Pinned service

    func testPinnedServiceShown() {
        let services: [ServiceID: ServiceState] = [.claude: claude(session: 0.17, weekly: 0.10), .grokBot: grokBot(weekly: 0.60)]
        // Grok Bot is lower, but Claude is pinned: Claude's own lowest limit shows.
        XCTAssertEqual(make(services, choice: .service(.claude)).content,
                       StatusItemContent(logo: .claude, title: "83% remain", badge: .normal, isDimmed: false))
        XCTAssertEqual(make(services, choice: .service(.grokBot)).content,
                       StatusItemContent(logo: .grokBot, title: "40% remain", badge: .amber, isDimmed: false))
    }

    func testPinnedServiceHiddenFallsBackToLowest() {
        // Codex has the lowest number of all, but it is hidden: the pin is dropped instead of showing a dead item.
        let services: [ServiceID: ServiceState] = [.claude: claude(), .grokBot: grokBot(weekly: 0.60), .codex: oneLimit(0.95)]
        let pinnedToHidden = make(services, visible: [.claude, .grokBot], choice: .service(.codex))
        XCTAssertEqual(pinnedToHidden, make(services, visible: [.claude, .grokBot], choice: .lowest))
        XCTAssertEqual(pinnedToHidden.content, StatusItemContent(logo: .grokBot, title: "40% remain", badge: .amber, isDimmed: false))
    }

    func testPinnedServiceWithoutNumbersFallsBackToLowest() {
        // Pinned to Codex, but Codex is signed out, still loading or unreachable: the bar falls back to the lowest.
        let lowest = make([.claude: claude(), .grokBot: grokBot(weekly: 0.60)]).content
        XCTAssertEqual(lowest.logo, .grokBot)
        for state in [ServiceState.notSignedIn(hint: "Open Codex to sign in"), .loading, .unavailable(reason: "Can't reach ChatGPT")] {
            let presentation = make([.claude: claude(), .grokBot: grokBot(weekly: 0.60), .codex: state], choice: .service(.codex))
            XCTAssertEqual(presentation.content, lowest, "\(state)")
        }
    }

    func testPinnedServiceWithAnOldReadingStaysPinnedAndDimmed() {
        // Rahul pinned Grok Bot. Its reading is a day old, so it shows dimmed; Claude's fresh number does not replace it.
        let services: [ServiceID: ServiceState] = [.claude: claude(), .grokBot: grokBot(weekly: 0.90, minutesAgo: 25 * 60)]
        XCTAssertEqual(make(services, choice: .service(.grokBot)).content,
                       StatusItemContent(logo: .grokBot, title: "10% remain", badge: .critical, isDimmed: true))
    }

    // MARK: - Stale readings

    func testStaleReadingIsDimmedAndFreshOneWins() {
        // Grok Bot's reading is 25 hours old (its Mac app has not refreshed it) and lower than Claude's.
        let stale = grokBot(weekly: 0.90, minutesAgo: 25 * 60)
        let both = make([.claude: claude(session: 0.30, weekly: 0.20), .grokBot: stale])
        XCTAssertEqual(both.content, StatusItemContent(logo: .claude, title: "70% remain", badge: .normal, isDimmed: false))
        // Alone, the old reading still shows, dimmed: the bar says what it knows without passing it off as current.
        XCTAssertEqual(make([.grokBot: stale]).content, StatusItemContent(logo: .grokBot, title: "10% remain", badge: .critical, isDimmed: true))
    }

    func testEachServiceGoesStaleAfterItsOwnAge() {
        // Claude and Codex are polled every five minutes, so 15 minutes is three missed polls. Grok Bot's numbers
        // only move when its Mac app refreshes them, so it counts as current for a day.
        for (service, limitInMinutes) in [(ServiceID.claude, 15.0), (.codex, 15.0), (.grokBot, 24 * 60.0)] {
            XCTAssertFalse(make([service: oneLimit(minutesAgo: limitInMinutes)]).content.isDimmed, "\(service) at its limit")
            XCTAssertTrue(make([service: oneLimit(minutesAgo: limitInMinutes + 1)]).content.isDimmed, "\(service) just past it")
        }
    }

    func testReadingFromBeforeAResetCountsAsStale() {
        // Read a minute ago, but Claude's session reset 30 seconds ago: the 5% it shows is from before the reset.
        let beforeReset = ServiceState.reading(limits: [
            limit("5hr Session", used: 0.95, resets: now.addingTimeInterval(-30)),
            limit("Weekly", used: 0.20, resets: date("2026-11-10T02:00:00Z")),
        ], readAt: now.addingTimeInterval(-60))
        XCTAssertEqual(make([.claude: beforeReset]).content, StatusItemContent(logo: .claude, title: "5% remain", badge: .critical, isDimmed: true))
        // A current reading wins over it, even a higher one.
        XCTAssertEqual(make([.claude: beforeReset, .grokBot: grokBot(weekly: 0.60)]).content,
                       StatusItemContent(logo: .grokBot, title: "40% remain", badge: .amber, isDimmed: false))
    }

    func testAnyLimitThatHasResetMakesTheWholeReadingStale() {
        // The week reset, the session did not: both numbers are from before the reset.
        let weekReset = ServiceState.reading(limits: [
            limit("5hr Session", used: 0.30, resets: now.addingTimeInterval(3600)),
            limit("Weekly", used: 0.80, resets: now.addingTimeInterval(-1)),
        ], readAt: now.addingTimeInterval(-60))
        XCTAssertTrue(make([.claude: weekReset]).content.isDimmed)
    }

    func testResetBoundaryAndLimitsThatNeverResetDoNotCount() {
        func dimmed(resets: Date?, isBudget: Bool = false) -> Bool {
            let reading = ServiceState.reading(limits: [
                limit("5hr Session", used: 0.40, resets: now.addingTimeInterval(3600)),
                limit(isBudget ? "Extra usage" : "Weekly", used: 0.50, resets: resets, isBudget: isBudget),
            ], readAt: now.addingTimeInterval(-60))
            return make([.claude: reading]).content.isDimmed
        }
        XCTAssertTrue(dimmed(resets: now), "a reset at this very moment has happened")
        XCTAssertFalse(dimmed(resets: now.addingTimeInterval(1)), "a reset still ahead")
        XCTAssertFalse(dimmed(resets: nil), "no reset time is nothing to wait for")
        XCTAssertFalse(dimmed(resets: now.addingTimeInterval(-3600), isBudget: true), "a budget is not a rate limit")
    }

    // MARK: - No numbers

    func testNoNumbersSaysWhy() {
        // "Sign in" is a call to action, so it is drawn at full strength (dimmed it was 2.6:1 on a light menu bar).
        // "Updating" and "Offline" say there is nothing to act on, and stay dimmed.
        let cases: [(ServiceState, String, Bool)] = [
            (.notSignedIn(hint: "Not signed in"), "Sign in", false),
            (.loading, "Updating", true),
            (.unavailable(reason: "Can't reach claude.ai"), "Offline", true),
        ]
        for (state, title, isDimmed) in cases {
            XCTAssertEqual(make([.claude: state]).content,
                           StatusItemContent(logo: .claude, title: title, badge: .normal, isDimmed: isDimmed), "\(state)")
        }
    }

    /// Every way of being signed out says the same thing in the same strength, whatever the hint inside the panel says.
    func testSignInIsNeverDimmedForAnyHintOrService() {
        for hint in ["Not signed in", "Session expired", "No Claude plan on this account"] {
            XCTAssertEqual(make([.claude: .notSignedIn(hint: hint)]).content,
                           StatusItemContent(logo: .claude, title: "Sign in", badge: .normal, isDimmed: false), hint)
        }
        XCTAssertEqual(make([.grokBot: .notSignedIn(hint: "Open Grok Bot and sign in")]).content,
                       StatusItemContent(logo: .grokBot, title: "Sign in", badge: .normal, isDimmed: false))
        // Stale numbers are not a call to action: they stay dimmed.
        XCTAssertTrue(make([.grokBot: grokBot(weekly: 0.90, minutesAgo: 25 * 60)]).content.isDimmed)
        XCTAssertTrue(make([.claude: .reading(limits: [], readAt: now)]).content.isDimmed, "a reading with nothing in it is not either")
    }

    func testNoNumbersAnywhereShowsThePinnedOrFirstShownService() {
        let services: [ServiceID: ServiceState] = [
            .claude: .loading,
            .grokBot: .notSignedIn(hint: "Open Grok Bot to sign in"),
            .codex: .unavailable(reason: "Can't reach ChatGPT"),
        ]
        XCTAssertEqual(make(services).content, StatusItemContent(logo: .claude, title: "Updating", badge: .normal, isDimmed: true))
        XCTAssertEqual(make(services, visible: [.grokBot, .codex]).content.logo, .grokBot)
        XCTAssertEqual(make(services, choice: .service(.codex)).content,
                       StatusItemContent(logo: .codex, title: "Offline", badge: .normal, isDimmed: true))
        XCTAssertEqual(make(services, visible: [.claude, .grokBot], choice: .service(.codex)).content.logo, .claude,
                       "a pinned service that is hidden is not the one to show")
    }

    func testReadingWithoutLimitsSaysNoData() {
        let presentation = make([.claude: .reading(limits: [], readAt: now)])
        XCTAssertEqual(presentation.content, StatusItemContent(logo: .claude, title: "No data", badge: .normal, isDimmed: true))
        XCTAssertEqual(presentation.toolTip, "Claude: No usage limits reported")
        XCTAssertEqual(presentation.accessibilityValue, "Claude, no usage limits reported")
    }

    func testNothingShownStillGivesADimmedItem() {
        // Not reachable from the app (Claude is always shown), but the function must not trip over it.
        XCTAssertEqual(make([:], visible: []).content, StatusItemContent(logo: .claude, title: "Updating", badge: .normal, isDimmed: true))
        // A shown service the app has no state for is left out, not guessed at.
        XCTAssertEqual(make([.claude: claude()], visible: [.claude, .codex]).content.logo, .claude)
    }

    // MARK: - Tooltip

    func testTooltipListsEveryShownService() {
        let presentation = make([.claude: claude(), .grokBot: grokBot()])
        XCTAssertEqual(plain(presentation.toolTip).components(separatedBy: "\n"), [
            "Claude 5hr Session: 83% left, resets in 3 hr 10 min",
            "Claude Weekly: 90% left, resets Tue 2:00 AM",
            "Grok Bot Weekly: 93% left, resets Tue 1:21 PM",
            "Grok Bot updated 40 min ago",
        ])
    }

    func testTooltipAgeLineAppearsOnlyForAReadingOlderThanFifteenMinutes() {
        for (minutes, showsAge) in [(1.0, false), (15.0, false), (16.0, true)] {
            let tooltip = make([.claude: claude(minutesAgo: minutes)]).toolTip
            XCTAssertEqual(tooltip.contains("updated"), showsAge, "\(minutes) min old")
        }
        XCTAssertTrue(make([.claude: claude(minutesAgo: 16)]).toolTip.hasSuffix("\nClaude updated 16 min ago"))
    }

    func testTooltipSaysWhyAServiceHasNoNumbers() {
        let presentation = make([.claude: claude(), .grokBot: .notSignedIn(hint: "Open Grok Bot to sign in"), .codex: .loading])
        XCTAssertEqual(plain(presentation.toolTip).components(separatedBy: "\n"), [
            "Claude 5hr Session: 83% left, resets in 3 hr 10 min",
            "Claude Weekly: 90% left, resets Tue 2:00 AM",
            "Grok Bot: Open Grok Bot to sign in",
            "Codex: Updating",
        ])
    }

    func testTooltipLeavesOutTheResetOnceItHasPassed() {
        let past = ServiceState.reading(limits: [limit("Weekly", used: 0.5, resets: now.addingTimeInterval(-60))], readAt: now)
        XCTAssertEqual(make([.claude: past]).toolTip, "Claude Weekly: 50% left")
    }

    // MARK: - VoiceOver

    func testAccessibilityValueNamesTheShownLimit() {
        let presentation = make([.claude: claude(session: 0.17, weekly: 0.10), .grokBot: grokBot(weekly: 0.60)])
        XCTAssertEqual(presentation.accessibilityValue, "Grok Bot Weekly, 40% remaining")
    }

    func testAccessibilityValueSaysWhenTheNumberIsOld() {
        // The bar dims an old number; VoiceOver has no dimming, so it says so in words.
        let stale = make([.grokBot: grokBot(weekly: 0.90, minutesAgo: 25 * 60)])
        XCTAssertEqual(stale.accessibilityValue, "Grok Bot Weekly, 10% remaining, out of date")
        // Also when the reading is young but from before a reset.
        let beforeReset = ServiceState.reading(limits: [limit("Weekly", used: 0.95, resets: now.addingTimeInterval(-30))], readAt: now.addingTimeInterval(-60))
        XCTAssertEqual(make([.claude: beforeReset]).accessibilityValue, "Claude Weekly, 5% remaining, out of date")
    }

    func testAccessibilityValueSaysWhyThereAreNoNumbers() {
        let cases: [(ServiceState, String)] = [
            (.notSignedIn(hint: "Session expired"), "Claude, session expired"),
            (.loading, "Claude, updating"),
            (.unavailable(reason: "Can't reach claude.ai"), "Claude, can't reach claude.ai"),
        ]
        for (state, value) in cases {
            XCTAssertEqual(make([.claude: state]).accessibilityValue, value, "\(state)")
        }
    }

    // MARK: - Claude alone, as the app wires it until the panel work lands

    func testClaudeAloneFromItsSignInState() throws {
        // The Max 20x fixture is dated 12 October 2026, so this test keeps that day's clock.
        let october = date("2026-10-12T21:00:00Z")
        var data = try UsageData.decode(from: Data(Fixtures.usageMax20xJSON.utf8))
        data.lastUpdated = october.addingTimeInterval(-60)

        func presentation(_ state: AuthState) -> StatusPresentation {
            StatusPresentation.make(services: [.claude: .claude(state: state, data: data)], visible: [.claude], choice: .lowest, text: usageText(at: october))
        }
        let signedIn = presentation(.signedIn(.claudeCode, nil))
        XCTAssertEqual(signedIn.content, StatusItemContent(logo: .claude, title: "27% remain", badge: .amber, isDimmed: false))
        XCTAssertEqual(plain(signedIn.toolTip).components(separatedBy: "\n"), [
            "Claude 5hr Session: 92% left, resets in 1 hr",
            "Claude Weekly: 27% left, resets Fri 4:00 PM",
        ])
        // Numbers left over from before a sign-out are never shown.
        XCTAssertEqual(presentation(.signedOut(claudeCodeAvailable: true)).content,
                       StatusItemContent(logo: .claude, title: "Sign in", badge: .normal, isDimmed: false))
        XCTAssertEqual(presentation(.unreachable).content,
                       StatusItemContent(logo: .claude, title: "Offline", badge: .normal, isDimmed: true))
    }
}
