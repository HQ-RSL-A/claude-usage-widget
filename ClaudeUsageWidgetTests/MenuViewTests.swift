import XCTest
@testable import ClaudeUsageWidget

@MainActor
final class MenuViewTests: XCTestCase {

    private func signedInController() -> MenuViewController {
        let vc = MenuViewController()
        _ = vc.view
        vc.render(state: .signedIn(.webSession, nil))
        return vc
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
