import XCTest
@testable import ClaudeUsageWidget

@MainActor
final class MenuViewTests: XCTestCase {

    /// The clock the popover reads; tests move it forward.
    private var clock = ISO8601DateFormatter().date(from: "2026-10-12T21:00:00Z")!

    private func fixedText() -> UsageText {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return UsageText(now: clock, calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// A popover with a fixed clock and plain icons, so nothing here depends on the apps installed on this Mac.
    private func controller(state: AuthState = .signedIn(.webSession, nil)) -> MenuViewController {
        let vc = MenuViewController()
        vc.makeText = { [unowned self] in self.fixedText() }
        vc.panelIcon = { _ in NSImage(size: NSSize(width: 28, height: 28)) }
        _ = vc.view
        vc.render(state: state)
        return vc
    }

    private func max20x() throws -> UsageData {
        var data = try UsageData.decode(from: Data(Fixtures.usageMax20xJSON.utf8))
        data.lastUpdated = clock
        return data
    }

    private func proLike() throws -> UsageData {
        var data = try UsageData.decode(from: Data(Fixtures.usageProLikeJSON.utf8))
        data.lastUpdated = clock
        return data
    }

    /// Grok Bot's one weekly limit, 7% used by default so 93% is left.
    private func grokBot(used: Double = 0.07, readAt: Date? = nil, resetsIn: TimeInterval = 6 * 24 * 3600) -> ServiceState {
        .reading(limits: [ServiceLimit(label: "Weekly", percentUsed: used, resetsAt: clock.addingTimeInterval(resetsIn))],
                 readAt: readAt ?? clock)
    }

    private let codexHint = "Open Codex and sign in with ChatGPT"

    /// The system formatter puts a narrow no-break space (U+202F) before "PM"; either space reads the same.
    private func plain(_ rows: [[String]]) -> [[String]] {
        rows.map { $0.map { $0.replacingOccurrences(of: "\u{202F}", with: " ") } }
    }

    // MARK: - Sections

    func testSectionsFollowShownServicesInOrder() throws {
        let vc = controller()
        vc.shownServices = { [.claude, .grokBot, .codex] }
        vc.update(with: try max20x())
        vc.update(services: [.codex: .notSignedIn(hint: codexHint), .grokBot: grokBot()])
        XCTAssertEqual(vc.sectionServices, [.claude, .grokBot, .codex])

        // A hidden service drops out even though it still has a state.
        vc.shownServices = { [.claude, .codex] }
        vc.update(services: [.codex: .notSignedIn(hint: codexHint), .grokBot: grokBot()])
        XCTAssertEqual(vc.sectionServices, [.claude, .codex])

        // A shown service with nothing to say yet has no section.
        vc.shownServices = { [.claude, .grokBot, .codex] }
        vc.update(services: [.grokBot: grokBot()])
        XCTAssertEqual(vc.sectionServices, [.claude, .grokBot])

        // The order is the one the caller gives.
        vc.shownServices = { [.grokBot, .claude] }
        vc.update(services: [.grokBot: grokBot()])
        XCTAssertEqual(vc.sectionServices, [.grokBot, .claude])
    }

    /// Claude is shown from its own sign-in and numbers; a Claude entry in the list of the other services changes nothing.
    func testClaudeIsNotTakenFromTheServicesList() throws {
        let vc = controller()
        vc.update(with: try max20x())
        vc.update(services: [.claude: .notSignedIn(hint: "Not signed in")])
        XCTAssertEqual(vc.rows(for: .claude).count, 2)
        XCTAssertNil(vc.note(for: .claude))
    }

    func testTheHeaderSaysUsageRemaining() {
        XCTAssertEqual(controller().headerTitle, "Usage Remaining")
    }

    /// Opening the panel must not look every icon up again: the default source is the app's one shared cache.
    func testThePanelsOwnIconsComeFromTheSharedCache() {
        let vc = MenuViewController()
        for service in ServiceID.allCases {
            XCTAssertTrue(vc.panelIcon(service) === ServiceIcon.panelIcons.icon(for: service), "\(service)")
        }
    }

    func testEachSectionShowsItsServicesIcon() throws {
        let vc = controller()
        let icons: [ServiceID: NSImage] = Dictionary(uniqueKeysWithValues: ServiceID.allCases.map { ($0, NSImage(size: NSSize(width: 28, height: 28))) })
        vc.panelIcon = { icons[$0]! }
        vc.shownServices = { [.claude, .grokBot] }
        vc.update(with: try max20x())
        vc.update(services: [.grokBot: grokBot()])
        XCTAssertTrue(vc.iconImage(for: .claude) === icons[.claude])
        XCTAssertTrue(vc.iconImage(for: .grokBot) === icons[.grokBot])
        XCTAssertNil(vc.iconImage(for: .codex), "no section, no icon")

        // Other icons are picked up by the next draw, though nothing else changed.
        let others = Dictionary(uniqueKeysWithValues: ServiceID.allCases.map { ($0, NSImage(size: NSSize(width: 28, height: 28))) })
        vc.panelIcon = { others[$0]! }
        vc.renderTimes()
        XCTAssertTrue(vc.iconImage(for: .claude) === others[.claude])
        XCTAssertTrue(vc.iconImage(for: .grokBot) === others[.grokBot])
    }

    // MARK: - Rows

    func testRowsShowLabelPercentAndShortReset() throws {
        let vc = controller()
        vc.update(with: try max20x())
        // 8% and 73% used; the session resets in an hour (a time), the week in four days (a date).
        XCTAssertEqual(plain(vc.rows(for: .claude)), [["5hr Session", "92%", "10:00 PM"], ["Weekly", "27%", "Oct 16"]])
    }

    func testOtherServicesShowRowsToo() {
        let vc = controller()
        vc.shownServices = { [.claude, .grokBot] }
        vc.update(services: [.grokBot: grokBot()])
        XCTAssertEqual(vc.rows(for: .grokBot), [["Weekly", "93%", "Oct 18"]])
        XCTAssertNil(vc.note(for: .grokBot), "a fresh reading needs no note")
    }

    func testRowTooltipIsTheFullResetTime() throws {
        let vc = controller()
        vc.update(with: try max20x())
        XCTAssertEqual(vc.rowToolTips(for: .claude).map { $0?.replacingOccurrences(of: "\u{202F}", with: " ") },
                       ["Resets Mon Oct 12, 10:00 PM", "Resets Fri Oct 16, 4:00 PM"])
    }

    /// Claude's rows come from `UsageData.serviceLimits`, so the monthly budget is a row like any other.
    func testExtraUsageIsARowWithNoReset() throws {
        let vc = controller()
        vc.update(with: try proLike())
        XCTAssertEqual(plain(vc.rows(for: .claude)), [
            ["5hr Session", "58%", "10:00 PM"],
            ["Weekly", "33%", "Oct 16"],
            ["Weekly (Opus)", "60%", "Oct 16"],
            ["Weekly (Sonnet)", "88%", "Oct 16"],
            ["Extra usage", "65%", ""],
        ])
        XCTAssertEqual(vc.rowToolTips(for: .claude).last, "Monthly budget")
    }

    func testPercentIsAmberFrom60UsedAndRedFrom85() {
        let vc = controller()
        vc.shownServices = { [.claude, .grokBot] }
        let used = [0.0, 0.59, 0.60, 0.84, 0.85, 1.0]
        vc.update(services: [.grokBot: .reading(limits: used.map { ServiceLimit(label: "Weekly", percentUsed: $0, resetsAt: nil) }, readAt: clock)])
        XCTAssertEqual(vc.rows(for: .grokBot).map { $0[1] }, ["100%", "41%", "40%", "16%", "15%", "0%"])
        // Under 60% used the number is plain text; from there it is amber, from 85% red. Which amber and red is
        // the next test: they depend on the panel's appearance.
        let colors = vc.rowPercentColors(for: .grokBot)
        XCTAssertEqual(colors.prefix(2).map { $0 }, [.labelColor, .labelColor])
        XCTAssertEqual(colors.dropFirst(2).prefix(2).map { Self.hex($0, in: .aqua) }, ["#B45309", "#B45309"])
        XCTAssertEqual(colors.dropFirst(4).map { Self.hex($0, in: .aqua) }, ["#DC2626", "#DC2626"])
    }

    /// The menu bar's amber (#F59E0B) is about 2:1 against a light panel, too faint for a number, and Rahul's rule is
    /// that colored digits must not get lost. So on a light panel the numbers use a darker amber and red, and on a
    /// dark one the brighter pair. The menu bar's own colors do not change (`StatusIconTests` pins them).
    func testPercentColorsFollowThePanelsAppearance() {
        let vc = controller()
        vc.shownServices = { [.claude, .grokBot] }
        let limits = [0.2, 0.60, 0.85].map { ServiceLimit(label: "Weekly", percentUsed: $0, resetsAt: nil) }
        vc.update(services: [.grokBot: .reading(limits: limits, readAt: clock)])
        let colors = vc.rowPercentColors(for: .grokBot)

        XCTAssertEqual(colors[1...].map { Self.hex($0, in: .aqua) }, ["#B45309", "#DC2626"], "light panel")
        XCTAssertEqual(colors[1...].map { Self.hex($0, in: .darkAqua) }, ["#F59E0B", "#EF4444"], "dark panel")
        // Plain numbers stay the system's label color in both.
        XCTAssertEqual(Self.hex(colors[0], in: .aqua), Self.hex(.labelColor, in: .aqua))
        XCTAssertEqual(Self.hex(colors[0], in: .darkAqua), Self.hex(.labelColor, in: .darkAqua))
    }

    /// The panel's colors as a hex string in one appearance, the way that appearance would draw them.
    private static func hex(_ color: NSColor, in name: NSAppearance.Name) -> String {
        var result = "?"
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            func byte(_ value: CGFloat) -> Int { Int((value * 255).rounded()) }
            result = String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
        }
        return result
    }

    func testNoLimitsSaysSo() {
        let vc = controller()
        vc.update(with: UsageData(buckets: [], extraUsage: nil, lastUpdated: clock))
        XCTAssertEqual(vc.rows(for: .claude), [])
        XCTAssertEqual(vc.note(for: .claude), "No usage limits reported for this plan")
    }

    func testReplacingTheNumbersReplacesTheRows() throws {
        let vc = controller()
        vc.update(with: try proLike())
        XCTAssertEqual(vc.rows(for: .claude).count, 5)
        vc.update(with: try max20x())
        XCTAssertEqual(vc.rows(for: .claude).count, 2)
    }

    func testClaudeShowsNoNumbersUntilTheyArrive() {
        let vc = controller()
        XCTAssertEqual(vc.sectionServices, [.claude])
        XCTAssertEqual(vc.rows(for: .claude), [])
        XCTAssertEqual(vc.note(for: .claude), "Loading...")
    }

    func testFailureWithoutNumbersSaysSoInsteadOfLoading() {
        let vc = controller()
        vc.showLoading()
        vc.showError("Offline or claude.ai unreachable")
        XCTAssertEqual(vc.note(for: .claude), "Couldn't load usage")
        vc.showLoading()
        XCTAssertEqual(vc.note(for: .claude), "Loading...")
    }

    // MARK: - Notes

    func testStaleGrokBotSectionSaysItsAge() {
        let vc = controller()
        vc.shownServices = { [.claude, .grokBot] }
        vc.update(services: [.grokBot: grokBot(readAt: clock.addingTimeInterval(-40 * 60))])
        XCTAssertEqual(vc.rows(for: .grokBot), [["Weekly", "93%", "Oct 18"]], "its numbers stay")
        XCTAssertEqual(vc.note(for: .grokBot), "Updated 40 min ago")

        // The note is for readings older than 15 minutes, and moves with the clock.
        vc.update(services: [.grokBot: grokBot(readAt: clock.addingTimeInterval(-15 * 60))])
        XCTAssertNil(vc.note(for: .grokBot))
        clock = clock.addingTimeInterval(60)
        vc.renderTimes()
        XCTAssertEqual(vc.note(for: .grokBot), "Updated 16 min ago")

        // Grok Bot is often days old: the note says so in days.
        vc.update(services: [.grokBot: grokBot(readAt: clock.addingTimeInterval(-3 * 24 * 3600))])
        XCTAssertEqual(vc.note(for: .grokBot), "Updated 3 days ago")
    }

    /// Tertiary text measured 1.9:1 against a light panel. The note under a stale reading is the one that says the
    /// numbers cannot be trusted, so it is the secondary label color, the same as a hint that stands alone.
    func testSectionNotesUseTheSecondaryLabelColor() {
        let vc = controller()
        vc.shownServices = { [.claude, .grokBot, .codex] }
        vc.update(services: [.grokBot: grokBot(readAt: clock.addingTimeInterval(-40 * 60)), .codex: .notSignedIn(hint: codexHint)])
        XCTAssertEqual(vc.note(for: .grokBot), "Updated 40 min ago")
        XCTAssertEqual(vc.noteColor(for: .grokBot), .secondaryLabelColor, "under numbers")
        XCTAssertEqual(vc.noteColor(for: .codex), .secondaryLabelColor, "on its own")
    }

    /// Claude's age lives in the footer; its section never carries the note.
    func testClaudeSectionNeverCarriesTheAgeNote() throws {
        let vc = controller()
        vc.update(with: try max20x())
        clock = clock.addingTimeInterval(40 * 60)
        vc.renderTimes()
        XCTAssertNil(vc.note(for: .claude))
        XCTAssertEqual(vc.statusText, "Updated 40 min ago")
    }

    func testHintShownForNotSignedInService() {
        let vc = controller()
        vc.shownServices = { [.claude, .codex] }
        vc.update(services: [.codex: .notSignedIn(hint: codexHint)])
        XCTAssertEqual(vc.rows(for: .codex), [])
        XCTAssertEqual(vc.note(for: .codex), codexHint)
        XCTAssertEqual(vc.visibleSignInButtons, [], "Claude's buttons are Claude's alone")
    }

    func testReasonShownForUnavailableService() {
        let vc = controller()
        vc.shownServices = { [.claude, .codex] }
        vc.update(services: [.codex: .unavailable(reason: "Couldn't reach Codex")])
        XCTAssertEqual(vc.rows(for: .codex), [])
        XCTAssertEqual(vc.note(for: .codex), "Couldn't reach Codex")
    }

    func testLoadingServiceSaysSo() {
        let vc = controller()
        vc.shownServices = { [.claude, .codex] }
        vc.update(services: [.codex: .loading])
        XCTAssertEqual(vc.rows(for: .codex), [])
        XCTAssertEqual(vc.note(for: .codex), "Loading...")
    }

    // MARK: - Out-of-date numbers

    /// A number that is out of date must not look current: it is dimmed, beside the note that says how old it is.
    func testOutOfDateReadingIsDimmed() throws {
        let vc = controller()
        vc.shownServices = { [.claude, .grokBot] }
        vc.update(with: try max20x())

        // Grok Bot's numbers count for a day: 40 minutes is current, 25 hours is not.
        vc.update(services: [.grokBot: grokBot(readAt: clock.addingTimeInterval(-40 * 60))])
        XCTAssertFalse(vc.isDimmed(.grokBot))
        vc.update(services: [.grokBot: grokBot(readAt: clock.addingTimeInterval(-25 * 3600))])
        XCTAssertTrue(vc.isDimmed(.grokBot))
        XCTAssertFalse(vc.isDimmed(.claude))

        // Claude's count for 15 minutes.
        clock = clock.addingTimeInterval(16 * 60)
        vc.renderTimes()
        XCTAssertTrue(vc.isDimmed(.claude))
    }

    /// Numbers from before a reset are out of date even when they are young.
    func testReadingFromBeforeAResetIsDimmed() {
        let vc = controller()
        vc.shownServices = { [.claude, .grokBot] }
        vc.update(services: [.grokBot: grokBot(readAt: clock.addingTimeInterval(-3600), resetsIn: -60)])
        XCTAssertTrue(vc.isDimmed(.grokBot))
        XCTAssertEqual(vc.rows(for: .grokBot), [["Weekly", "93%", ""]], "a reset that has passed is not shown as coming")
    }

    // MARK: - Claude's sign-in, inside its section

    func testClaudeSignedOutShowsButtonsInsideSection() {
        let vc = controller(state: .signedOut(claudeCodeAvailable: true))
        vc.shownServices = { [.claude, .grokBot] }
        vc.update(services: [.grokBot: grokBot()])
        XCTAssertEqual(vc.sectionServices, [.claude, .grokBot])
        XCTAssertEqual(vc.rows(for: .claude), [])
        XCTAssertEqual(vc.emptyTitle, "Not signed in")
        XCTAssertEqual(vc.emptySubtitle, "Your browser does the signing in")
        XCTAssertEqual(vc.visibleSignInButtons, ["Sign in with your browser", "Use Claude Code's sign-in", "Sign in inside the app"])
        XCTAssertEqual(vc.statusText, "", "no numbers, no age")
        XCTAssertEqual(vc.rows(for: .grokBot).count, 1, "the other services carry on")
    }

    func testSignedOut_withoutClaudeCode_hidesClaudeCodeButton() {
        let vc = controller(state: .signedOut(claudeCodeAvailable: false))
        XCTAssertEqual(vc.visibleSignInButtons, ["Sign in with your browser", "Sign in inside the app"])
    }

    func testSigningIn_showsWaitingAndCancel() {
        let vc = controller(state: .signingIn)
        XCTAssertEqual(vc.visibleSignInButtons, ["Cancel"])
        XCTAssertTrue(vc.emptyTitle.contains("Waiting for your browser"))
        XCTAssertEqual(vc.emptySubtitle, "Approve the sign-in in the tab that opened")
    }

    func testSessionExpired_showsButtonForItsSource() {
        let vc = controller(state: .sessionExpired(.ownToken))
        XCTAssertEqual(vc.emptyTitle, "Session expired")
        XCTAssertEqual(vc.emptySubtitle, "Sign in again to keep tracking usage")
        XCTAssertEqual(vc.visibleSignInButtons, ["Sign in with your browser"])
        vc.render(state: .sessionExpired(.claudeCode))
        XCTAssertEqual(vc.visibleSignInButtons, ["Use Claude Code's sign-in", "Sign in with your browser"])
        vc.render(state: .sessionExpired(.webSession))
        XCTAssertEqual(vc.visibleSignInButtons, ["Sign in inside the app", "Sign in with your browser"])
    }

    func testNoChatOrg_checkingAndOffline_haveTheirCopy() {
        let vc = controller(state: .noChatOrg)
        XCTAssertEqual(vc.emptyTitle, "No Claude plan on this account")
        XCTAssertEqual(vc.emptySubtitle, "This account only has API access")
        XCTAssertEqual(vc.visibleSignInButtons, ["Sign in with your browser"])
        vc.render(state: .unknown)
        XCTAssertEqual(vc.emptyTitle, "Checking sign-in...")
        XCTAssertEqual(vc.emptySubtitle, "One moment")
        XCTAssertEqual(vc.visibleSignInButtons, [])
        vc.render(state: .unreachable)
        XCTAssertEqual(vc.emptyTitle, "Could not reach claude.ai")
        XCTAssertEqual(vc.emptySubtitle, "Check your connection and refresh")
        XCTAssertEqual(vc.visibleSignInButtons, [])
    }

    func testSignInMessage_isShownInTheSection() {
        let vc = MenuViewController()
        _ = vc.view
        vc.signInMessage = "Sign-in timed out, try again"
        vc.render(state: .signedOut(claudeCodeAvailable: false))
        XCTAssertEqual(vc.emptySubtitle, "Sign-in timed out, try again")
    }

    func testSignedIn_hasNoSignInCopyOrButtons() throws {
        let vc = controller(state: .signedOut(claudeCodeAvailable: true))
        vc.render(state: .signedIn(.webSession, nil))
        vc.update(with: try max20x())
        XCTAssertEqual(vc.emptyTitle, "")
        XCTAssertEqual(vc.visibleSignInButtons, [])
        XCTAssertEqual(vc.rows(for: .claude).count, 2)
    }

    /// Numbers count only while signed in: nothing left over from before is shown once the sign-in is gone.
    func testLeavingSignedInTakesTheNumbersAway() throws {
        let vc = controller()
        vc.update(with: try max20x())
        XCTAssertEqual(vc.rows(for: .claude).count, 2)
        vc.render(state: .sessionExpired(.ownToken))
        XCTAssertEqual(vc.rows(for: .claude), [])
        XCTAssertEqual(vc.statusText, "")
    }

    func testIconTooltipNamesTheServiceAndWhoIsSignedIn() {
        let vc = controller(state: .signedIn(.ownToken, Profile(email: "test@example.com", displayName: "Test", organizationName: nil, organizationType: nil)))
        vc.shownServices = { [.claude, .grokBot] }
        vc.update(services: [.grokBot: grokBot()])
        XCTAssertEqual(vc.iconToolTip(for: .claude), "Claude\nSigned in as test@example.com")
        XCTAssertEqual(vc.iconToolTip(for: .grokBot), "Grok Bot")
        vc.render(state: .signedIn(.claudeCode, nil))
        XCTAssertEqual(vc.iconToolTip(for: .claude), "Claude\nvia Claude Code")
        vc.render(state: .signedIn(.webSession, nil))
        XCTAssertEqual(vc.iconToolTip(for: .claude), "Claude")
        vc.render(state: .signedOut(claudeCodeAvailable: false))
        XCTAssertEqual(vc.iconToolTip(for: .claude), "Claude")
    }

    // MARK: - Footer and spinner

    func testStatus_afterUpdate_saysUpdatedJustNow() throws {
        let vc = controller()
        vc.showLoading()
        vc.update(with: try max20x())
        XCTAssertEqual(vc.statusText, "Updated just now")
        XCTAssertFalse(vc.isShowingSpinner)
    }

    func testStatus_whileLoading_saysUpdating_andSpins() {
        let vc = controller()
        vc.showLoading()
        XCTAssertEqual(vc.statusText, "Updating...")
        XCTAssertTrue(vc.isShowingSpinner)
    }

    func testStatus_afterErrorWithData_keepsTheAgeAndTheRows() throws {
        let vc = controller()
        vc.update(with: try max20x())
        clock = clock.addingTimeInterval(12 * 60)
        vc.showLoading()
        vc.showError("Offline or claude.ai unreachable")
        XCTAssertEqual(vc.statusText, "Couldn't refresh: Offline or claude.ai unreachable. Last updated 12 min ago.")
        XCTAssertFalse(vc.isShowingSpinner)
        XCTAssertEqual(vc.rows(for: .claude).count, 2)
    }

    /// A fetch cut short by an expiry or a sign-out never reports back: the spinner must stop anyway.
    func testLeavingSignedIn_stopsTheSpinner() {
        let vc = controller()
        vc.showLoading()
        vc.render(state: .sessionExpired(.claudeCode))
        XCTAssertFalse(vc.isShowingSpinner)
        vc.render(state: .signedIn(.claudeCode, nil))
        vc.showLoading()
        vc.render(state: .signedOut(claudeCodeAvailable: false))
        XCTAssertFalse(vc.isShowingSpinner)
    }

    func testRenderTimes_usesTheCurrentTime() throws {
        let vc = controller()
        vc.update(with: try max20x())
        clock = clock.addingTimeInterval(30 * 60)
        vc.renderTimes()
        XCTAssertEqual(vc.statusText, "Updated 30 min ago")
    }

    /// A reset more than a day away shows its date; once it is under a day away, its time.
    func testRenderTimes_switchesAResetFromDateToTimeUnderADay() throws {
        let vc = controller()
        vc.update(with: try max20x())
        XCTAssertEqual(vc.rows(for: .claude)[1][2], "Oct 16", "the week resets in 3 days 19 hours")
        clock = clock.addingTimeInterval(3 * 24 * 3600)   // now 19 hours away
        vc.renderTimes()
        XCTAssertEqual(plain(vc.rows(for: .claude))[1][2], "4:00 PM")
    }

    func testPopoverWillShow_bringsTimesUpToDate() throws {
        let vc = controller()
        vc.update(with: try max20x())
        clock = clock.addingTimeInterval(5 * 60)
        vc.popoverWillShow()
        XCTAssertEqual(vc.statusText, "Updated 5 min ago")
        vc.popoverDidClose()
    }

    func testStatusLineBelongsToClaudeAndHidesWithIt() throws {
        let vc = controller()
        vc.shownServices = { [.claude, .grokBot] }
        vc.update(with: try max20x())
        vc.update(services: [.grokBot: grokBot()])
        XCTAssertEqual(vc.statusText, "Updated just now")
        vc.shownServices = { [.grokBot] }
        vc.update(services: [.grokBot: grokBot()])
        XCTAssertEqual(vc.statusText, "", "no Claude section, no Claude status")
    }

    // MARK: - More menu

    private func moreMenu(_ vc: MenuViewController) -> [(title: String, state: NSControl.StateValue, enabled: Bool)] {
        vc.makeMoreMenu().items.map { ($0.isSeparatorItem ? "-" : $0.title, $0.state, $0.isEnabled) }
    }

    func testMoreMenuItemsAndChecks() {
        let vc = controller()
        vc.shownServices = { [.claude, .codex] }
        vc.setUpServices = { [.claude, .grokBot, .codex] }
        vc.currentMenuBarChoice = { .service(.codex) }
        vc.isOpenAtLoginEnabled = { true }
        let items = moreMenu(vc)
        XCTAssertEqual(items.map(\.title), [
            "Refresh", "-",
            "Menu Bar Shows", "Lowest Remaining", "Claude", "Codex", "-",
            "Show", "Claude", "Grok Bot", "Codex", "-",
            "Open at Login", "Sign Out of Claude", "Quit",
        ])
        // The two headings are disabled; everything else can be chosen.
        XCTAssertEqual(items.filter { !$0.enabled && $0.title != "-" }.map(\.title), ["Menu Bar Shows", "Show"])
        // Menu Bar Shows: a check on the current choice only.
        XCTAssertEqual(items[3...5].map(\.state), [.off, .off, .on])
        // Show: a check on each shown service.
        XCTAssertEqual(items[8...10].map(\.state), [.on, .off, .on])
        XCTAssertEqual(items[12].state, .on, "Open at Login is on")
    }

    func testMenuBarChoiceDefaultsToLowestAndFallsBackWhenThePinnedServiceIsHidden() {
        let vc = controller()
        vc.shownServices = { [.claude, .grokBot] }
        vc.setUpServices = { [.claude, .grokBot, .codex] }
        vc.currentMenuBarChoice = { .lowest }
        XCTAssertEqual(moreMenu(vc)[3...5].map(\.state), [.on, .off, .off])
        vc.currentMenuBarChoice = { .service(.grokBot) }
        XCTAssertEqual(moreMenu(vc)[3...5].map(\.state), [.off, .off, .on])
        // The menu bar falls back to the lowest when the pinned service is hidden, so the check follows it.
        vc.currentMenuBarChoice = { .service(.codex) }
        XCTAssertEqual(moreMenu(vc)[3...5].map(\.state), [.on, .off, .off])
    }

    func testOpenAtLoginOffAndSignOutOnlyWhenThereIsASignIn() {
        let vc = controller()
        vc.isOpenAtLoginEnabled = { false }
        XCTAssertEqual(moreMenu(vc).last(where: { $0.title == "Open at Login" })?.state, NSControl.StateValue.off)

        func hasSignOut(_ state: AuthState) -> Bool {
            vc.render(state: state)
            return vc.makeMoreMenu().items.contains { $0.title == "Sign Out of Claude" }
        }
        XCTAssertTrue(hasSignOut(.signedIn(.ownToken, nil)))
        XCTAssertTrue(hasSignOut(.sessionExpired(.claudeCode)))
        XCTAssertTrue(hasSignOut(.noChatOrg))
        XCTAssertFalse(hasSignOut(.signedOut(claudeCodeAvailable: true)))
        XCTAssertFalse(hasSignOut(.signingIn))
        XCTAssertFalse(hasSignOut(.unknown))
        XCTAssertFalse(hasSignOut(.unreachable))
        XCTAssertEqual(vc.makeMoreMenu().items.last?.title, "Quit")
    }

    /// An empty panel is a dead end: the last shown service has nothing to hide behind.
    func testLastShownServiceCannotBeHidden() {
        let vc = controller()
        vc.setUpServices = { [.claude, .grokBot] }
        vc.shownServices = { [.claude] }
        var toggled: [ServiceID] = []
        vc.onToggleService = { toggled.append($0) }
        var items = vc.makeMoreMenu().items
        let showClaude = items[items.firstIndex { $0.title == "Show" }! + 1]
        let showGrokBot = items[items.firstIndex { $0.title == "Show" }! + 2]
        XCTAssertEqual(showClaude.title, "Claude")
        XCTAssertFalse(showClaude.isEnabled, "the only shown service cannot be hidden")
        XCTAssertEqual(showClaude.state, .on)
        XCTAssertTrue(showGrokBot.isEnabled, "a hidden one can be shown")

        // Not even by sending the action by hand.
        _ = NSApp.sendAction(showClaude.action!, to: showClaude.target, from: showClaude)
        XCTAssertEqual(toggled, [])

        // With two shown, either can go.
        vc.shownServices = { [.claude, .grokBot] }
        items = vc.makeMoreMenu().items
        let show = items.firstIndex { $0.title == "Show" }!
        XCTAssertEqual(items[show + 1...show + 2].map(\.isEnabled), [true, true])
    }

    func testChoosingMenuBarAndToggleCallBack() {
        let vc = controller()
        vc.setUpServices = { [.claude, .grokBot, .codex] }
        vc.shownServices = { [.claude, .grokBot] }
        var choices: [MenuBarChoice] = []
        var toggled: [ServiceID] = []
        vc.onChooseMenuBar = { choices.append($0) }
        vc.onToggleService = { toggled.append($0) }

        let menu = vc.makeMoreMenu()
        func perform(_ title: String, after heading: String) {
            let start = menu.items.firstIndex { $0.title == heading }!
            let index = menu.items[(start + 1)...].firstIndex { $0.title == title }!
            menu.performActionForItem(at: index)
        }
        perform("Lowest Remaining", after: "Menu Bar Shows")
        perform("Grok Bot", after: "Menu Bar Shows")
        perform("Grok Bot", after: "Show")
        perform("Codex", after: "Show")
        XCTAssertEqual(choices, [.lowest, .service(.grokBot)])
        XCTAssertEqual(toggled, [.grokBot, .codex])
    }

    func testMenuBarListsOnlyShownServices() {
        let vc = controller()
        vc.setUpServices = { [.claude, .grokBot, .codex] }
        vc.shownServices = { [.claude, .grokBot] }
        let titles = moreMenu(vc).map(\.title)
        let heading = titles.firstIndex(of: "Menu Bar Shows")!
        XCTAssertEqual(Array(titles[heading + 1...heading + 3]), ["Lowest Remaining", "Claude", "Grok Bot"])
        XCTAssertEqual(titles[heading + 4], "-")
    }

    func testRefreshOpenAtLoginAndSignOutCallBack() {
        let vc = controller()
        var refreshes = 0, toggles = 0, signOuts = 0
        vc.onRefresh = { refreshes += 1 }
        vc.onToggleOpenAtLogin = { toggles += 1 }
        vc.onSignOut = { signOuts += 1 }
        let menu = vc.makeMoreMenu()
        func index(_ title: String) -> Int { menu.items.firstIndex { $0.title == title }! }
        menu.performActionForItem(at: index("Refresh"))
        menu.performActionForItem(at: index("Open at Login"))
        menu.performActionForItem(at: index("Sign Out of Claude"))
        XCTAssertEqual([refreshes, toggles, signOuts], [1, 1, 1])
    }

    func testQuitQuitsTheApp() {
        let quit = controller().makeMoreMenu().items.last!
        XCTAssertEqual(quit.title, "Quit")
        XCTAssertEqual(quit.action, #selector(NSApplication.terminate(_:)))
        XCTAssertTrue(quit.target === NSApp)
    }

    // MARK: - Size and alignment

    func testPanelIs320WideAndTallerWithMoreRows() throws {
        let vc = controller()
        vc.update(with: try max20x())
        let twoRows = vc.preferredContentSize.height
        vc.update(with: try proLike())
        let fiveRows = vc.preferredContentSize.height
        XCTAssertGreaterThan(twoRows, 0)
        XCTAssertGreaterThan(fiveRows, twoRows)
        XCTAssertEqual(vc.preferredContentSize.width, 320)
        vc.shownServices = { [.claude, .grokBot, .codex] }
        vc.update(services: [.grokBot: grokBot(), .codex: .notSignedIn(hint: codexHint)])
        XCTAssertGreaterThan(vc.preferredContentSize.height, fiveRows, "every section adds height")
        XCTAssertEqual(vc.preferredContentSize.width, 320)
    }

    /// Glanceable means aligned: every section puts its icon, its labels and its two number columns in the same places.
    func testColumnsAlignAcrossSections() throws {
        let vc = controller()
        vc.shownServices = { [.claude, .grokBot, .codex] }
        vc.update(with: try proLike())
        // 100% left, and a reset at 12:00 AM: the widest a row gets.
        let midnight = ISO8601DateFormatter().date(from: "2026-10-13T00:00:00Z")!
        vc.update(services: [.grokBot: grokBot(used: 0),
                             .codex: .reading(limits: [ServiceLimit(label: "5hr Session", percentUsed: 1.0, resetsAt: midnight),
                                                       ServiceLimit(label: "Weekly", percentUsed: 0.4, resetsAt: clock.addingTimeInterval(5 * 24 * 3600))],
                                           readAt: clock)])
        vc.view.layoutSubtreeIfNeeded()

        let edges = ServiceID.allCases.flatMap { vc.rowEdges(for: $0) }
        XCTAssertEqual(edges.count, 8)
        for edge in edges {
            XCTAssertEqual(edge.labelMinX, edges[0].labelMinX, accuracy: 0.01, "labels start together")
            XCTAssertEqual(edge.percentMaxX, edges[0].percentMaxX, accuracy: 0.01, "percents end together")
            XCTAssertEqual(edge.resetMaxX, edges[0].resetMaxX, accuracy: 0.01, "resets end together")
            XCTAssertLessThanOrEqual(edge.labelMaxX, edge.percentMinX, "a label never runs into its number")
            XCTAssertLessThanOrEqual(edge.percentMaxX, edge.resetMinX, "a number never runs into its reset")
            XCTAssertFalse(edge.isCut, "every word fits whole: Weekly (Sonnet), 100%, 12:00 AM")
        }
        XCTAssertEqual(edges[0].resetMaxX, 320 - 14, accuracy: 0.01, "the right margin is 14")

        let icons = ServiceID.allCases.compactMap { vc.iconFrame(for: $0) }
        XCTAssertEqual(icons.count, 3)
        for icon in icons {
            XCTAssertEqual(icon.minX, 14, accuracy: 0.01, "icons sit on the left margin")
            XCTAssertEqual(icon.size, NSSize(width: 28, height: 28))
        }
        XCTAssertLessThan(icons[0].maxX, edges[0].labelMinX)
    }

    /// The dots are a small target, so they get all the room the header has to give.
    func testDotsButtonHasARealClickTarget() {
        let vc = controller()
        vc.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(vc.moreButtonFrame.width, 28)
        XCTAssertGreaterThanOrEqual(vc.moreButtonFrame.height, 22)
    }

    /// A row is one thing to VoiceOver, not three.
    func testEachRowReadsAsOneSentenceToVoiceOver() throws {
        let vc = controller()
        vc.update(with: try max20x())
        XCTAssertEqual(vc.rowVoiceOverTexts(for: .claude).map { $0?.replacingOccurrences(of: "\u{202F}", with: " ") },
                       ["5hr Session, 92% left, Resets Mon Oct 12, 10:00 PM", "Weekly, 27% left, Resets Fri Oct 16, 4:00 PM"])
        vc.update(with: try proLike())
        XCTAssertEqual(vc.rowVoiceOverTexts(for: .claude).last, "Extra usage, 65% left, Monthly budget")
    }

    /// The panel is drawn again only when something it says changes, so a click is never lost to a redraw
    /// that changed nothing.
    func testPanelIsRebuiltOnlyWhenSomethingChanges() throws {
        let vc = controller(state: .signedOut(claudeCodeAvailable: true))
        let section = vc.sectionView(for: .claude)
        XCTAssertNotNil(section)
        vc.renderTimes()
        vc.update(services: [:])
        clock = clock.addingTimeInterval(31 * 60)
        vc.renderTimes()
        XCTAssertTrue(vc.sectionView(for: .claude) === section, "same words, same views")
        vc.render(state: .signingIn)
        XCTAssertFalse(vc.sectionView(for: .claude) === section, "new words, new views")
    }

    /// A long failure message wraps inside the footer instead of pushing the version out of the popover.
    func testLongStatusWrapsAndKeepsTheVersionInView() throws {
        let vc = controller()
        vc.update(with: try max20x())
        clock = clock.addingTimeInterval(12 * 60)
        vc.showError("Offline or claude.ai unreachable, and then some more words to make it long")
        vc.view.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(vc.footerFrames.version.maxX, 320 - 14 + 0.01)
        XCTAssertLessThanOrEqual(vc.footerFrames.status.maxX, vc.footerFrames.version.minX)
        XCTAssertEqual(vc.preferredContentSize.width, 320)
    }
}
