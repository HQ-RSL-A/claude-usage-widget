import XCTest
@testable import ClaudeUsageWidget

final class UsageTextTests: XCTestCase {

    private let now = ISO8601DateFormatter().date(from: "2026-10-26T23:11:00Z")!

    /// Fixed clock, UTC, US English: every string below is exact.
    private var text: UsageText {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return UsageText(now: now, calendar: calendar, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func bucket(_ kind: BucketKind = .session, _ used: Double = 0.5, resetsIn seconds: TimeInterval?) -> UsageBucket {
        UsageBucket(kind: kind, percentUsed: used, resetsAt: seconds.map { now.addingTimeInterval($0) }, lockedReason: nil)
    }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    // MARK: - Reset

    func test_reset_underAnHour_showsMinutes() {
        XCTAssertEqual(text.reset(bucket(resetsIn: 42 * 60)), "Resets in 42 min")
    }

    func test_reset_roundsToTheNearestMinute_neverZero() {
        XCTAssertEqual(text.reset(bucket(resetsIn: 20)), "Resets in 1 min")
        XCTAssertEqual(text.reset(bucket(resetsIn: 3 * 3600 + 9 * 60 + 30)), "Resets in 3 hr 10 min")
        XCTAssertEqual(text.reset(bucket(resetsIn: 3600 + 20)), "Resets in 1 hr")
    }

    func test_reset_underADay_countsDown_forWeeklyToo() {
        let weekly = UsageBucket(kind: .weeklyAll, percentUsed: 0.74, resetsAt: date("2026-10-27T03:00:00Z"), lockedReason: nil)
        XCTAssertEqual(text.reset(weekly), "Resets in 3 hr 49 min")
    }

    func test_reset_aDayOrMore_showsDayAndTime() {
        let weekly = UsageBucket(kind: .weeklyAll, percentUsed: 0.2, resetsAt: date("2026-10-29T16:00:00Z"), lockedReason: nil)
        // The system formatter puts a narrow no-break space (U+202F) before "PM"; either space reads the same.
        XCTAssertEqual(text.reset(weekly)?.replacingOccurrences(of: "\u{202F}", with: " "), "Resets Thu 4:00 PM")
    }

    func test_reset_pastOrMissing_isNil() {
        XCTAssertNil(text.reset(bucket(resetsIn: -60)))
        XCTAssertNil(text.reset(bucket(resetsIn: nil)))
    }

    // MARK: - Row text

    func test_detail_limitReached() {
        XCTAssertEqual(text.detail(bucket(.session, 1.0, resetsIn: 72 * 60)), "Limit reached, resets in 1 hr 12 min")
        XCTAssertEqual(text.detail(bucket(.session, 1.0, resetsIn: nil)), "Limit reached")
        XCTAssertEqual(text.detail(bucket(.session, 0.5, resetsIn: nil)), "")
        XCTAssertEqual(text.detail(bucket(.session, 0.5, resetsIn: 42 * 60)), "Resets in 42 min")
    }

    func test_percentLeft() {
        XCTAssertEqual(text.percentLeft(bucket(.session, 0.12, resetsIn: nil)), "88% left")
    }

    // MARK: - Age and status line

    func test_age() {
        XCTAssertEqual(text.age(of: now.addingTimeInterval(-20)), "just now")
        XCTAssertEqual(text.age(of: now.addingTimeInterval(-3 * 60)), "3 min ago")
        XCTAssertEqual(text.age(of: now.addingTimeInterval(-125 * 60)), "2 hr ago")
        XCTAssertEqual(text.age(of: now.addingTimeInterval(30)), "just now")
    }

    func test_status_variants() {
        let twelveMinutesAgo = now.addingTimeInterval(-12 * 60)
        let offline = "Offline or claude.ai unreachable"
        XCTAssertEqual(text.status(lastUpdated: twelveMinutesAgo, isFetching: true, failure: offline), "Updating...")
        XCTAssertEqual(text.status(lastUpdated: twelveMinutesAgo, isFetching: false, failure: offline),
                       "Couldn't refresh: Offline or claude.ai unreachable. Last updated 12 min ago.")
        XCTAssertEqual(text.status(lastUpdated: nil, isFetching: false, failure: offline), "Couldn't refresh: Offline or claude.ai unreachable")
        XCTAssertEqual(text.status(lastUpdated: now.addingTimeInterval(-5), isFetching: false, failure: nil), "Updated just now")
        XCTAssertEqual(text.status(lastUpdated: nil, isFetching: false, failure: nil), "")
    }

    // MARK: - Menu bar tooltip and VoiceOver

    func test_tooltip_listsEachLimitThenAge() {
        let data = UsageData(buckets: [
            bucket(.session, 0.12, resetsIn: 3 * 3600 + 10 * 60),
            UsageBucket(kind: .weeklyAll, percentUsed: 0.74, resetsAt: date("2026-10-27T03:00:00Z"), lockedReason: nil),
        ], extraUsage: nil, lastUpdated: now.addingTimeInterval(-2 * 60))
        XCTAssertEqual(text.tooltip(for: data),
                       "Current session: 88% left, resets in 3 hr 10 min\nWeekly (all models): 26% left, resets in 3 hr 49 min\nUpdated 2 min ago")
    }

    func test_tooltip_noBuckets() {
        let data = UsageData(buckets: [], extraUsage: nil, lastUpdated: now)
        XCTAssertEqual(text.tooltip(for: data), "No usage limits reported\nUpdated just now")
    }

    func test_accessibilityValue() {
        let both = UsageData(buckets: [bucket(.session, 0.12, resetsIn: nil), bucket(.weeklyAll, 0.74, resetsIn: nil)], extraUsage: nil)
        XCTAssertEqual(text.accessibilityValue(for: both), "Session 88% left, week 26% left")
        let sessionOnly = UsageData(buckets: [bucket(.session, 0.12, resetsIn: nil)], extraUsage: nil)
        XCTAssertEqual(text.accessibilityValue(for: sessionOnly), "Session 88% left")
        XCTAssertEqual(text.accessibilityValue(for: UsageData(buckets: [], extraUsage: nil)), "No usage limits reported")
    }
}
