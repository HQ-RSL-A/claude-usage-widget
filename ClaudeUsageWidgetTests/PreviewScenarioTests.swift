import XCTest
@testable import ClaudeUsageWidget

final class PreviewScenarioTests: XCTestCase {

    private let now = ISO8601DateFormatter().date(from: "2026-10-26T23:11:00Z")!

    func test_previewScenario_parsesLaunchArgument() {
        let name = "io.rsla.ClaudeUsageWidget.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        XCTAssertNil(PreviewScenario.fromLaunchArguments(defaults))
        defaults.set("amber", forKey: "previewUsage")
        XCTAssertEqual(PreviewScenario.fromLaunchArguments(defaults), .amber)
        defaults.set("sideways", forKey: "previewUsage")
        XCTAssertNil(PreviewScenario.fromLaunchArguments(defaults))
    }

    func test_previewScenarios_coverTheStates() {
        XCTAssertEqual(PreviewScenario.fresh.data(now: now)?.sessionBucket?.percentLeft, 100)
        XCTAssertEqual(PreviewScenario.normal.data(now: now)?.weekBucket?.barColorState, .normal)
        XCTAssertEqual(PreviewScenario.amber.data(now: now)?.weekBucket?.barColorState, .amber)
        XCTAssertEqual(PreviewScenario.critical.data(now: now)?.weekBucket?.barColorState, .critical)
        XCTAssertEqual(PreviewScenario.limit.data(now: now)?.sessionBucket?.percentLeft, 0)
        XCTAssertEqual(PreviewScenario.stale.data(now: now).map { now.timeIntervalSince($0.lastUpdated) }, 20 * 60)
        XCTAssertNil(PreviewScenario.signedOut.data(now: now))
        XCTAssertEqual(PreviewScenario.signedOut.state, .signedOut(claudeCodeAvailable: true))
        for scenario in PreviewScenario.allCases where scenario != .signedOut {
            guard case .signedIn = scenario.state else { return XCTFail("\(scenario) should be signed in") }
            XCTAssertNotNil(scenario.data(now: now), "\(scenario)")
        }
    }
}
