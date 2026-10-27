import XCTest
@testable import ClaudeUsageWidget

final class StatusPresentationTests: XCTestCase {

    private let now = ISO8601DateFormatter().date(from: "2026-10-12T21:00:00Z")!
    private let signedIn = AuthState.signedIn(.claudeCode, nil)

    private var text: UsageText {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return UsageText(now: now, calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func fixture(_ json: String, updatedMinutesAgo minutes: Double = 1) throws -> UsageData {
        var data = try UsageData.decode(from: Data(json.utf8))
        data.lastUpdated = now.addingTimeInterval(-minutes * 60)
        return data
    }

    private func make(_ state: AuthState, _ data: UsageData?, _ layout: MenuBarLayout = .both) -> StatusPresentation {
        StatusPresentation.make(state: state, data: data, layout: layout, text: text)
    }

    // MARK: - Signed in

    func test_both_showsSessionThenWeek() throws {
        let presentation = make(signedIn, try fixture(Fixtures.usageMax20xJSON))
        XCTAssertEqual(presentation.icon.rings, [.usage(left: 92, used: 0.08, color: .normal), .usage(left: 27, used: 0.73, color: .amber)])
        XCTAssertFalse(presentation.icon.isDimmed)
        XCTAssertFalse(presentation.icon.isTemplate)
    }

    func test_singleLayouts_showOneRing() throws {
        let data = try fixture(Fixtures.usageMax20xJSON)
        XCTAssertEqual(make(signedIn, data, .session).icon.rings, [.usage(left: 92, used: 0.08, color: .normal)])
        XCTAssertEqual(make(signedIn, data, .week).icon.rings, [.usage(left: 27, used: 0.73, color: .amber)])
    }

    func test_missingSession_keepsItsSlotAsADash() throws {
        let presentation = make(signedIn, try fixture(Fixtures.usageNoSessionJSON))
        XCTAssertEqual(presentation.icon.rings, [.noData, .usage(left: 80, used: 0.2, color: .normal)])
        XCTAssertFalse(presentation.icon.isDimmed)
    }

    func test_noBuckets_showsDimmedDashes() {
        let empty = UsageData(buckets: [], extraUsage: nil, lastUpdated: now)
        XCTAssertEqual(make(signedIn, empty).icon, StatusIconModel(rings: [.noData, .noData], isDimmed: true))
        XCTAssertEqual(make(signedIn, empty, .week).icon.rings, [.noData])
    }

    func test_staleData_isDimmed() throws {
        XCTAssertTrue(make(signedIn, try fixture(Fixtures.usageMax20xJSON, updatedMinutesAgo: 16)).icon.isDimmed)
        XCTAssertFalse(make(signedIn, try fixture(Fixtures.usageMax20xJSON, updatedMinutesAgo: 14)).icon.isDimmed)
    }

    func test_signedIn_tooltipAndValueComeFromUsageText() throws {
        let data = try fixture(Fixtures.usageMax20xJSON)
        let presentation = make(signedIn, data)
        XCTAssertEqual(presentation.toolTip, text.tooltip(for: data))
        XCTAssertEqual(presentation.accessibilityValue, text.accessibilityValue(for: data))
    }

    func test_signedInWithoutData_saysUpdating() {
        let presentation = make(signedIn, nil)
        XCTAssertEqual(presentation.icon, StatusIconModel(rings: [.noData, .noData], isDimmed: true))
        XCTAssertEqual(presentation.toolTip, "Claude Usage: updating")
        XCTAssertEqual(presentation.accessibilityValue, "Updating")
    }

    // MARK: - Not signed in

    func test_signedOut_showsDimmedDashes() throws {
        let presentation = make(.signedOut(claudeCodeAvailable: true), nil)
        XCTAssertEqual(presentation.icon, StatusIconModel(rings: [.noData, .noData], isDimmed: true))
        XCTAssertEqual(presentation.toolTip, "Claude Usage: not signed in")
        XCTAssertEqual(presentation.accessibilityValue, "Not signed in")
        XCTAssertEqual(make(.signedOut(claudeCodeAvailable: false), nil, .session).icon.rings, [.noData])
        // Numbers left over from before the sign-out are never shown.
        XCTAssertEqual(make(.signedOut(claudeCodeAvailable: false), try fixture(Fixtures.usageMax20xJSON)).icon.rings, [.noData, .noData])
    }

    func test_otherStates_sayWhatIsGoingOn() {
        let cases: [(AuthState, String)] = [
            (.unknown, "checking sign-in"),
            (.unreachable, "can't reach claude.ai"),
            (.signingIn, "waiting for your browser"),
            (.sessionExpired(.ownToken), "session expired"),
            (.noChatOrg, "no Claude plan on this account"),
        ]
        for (state, phrase) in cases {
            let presentation = make(state, nil)
            XCTAssertEqual(presentation.toolTip, "Claude Usage: \(phrase)")
            XCTAssertEqual(presentation.icon, StatusIconModel(rings: [.noData, .noData], isDimmed: true))
        }
    }
}
