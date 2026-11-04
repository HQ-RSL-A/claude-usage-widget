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
}
