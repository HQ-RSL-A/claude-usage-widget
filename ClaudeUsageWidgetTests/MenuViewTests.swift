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
}
