import XCTest
@testable import ClaudeUsageWidget

final class ServicesTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "io.rsla.ClaudeUsageWidget.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func decode(_ json: String) throws -> UsageData {
        try UsageData.decode(from: Data(json.utf8))
    }

    /// The Max 20x fixture with the monthly budget switched on at 25% used (the shipped fixture has it off).
    private func usageMax20xWithBudgetJSON() -> String {
        let off = #""extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null"#
        let on = #""extra_usage": {"is_enabled": true, "monthly_limit": 5000, "used_credits": 1250, "utilization": 25"#
        XCTAssertTrue(Fixtures.usageMax20xJSON.contains(off), "The Max 20x fixture changed shape")
        return Fixtures.usageMax20xJSON.replacingOccurrences(of: off, with: on)
    }

    // MARK: - Labels

    func testBucketLabelsAreShort() {
        XCTAssertEqual(BucketKind.session.label, "5hr Session")
        XCTAssertEqual(BucketKind.weeklyAll.label, "Weekly")
        XCTAssertEqual(BucketKind.weeklyOpus.label, "Weekly (Opus)")
        XCTAssertEqual(BucketKind.weeklySonnet.label, "Weekly (Sonnet)")
    }

    // MARK: - ServiceID

    func testServiceIDsKeepPanelOrderAndFacts() throws {
        XCTAssertEqual(ServiceID.allCases, [.claude, .grokBot, .codex])
        XCTAssertEqual(ServiceID.allCases.map(\.rawValue), ["claude", "grokBot", "codex"])
        XCTAssertEqual(ServiceID.allCases.map(\.displayName), ["Claude", "Grok Bot", "Codex"])
        XCTAssertEqual(ServiceID.allCases.map(\.bundleIdentifier),
                       ["com.anthropic.claudefordesktop", "com.anysphere.sand", "com.openai.codex"])
        XCTAssertEqual(ServiceID.allCases.map(\.staleAfter), [900, 86400, 900])
        // Codable by raw value, so a stored or encoded service reads back as the same one.
        let encoded = try JSONEncoder().encode([ServiceID.grokBot])
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #"["grokBot"]"#)
        XCTAssertEqual(try JSONDecoder().decode([ServiceID].self, from: encoded), [.grokBot])
    }

    // MARK: - ServiceLimit

    func testLimitDerivesWhatIsLeftAndItsColor() {
        func limit(_ used: Double) -> ServiceLimit { ServiceLimit(label: "Weekly", percentUsed: used, resetsAt: nil) }
        XCTAssertEqual(limit(0.0704).percentLeft, 93)
        XCTAssertEqual(limit(0.0704).colorState, .normal)
        XCTAssertEqual(limit(0.67).percentLeft, 33)
        XCTAssertEqual(limit(0.67).colorState, .amber)
        XCTAssertEqual(limit(0.90).percentLeft, 10)
        XCTAssertEqual(limit(0.90).colorState, .critical)
        XCTAssertEqual(limit(1.3).percentLeft, 0)
        XCTAssertFalse(limit(0.5).isBudget)
    }

    // MARK: - UsageData -> limits

    func testUsageDataMapsToLimitsInOrderWithExtraUsageAsBudget() throws {
        let data = try decode(usageMax20xWithBudgetJSON())
        let session = try XCTUnwrap(data.bucket(.session))
        let week = try XCTUnwrap(data.bucket(.weeklyAll))
        XCTAssertNotNil(session.resetsAt)
        XCTAssertNotNil(week.resetsAt)

        let limits = data.serviceLimits
        XCTAssertEqual(limits, [
            ServiceLimit(label: "5hr Session", percentUsed: 0.08, resetsAt: session.resetsAt),
            ServiceLimit(label: "Weekly", percentUsed: 0.73, resetsAt: week.resetsAt),
            ServiceLimit(label: "Extra usage", percentUsed: 0.25, resetsAt: nil, isBudget: true),
        ])
        XCTAssertEqual(limits.map(\.percentLeft), [92, 27, 75])
        XCTAssertEqual(limits.map(\.colorState), [.normal, .amber, .normal])
    }

    func testAllFourBucketsKeepKindOrderAheadOfTheBudget() throws {
        let limits = try decode(Fixtures.usageProLikeJSON).serviceLimits
        XCTAssertEqual(limits.map(\.label), ["5hr Session", "Weekly", "Weekly (Opus)", "Weekly (Sonnet)", "Extra usage"])
        XCTAssertEqual(limits.map(\.isBudget), [false, false, false, false, true])
    }

    func testExtraUsageThatIsOffOrUnmeasuredIsNotALimit() throws {
        // The shipped Max 20x fixture has extra usage switched off.
        XCTAssertEqual(try decode(Fixtures.usageMax20xJSON).serviceLimits.map(\.label), ["5hr Session", "Weekly"])
        // On, but the API reports no utilization to show.
        let unmeasured = UsageData(buckets: [], extraUsage: ExtraUsage(isEnabled: true, percentUsed: nil))
        XCTAssertEqual(unmeasured.serviceLimits, [])
        // Off, even with a utilization left in the response.
        let off = UsageData(buckets: [], extraUsage: ExtraUsage(isEnabled: false, percentUsed: 0.4))
        XCTAssertEqual(off.serviceLimits, [])
    }

    // MARK: - Claude's sign-in state -> ServiceState

    func testClaudeStateMapping() throws {
        var data = try decode(Fixtures.usageMax20xJSON)
        data.lastUpdated = Date(timeIntervalSince1970: 1_794_000_000)

        // Signed in: the numbers, stamped with when they were fetched. Every identity counts.
        let profile = Profile(email: "test@example.com", displayName: "Test", organizationName: nil, organizationType: nil)
        for state in [AuthState.signedIn(.ownToken, profile), .signedIn(.claudeCode, nil), .signedIn(.webSession, nil)] {
            XCTAssertEqual(ServiceState.claude(state: state, data: data),
                           .reading(limits: data.serviceLimits, readAt: data.lastUpdated))
            XCTAssertEqual(ServiceState.claude(state: state, data: nil), .loading)
        }

        // Any other state: numbers left over from before it are never shown, so `data` is passed to prove it.
        XCTAssertEqual(ServiceState.claude(state: .unknown, data: data), .loading)
        XCTAssertEqual(ServiceState.claude(state: .signingIn, data: data), .loading)
        for state in [AuthState.signedOut(claudeCodeAvailable: true), .signedOut(claudeCodeAvailable: false)] {
            XCTAssertEqual(ServiceState.claude(state: state, data: data), .notSignedIn(hint: "Not signed in"))
        }
        for source in [IdentitySource.ownToken, .claudeCode, .webSession] {
            XCTAssertEqual(ServiceState.claude(state: .sessionExpired(source), data: data), .notSignedIn(hint: "Session expired"))
        }
        XCTAssertEqual(ServiceState.claude(state: .noChatOrg, data: data), .notSignedIn(hint: "No Claude plan on this account"))
        XCTAssertEqual(ServiceState.claude(state: .unreachable, data: data), .unavailable(reason: "Can't reach claude.ai"))
        XCTAssertEqual(ServiceState.claude(state: .unreachable, data: nil), .unavailable(reason: "Can't reach claude.ai"))
    }

    // MARK: - ServiceSettings

    func testSettingsRoundTripAndDefaults() {
        let settings = ServiceSettings(defaults: defaults)

        // Nothing stored: the menu bar shows the lowest limit and nothing is hidden.
        XCTAssertEqual(settings.menuBarChoice, .lowest)
        XCTAssertEqual(ServiceID.allCases.filter(settings.isHidden), [])

        settings.menuBarChoice = .service(.grokBot)
        XCTAssertEqual(settings.menuBarChoice, .service(.grokBot))
        XCTAssertEqual(defaults.string(forKey: "menuBarService"), "grokBot")
        XCTAssertEqual(ServiceSettings(defaults: defaults).menuBarChoice, .service(.grokBot), "A new launch reads the same choice")

        settings.menuBarChoice = .lowest
        XCTAssertEqual(settings.menuBarChoice, .lowest)
        XCTAssertEqual(defaults.string(forKey: "menuBarService"), "lowest")

        // An unknown value, such as one a later version wrote, reads as the default.
        defaults.set("x", forKey: "menuBarService")
        XCTAssertEqual(settings.menuBarChoice, .lowest)

        settings.setHidden(true, for: .codex)
        XCTAssertTrue(settings.isHidden(.codex))
        XCTAssertFalse(settings.isHidden(.claude))
        XCTAssertFalse(settings.isHidden(.grokBot))
        XCTAssertEqual(defaults.stringArray(forKey: "hiddenServices"), ["codex"])
        XCTAssertTrue(ServiceSettings(defaults: defaults).isHidden(.codex), "A new launch reads the same choice")

        settings.setHidden(false, for: .codex)
        XCTAssertEqual(ServiceID.allCases.filter(settings.isHidden), [])
    }

    func testHidingSeveralServicesKeepsEachOnceAndUnhidesOneAtATime() {
        let settings = ServiceSettings(defaults: defaults)
        settings.setHidden(true, for: .grokBot)
        settings.setHidden(true, for: .codex)
        settings.setHidden(true, for: .codex)
        XCTAssertEqual(ServiceID.allCases.filter(settings.isHidden), [.grokBot, .codex])
        XCTAssertEqual(defaults.stringArray(forKey: "hiddenServices")?.count, 2, "Hiding twice does not store it twice")

        settings.setHidden(false, for: .grokBot)
        XCTAssertEqual(ServiceID.allCases.filter(settings.isHidden), [.codex])
    }

    func testUnreadableHiddenServicesValueMeansNothingIsHidden() {
        let settings = ServiceSettings(defaults: defaults)
        defaults.set("codex", forKey: "hiddenServices")   // a string, not the array the app writes
        XCTAssertEqual(ServiceID.allCases.filter(settings.isHidden), [])
        settings.setHidden(true, for: .grokBot)
        XCTAssertEqual(ServiceID.allCases.filter(settings.isHidden), [.grokBot])
    }

    // MARK: - Old keys

    /// v0.6.0 replaced the rings and their "Show in Menu Bar" layout. Both keys earlier versions wrote are deleted at launch,
    /// not migrated: neither means anything now.
    func testRemoveLegacyKeysDeletesBothOldKeysAndNothingElse() {
        defaults.set("weekly", forKey: "ringMetricMode")
        defaults.set("session", forKey: "menuBarShows")
        defaults.set("grokBot", forKey: "menuBarService")
        defaults.set(["codex"], forKey: "hiddenServices")
        defaults.set(true, forKey: "claudeCodeTokenOptOut")

        ServiceSettings.removeLegacyKeys(from: defaults)

        XCTAssertNil(defaults.object(forKey: "ringMetricMode"))
        XCTAssertNil(defaults.object(forKey: "menuBarShows"))
        XCTAssertEqual(ServiceSettings(defaults: defaults).menuBarChoice, .service(.grokBot), "this version's own choices stay")
        XCTAssertTrue(ServiceSettings(defaults: defaults).isHidden(.codex))
        XCTAssertEqual(defaults.object(forKey: "claudeCodeTokenOptOut") as? Bool, true, "so do the sign-in flags")
        ServiceSettings.removeLegacyKeys(from: defaults)   // nothing to remove the second time: no trouble
    }

    // MARK: - Which services the panel shows

    func testShownServicesAreTheSetUpOnesMinusTheHiddenOnesInPanelOrder() {
        let settings = ServiceSettings(defaults: defaults)
        let setUp: [ServiceID] = [.claude, .grokBot, .codex]
        XCTAssertEqual(settings.shownServices(among: setUp), [.claude, .grokBot, .codex])

        settings.setHidden(true, for: .grokBot)
        XCTAssertEqual(settings.shownServices(among: setUp), [.claude, .codex])
        settings.setHidden(true, for: .claude)
        XCTAssertEqual(settings.shownServices(among: setUp), [.codex])
        settings.setHidden(false, for: .grokBot)
        XCTAssertEqual(settings.shownServices(among: setUp), [.grokBot, .codex])
    }

    /// Hidden for a service that is not set up is nothing to the panel, and a service that is not set up is never shown.
    func testShownServicesNeverIncludeOneThatIsNotSetUp() {
        let settings = ServiceSettings(defaults: defaults)
        settings.setHidden(true, for: .codex)   // hidden, and then it was uninstalled
        XCTAssertEqual(settings.shownServices(among: [.claude, .grokBot]), [.claude, .grokBot])
        XCTAssertEqual(ServiceSettings(defaults: defaults).shownServices(among: [.claude]), [.claude])
    }

    /// An empty panel is a dead end: when every set-up service is hidden (a stored choice that no longer fits what is
    /// installed), the first of them is shown anyway.
    func testAtLeastOneServiceAlwaysStaysShown() {
        let settings = ServiceSettings(defaults: defaults)
        for service in ServiceID.allCases { settings.setHidden(true, for: service) }
        XCTAssertEqual(settings.shownServices(among: [.claude, .grokBot, .codex]), [.claude])
        XCTAssertEqual(settings.shownServices(among: [.grokBot, .codex]), [.grokBot])
        XCTAssertEqual(settings.shownServices(among: [.claude]), [.claude])
    }

    // MARK: - What every service has to show

    private func weekly(_ used: Double) -> ServiceState {
        .reading(limits: [ServiceLimit(label: "Weekly", percentUsed: used, resetsAt: nil)], readAt: Date(timeIntervalSince1970: 1_000))
    }

    /// Claude's state comes from its own sign-in, the others from the poller. A set-up service the poller has not
    /// read yet is loading, and one that is not set up has no state at all, whatever the poller still holds for it.
    func testMergedStatesCoverEverySetUpServiceAndNothingElse() {
        let claude = ServiceState.notSignedIn(hint: "Not signed in")
        let merged = ServiceState.merged(claude: claude, others: [.grokBot: weekly(0.07)], setUp: [.claude, .grokBot, .codex])
        XCTAssertEqual(merged, [.claude: claude, .grokBot: weekly(0.07), .codex: .loading])

        let onlyClaude = ServiceState.merged(claude: .loading, others: [:], setUp: [.claude])
        XCTAssertEqual(onlyClaude, [.claude: .loading])

        // A stale entry for a service that is no longer set up (the preview's signed-out Codex) is dropped.
        let dropped = ServiceState.merged(claude: .loading, others: [.codex: .notSignedIn(hint: "Open Codex and sign in with ChatGPT")], setUp: [.claude, .grokBot])
        XCTAssertEqual(dropped, [.claude: .loading, .grokBot: .loading])
    }

    /// Claude's own state wins over anything the poller might say for it.
    func testMergedClaudeIsAlwaysItsOwn() {
        let merged = ServiceState.merged(claude: .loading, others: [.claude: weekly(0.5)], setUp: [.claude])
        XCTAssertEqual(merged, [.claude: .loading])
    }

    // MARK: - Is a reading current

    private let now = Date(timeIntervalSince1970: 1_794_000_000)

    /// A reading of one limit, taken `minutesAgo` minutes before `now`.
    private func reading(minutesAgo: Double, resets: Date? = nil, isBudget: Bool = false) -> ServiceState {
        .reading(limits: [ServiceLimit(label: "Weekly", percentUsed: 0.5, resetsAt: resets, isBudget: isBudget)],
                 readAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    /// Claude and Codex are polled every five minutes, so 15 minutes is three missed polls; Grok Bot's numbers only
    /// move when its Mac app refreshes them, so it counts as current for a day.
    func testReadingIsCurrentUntilItsOwnServicesClockRunsOut() {
        for (service, limitInMinutes) in [(ServiceID.claude, 15.0), (.codex, 15.0), (.grokBot, 24 * 60.0)] {
            XCTAssertTrue(reading(minutesAgo: limitInMinutes).isCurrent(service, now: now), "\(service) at its limit")
            XCTAssertFalse(reading(minutesAgo: limitInMinutes + 1).isCurrent(service, now: now), "\(service) just past it")
        }
    }

    /// A reading can be young and still from before a reset that has since happened.
    func testReadingFromBeforeAResetIsNotCurrent() {
        XCTAssertFalse(reading(minutesAgo: 1, resets: now.addingTimeInterval(-30)).isCurrent(.claude, now: now))
        XCTAssertFalse(reading(minutesAgo: 1, resets: now).isCurrent(.claude, now: now), "a reset at this very moment has happened")
        XCTAssertTrue(reading(minutesAgo: 1, resets: now.addingTimeInterval(1)).isCurrent(.claude, now: now), "a reset still ahead")
        XCTAssertTrue(reading(minutesAgo: 1, resets: nil).isCurrent(.claude, now: now), "no reset time is nothing to wait for")
        // One limit that has reset makes the whole reading old: the others were read before it too.
        let oneReset = ServiceState.reading(limits: [
            ServiceLimit(label: "5hr Session", percentUsed: 0.3, resetsAt: now.addingTimeInterval(3600)),
            ServiceLimit(label: "Weekly", percentUsed: 0.8, resetsAt: now.addingTimeInterval(-1)),
        ], readAt: now.addingTimeInterval(-60))
        XCTAssertFalse(oneReset.isCurrent(.claude, now: now))
    }

    /// A reset that came before the reading was taken is already in its numbers, so it says nothing against them.
    /// Only a reading taken before the reset can be out of date because of it.
    func testReadingTakenAfterAResetStaysCurrent() {
        // Taken a minute ago, the reset an hour ago: the numbers already count the new window.
        XCTAssertTrue(reading(minutesAgo: 1, resets: now.addingTimeInterval(-3600)).isCurrent(.claude, now: now))
        // Grok Bot's day-long clock the same way: read an hour ago, reset three hours ago.
        XCTAssertTrue(reading(minutesAgo: 60, resets: now.addingTimeInterval(-3 * 3600)).isCurrent(.grokBot, now: now))
        // A reset at the very moment of the reading is in the reading, not after it.
        XCTAssertTrue(reading(minutesAgo: 1, resets: now.addingTimeInterval(-60)).isCurrent(.claude, now: now))
        // One second later it is after the reading, and the reading is old.
        XCTAssertFalse(reading(minutesAgo: 1, resets: now.addingTimeInterval(-59)).isCurrent(.claude, now: now))
        // The reading's age still counts: a reset before it does not make an old reading current.
        XCTAssertFalse(reading(minutesAgo: 16, resets: now.addingTimeInterval(-3600)).isCurrent(.claude, now: now))
    }

    /// With several limits, the reading is old as soon as one of them reset after it was taken.
    func testOnlyALimitThatResetAfterTheReadingMakesItOld() {
        let readAt = now.addingTimeInterval(-60)
        func state(session: TimeInterval, weekly: TimeInterval) -> ServiceState {
            .reading(limits: [
                ServiceLimit(label: "5hr Session", percentUsed: 0.3, resetsAt: now.addingTimeInterval(session)),
                ServiceLimit(label: "Weekly", percentUsed: 0.8, resetsAt: now.addingTimeInterval(weekly)),
            ], readAt: readAt)
        }
        XCTAssertTrue(state(session: -3600, weekly: -7200).isCurrent(.claude, now: now), "both reset before the reading")
        XCTAssertTrue(state(session: -3600, weekly: 3600).isCurrent(.claude, now: now), "one reset before it, one still ahead")
        XCTAssertFalse(state(session: -3600, weekly: -30).isCurrent(.claude, now: now), "the second reset after the reading, and has happened")
        XCTAssertFalse(state(session: -30, weekly: 3600).isCurrent(.claude, now: now), "the first one, with the second still ahead")
    }

    /// A budget (Claude's extra usage) is spending, not a rate limit, so it never makes a reading old.
    func testBudgetNeverMakesAReadingOld() {
        // A reset after the reading and already past: on a rate limit that makes the reading old, so the budget
        // is what keeps this one current. (A reset from before the reading would prove nothing.)
        let resets = now.addingTimeInterval(-30)
        XCTAssertFalse(reading(minutesAgo: 1, resets: resets).isCurrent(.claude, now: now), "the same reset on a rate limit")
        XCTAssertTrue(reading(minutesAgo: 1, resets: resets, isBudget: true).isCurrent(.claude, now: now))
    }

    /// There are no numbers in the other states, so none of them is current.
    func testStatesWithoutNumbersAreNeverCurrent() {
        for state in [ServiceState.loading, .notSignedIn(hint: "Not signed in"), .unavailable(reason: "Can't reach claude.ai")] {
            XCTAssertFalse(state.isCurrent(.claude, now: now), "\(state)")
        }
    }
}
