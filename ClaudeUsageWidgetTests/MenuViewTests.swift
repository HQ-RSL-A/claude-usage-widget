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

    private func signedInController() -> MenuViewController {
        let vc = MenuViewController()
        vc.makeText = { [unowned self] in self.fixedText() }
        _ = vc.view
        vc.render(state: .signedIn(.webSession, nil))
        return vc
    }

    private func max20x() throws -> UsageData {
        var data = try UsageData.decode(from: Data(Fixtures.usageMax20xJSON.utf8))
        data.lastUpdated = clock
        return data
    }

    // MARK: - Rows say what's left

    func test_update_showsWhatsLeft() throws {
        let vc = signedInController()
        vc.update(with: try max20x())
        XCTAssertEqual(vc.rowPercentTexts, ["92% left", "27% left"])
    }

    func test_update_detailsUsePlainResetText() throws {
        let vc = signedInController()
        vc.update(with: try max20x())
        XCTAssertEqual(vc.rowDetailTexts.map { $0.replacingOccurrences(of: "\u{202F}", with: " ") }, ["Resets in 1 hr", "Resets Fri 4:00 PM"])
    }

    func test_limitReached_detail() {
        let vc = signedInController()
        let full = UsageBucket(kind: .session, percentUsed: 1.0, resetsAt: clock.addingTimeInterval(72 * 60), lockedReason: nil)
        vc.update(with: UsageData(buckets: [full], extraUsage: nil, lastUpdated: clock))
        XCTAssertEqual(vc.rowPercentTexts, ["0% left"])
        XCTAssertEqual(vc.rowDetailTexts, ["Limit reached, resets in 1 hr 12 min"])
    }

    func test_extraUsage_saysWhatsLeftOfTheMonthlyBudget() throws {
        let vc = signedInController()
        var data = try UsageData.decode(from: Data(Fixtures.usageProLikeJSON.utf8))
        data.lastUpdated = clock
        vc.update(with: data)
        XCTAssertEqual(vc.rowPercentTexts.last, "65% left")
        XCTAssertEqual(vc.rowDetailTexts.last, "Monthly budget")
    }

    // MARK: - Status line and spinner

    func test_status_afterUpdate_saysUpdatedJustNow() throws {
        let vc = signedInController()
        vc.showLoading()
        vc.update(with: try max20x())
        XCTAssertEqual(vc.statusText, "Updated just now")
        XCTAssertFalse(vc.isShowingSpinner)
    }

    func test_status_whileLoading_saysUpdating_andSpins() {
        let vc = signedInController()
        vc.showLoading()
        XCTAssertEqual(vc.statusText, "Updating...")
        XCTAssertTrue(vc.isShowingSpinner)
    }

    func test_status_afterErrorWithData_keepsTheAge() throws {
        let vc = signedInController()
        vc.update(with: try max20x())
        clock = clock.addingTimeInterval(12 * 60)
        vc.showLoading()
        vc.showError("Offline or claude.ai unreachable")
        XCTAssertEqual(vc.statusText, "Couldn't refresh: Offline or claude.ai unreachable. Last updated 12 min ago.")
        XCTAssertFalse(vc.isShowingSpinner)
        XCTAssertEqual(vc.usageRowCount, 2)
    }

    /// A fetch cut short by an expiry or a sign-out never reports back: the spinner must stop anyway.
    func test_leavingSignedIn_stopsTheSpinner() {
        let vc = signedInController()
        vc.showLoading()
        vc.render(state: .sessionExpired(.claudeCode))
        XCTAssertFalse(vc.isShowingSpinner)
        vc.render(state: .signedIn(.claudeCode, nil))
        vc.showLoading()
        vc.render(state: .signedOut(claudeCodeAvailable: false))
        XCTAssertFalse(vc.isShowingSpinner)
    }

    func test_renderTimes_usesTheCurrentTime() throws {
        let vc = signedInController()
        vc.update(with: try max20x())
        clock = clock.addingTimeInterval(30 * 60)
        vc.renderTimes()
        XCTAssertEqual(vc.rowDetailTexts.first, "Resets in 30 min")
        XCTAssertEqual(vc.statusText, "Updated 30 min ago")
    }

    func test_popoverWillShow_bringsTimesUpToDate() throws {
        let vc = signedInController()
        vc.update(with: try max20x())
        clock = clock.addingTimeInterval(5 * 60)
        vc.popoverWillShow()
        XCTAssertEqual(vc.statusText, "Updated 5 min ago")
        vc.popoverDidClose()
    }

    // MARK: - Settings menu

    func test_noSegmentedControl() {
        XCTAssertFalse(signedInController().containsSegmentedControl)
    }

    func test_settingsMenu_reflectsLayoutAndLoginItem() {
        let vc = signedInController()
        vc.currentLayout = { .week }
        vc.isOpenAtLoginEnabled = { true }
        let menu = vc.makeSettingsMenu()
        XCTAssertEqual(menu.items.count, 6)
        XCTAssertEqual(menu.items[0].title, "Show in Menu Bar")
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertEqual(menu.items[1...3].map(\.title), ["Session and Week", "Session Only", "Week Only"])
        XCTAssertEqual(menu.items[1...3].map(\.state), [.off, .off, .on])
        XCTAssertTrue(menu.items[4].isSeparatorItem)
        XCTAssertEqual(menu.items[5].title, "Open at Login")
        XCTAssertEqual(menu.items[5].state, .on)
    }

    func test_settingsMenu_choosingALayout_callsBack() {
        let vc = signedInController()
        var chosen: MenuBarLayout?
        vc.onChangeLayout = { chosen = $0 }
        vc.makeSettingsMenu().performActionForItem(at: 2)
        XCTAssertEqual(chosen, .session)
    }

    func test_settingsMenu_openAtLogin_callsBack() {
        let vc = signedInController()
        var toggles = 0
        vc.onToggleOpenAtLogin = { toggles += 1 }
        vc.makeSettingsMenu().performActionForItem(at: 5)
        XCTAssertEqual(toggles, 1)
    }

    func test_update_max20x_showsTwoUsageRows() throws {
        let vc = signedInController()
        vc.update(with: try UsageData.decode(from: Data(Fixtures.usageMax20xJSON.utf8)))
        XCTAssertEqual(vc.usageRowCount, 2)
        XCTAssertEqual(vc.rowCount, 2)
    }

    func test_update_proLike_showsFourBucketsPlusExtraUsage() throws {
        let vc = signedInController()
        vc.update(with: try UsageData.decode(from: Data(Fixtures.usageProLikeJSON.utf8)))
        XCTAssertEqual(vc.usageRowCount, 5)
    }

    func test_update_noBuckets_showsOnePlaceholderAndNoUsageRows() {
        let vc = signedInController()
        vc.update(with: UsageData(buckets: [], extraUsage: nil))
        XCTAssertEqual(vc.rowCount, 1)
        XCTAssertEqual(vc.usageRowCount, 0)
    }

    func test_update_replacesRowsInsteadOfAppending() throws {
        let vc = signedInController()
        vc.update(with: try UsageData.decode(from: Data(Fixtures.usageProLikeJSON.utf8)))
        vc.update(with: try UsageData.decode(from: Data(Fixtures.usageMax20xJSON.utf8)))
        XCTAssertEqual(vc.usageRowCount, 2)
    }

    func test_preferredHeight_growsWithRows() throws {
        let vc = signedInController()
        vc.update(with: try UsageData.decode(from: Data(Fixtures.usageMax20xJSON.utf8)))
        let twoRows = vc.preferredContentSize.height
        vc.update(with: try UsageData.decode(from: Data(Fixtures.usageProLikeJSON.utf8)))
        let fiveRows = vc.preferredContentSize.height
        XCTAssertGreaterThan(twoRows, 0)
        XCTAssertGreaterThan(fiveRows, twoRows)
        XCTAssertEqual(vc.preferredContentSize.width, 300)
    }

    func test_render_signedOut_hidesUsage_signedIn_showsIt() {
        let vc = MenuViewController()
        _ = vc.view
        vc.render(state: .signedOut(claudeCodeAvailable: false))
        XCTAssertFalse(vc.isShowingUsage)
        vc.render(state: .sessionExpired(.webSession))
        XCTAssertFalse(vc.isShowingUsage)
        vc.render(state: .signedIn(.webSession, nil))
        XCTAssertTrue(vc.isShowingUsage)
    }

    func test_signedOut_withClaudeCode_showsAllThreeButtons() {
        let vc = MenuViewController(); _ = vc.view
        vc.render(state: .signedOut(claudeCodeAvailable: true))
        XCTAssertEqual(vc.visibleSignInButtons, ["Sign in with your browser", "Use Claude Code's sign-in", "Sign in inside the app"])
        XCTAssertNil(vc.footerAuthTitle)
        XCTAssertFalse(vc.isShowingUsage)
    }

    func test_signedOut_withoutClaudeCode_hidesClaudeCodeButton() {
        let vc = MenuViewController(); _ = vc.view
        vc.render(state: .signedOut(claudeCodeAvailable: false))
        XCTAssertEqual(vc.visibleSignInButtons, ["Sign in with your browser", "Sign in inside the app"])
    }

    func test_signingIn_showsWaitingAndCancel() {
        let vc = MenuViewController(); _ = vc.view
        vc.render(state: .signingIn)
        XCTAssertEqual(vc.visibleSignInButtons, ["Cancel"])
        XCTAssertTrue(vc.emptyTitle.contains("Waiting for your browser"))
    }

    func test_signedIn_showsEmailSubtitle_andSignOut() {
        let vc = MenuViewController(); _ = vc.view
        vc.render(state: .signedIn(.ownToken, Profile(email: "test@example.com", displayName: "Test", organizationName: nil, organizationType: nil)))
        XCTAssertEqual(vc.subtitleText, "Signed in as test@example.com")
        XCTAssertEqual(vc.footerAuthTitle, "Sign Out")
        XCTAssertTrue(vc.isShowingUsage)
    }

    func test_signedIn_viaClaudeCode_withoutProfile_saysSo() {
        let vc = MenuViewController(); _ = vc.view
        vc.render(state: .signedIn(.claudeCode, nil))
        XCTAssertEqual(vc.subtitleText, "via Claude Code")
    }

    func test_sessionExpired_showsButtonForItsSource() {
        let vc = MenuViewController(); _ = vc.view
        vc.render(state: .sessionExpired(.ownToken))
        XCTAssertEqual(vc.visibleSignInButtons, ["Sign in with your browser"])
        XCTAssertEqual(vc.footerAuthTitle, "Sign Out")
        vc.render(state: .sessionExpired(.claudeCode))
        XCTAssertEqual(vc.visibleSignInButtons, ["Use Claude Code's sign-in", "Sign in with your browser"])
    }

    func test_signInMessage_isShownInEmptyState() {
        let vc = MenuViewController(); _ = vc.view
        vc.signInMessage = "Sign-in timed out, try again"
        vc.render(state: .signedOut(claudeCodeAvailable: false))
        XCTAssertEqual(vc.emptySubtitle, "Sign-in timed out, try again")
    }
}
