import XCTest
@testable import ClaudeUsageWidget

final class PreviewScenarioTests: XCTestCase {

    private let now = ISO8601DateFormatter().date(from: "2026-10-26T23:11:00Z")!
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 24 * 3600

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

    // MARK: - Grok Bot and Codex

    /// The limits and read time of one made-up service. Fails the test when that service is not a reading.
    private func reading(_ id: ServiceID, in scenario: PreviewScenario,
                         file: StaticString = #filePath, line: UInt = #line) -> (limits: [ServiceLimit], readAt: Date)? {
        guard case .reading(let limits, let readAt)? = scenario.services(now: now)[id] else {
            XCTFail("\(scenario) should show \(id) as a reading", file: file, line: line)
            return nil
        }
        return (limits, readAt)
    }

    func testPreviewScenariosIncludeGrokBot() {
        for scenario in PreviewScenario.allCases {
            // Claude stays on `state` and `data(now:)`.
            XCTAssertEqual(Set(scenario.services(now: now).keys), [.grokBot, .codex], "\(scenario)")
            XCTAssertEqual(reading(.grokBot, in: scenario)?.limits.map(\.label), ["Weekly"], "\(scenario)")
        }
        XCTAssertEqual(reading(.grokBot, in: .amber)?.limits.first?.percentUsed, 0.65)
    }

    func testStaleGrokBotReadingIsOld() throws {
        let readAt = try XCTUnwrap(reading(.grokBot, in: .stale)?.readAt)
        XCTAssertEqual(now.timeIntervalSince(readAt), 26 * hour)
        // Old enough that the panel has to call it stale, never current.
        XCTAssertGreaterThan(now.timeIntervalSince(readAt), ServiceID.grokBot.staleAfter)
        // Every other reading was just taken.
        for scenario in PreviewScenario.allCases {
            for id in [ServiceID.grokBot, .codex] where !(scenario == .stale && id == .grokBot) {
                if case .reading(_, let readAt)? = scenario.services(now: now)[id] {
                    XCTAssertEqual(readAt, now, "\(scenario) \(id)")
                }
            }
        }
    }

    func testSetUpServices() {
        for scenario in PreviewScenario.allCases where scenario != .signedOut {
            XCTAssertEqual(scenario.setUpServices, [.claude, .grokBot, .codex], "\(scenario)")
        }
        XCTAssertEqual(PreviewScenario.signedOut.setUpServices, [.claude, .grokBot])
    }

    func testPreviewGrokBotAndCodexNumbers() {
        typealias Row = (used: Double, resetsIn: TimeInterval)
        // Grok Bot's one weekly limit, then Codex's 5hr session and weekly. Codex has no reading in `stale`
        // and `signedOut` (checked below). Codex resets that a scenario doesn't set are 2 hr and 5 days.
        let table: [(PreviewScenario, grokBot: Row, codex: [Row]?)] = [
            (.fresh, (0.05, 6 * day), [(0.0, 2 * hour), (0.10, 5 * day)]),
            (.normal, (0.07, 6 * day), [(0.20, 2 * hour), (0.35, 5 * day)]),
            (.amber, (0.65, 2 * day), [(0.30, 2 * hour), (0.50, 5 * day)]),
            (.critical, (0.90, 1 * day), [(0.88, 40 * 60), (0.70, 3 * day)]),
            (.limit, (1.0, 20 * hour), [(0.20, 2 * hour), (0.35, 5 * day)]),
            (.stale, (0.07, 6 * day), nil),
            (.signedOut, (0.07, 6 * day), nil),
        ]
        XCTAssertEqual(table.map { $0.0 }, PreviewScenario.allCases, "every scenario has a row, in order")

        func limit(_ label: String, _ row: Row) -> ServiceLimit {
            ServiceLimit(label: label, percentUsed: row.used, resetsAt: now.addingTimeInterval(row.resetsIn))
        }
        for (scenario, grokBot, codex) in table {
            XCTAssertEqual(reading(.grokBot, in: scenario)?.limits, [limit("Weekly", grokBot)], "\(scenario) Grok Bot")
            if let codex {
                XCTAssertEqual(reading(.codex, in: scenario)?.limits,
                               [limit("5hr Session", codex[0]), limit("Weekly", codex[1])], "\(scenario) Codex")
            }
        }
        XCTAssertEqual(PreviewScenario.stale.services(now: now)[.codex], .unavailable(reason: "Couldn't reach Codex"))
        XCTAssertEqual(PreviewScenario.signedOut.services(now: now)[.codex],
                       .notSignedIn(hint: "Open Codex and sign in with ChatGPT"))
    }
}
