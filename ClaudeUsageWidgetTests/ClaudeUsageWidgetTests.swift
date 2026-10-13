import XCTest
@testable import ClaudeUsageWidget

final class ClaudeUsageWidgetTests: XCTestCase {
    func test_bundleShortVersion_isMarketingVersion() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        XCTAssertEqual(version, "0.4.1")
    }
}
