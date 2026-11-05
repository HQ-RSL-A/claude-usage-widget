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

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    // MARK: - Reset

    func test_reset_underAnHour_showsMinutes() {
        XCTAssertEqual(text.reset(now.addingTimeInterval(42 * 60)), "Resets in 42 min")
    }

    func test_reset_roundsToTheNearestMinute_neverZero() {
        XCTAssertEqual(text.reset(now.addingTimeInterval(20)), "Resets in 1 min")
        XCTAssertEqual(text.reset(now.addingTimeInterval(3 * 3600 + 9 * 60 + 30)), "Resets in 3 hr 10 min")
        XCTAssertEqual(text.reset(now.addingTimeInterval(3600 + 20)), "Resets in 1 hr")
    }

    func test_reset_underADay_countsDown() {
        XCTAssertEqual(text.reset(date("2026-10-27T03:00:00Z")), "Resets in 3 hr 49 min")
    }

    func test_reset_aDayOrMore_showsDayAndTime() {
        // The system formatter puts a narrow no-break space (U+202F) before "PM"; either space reads the same.
        XCTAssertEqual(text.reset(date("2026-10-29T16:00:00Z"))?.replacingOccurrences(of: "\u{202F}", with: " "), "Resets Thu 4:00 PM")
    }

    func test_reset_pastOrMissing_isNil() {
        XCTAssertNil(text.reset(now.addingTimeInterval(-60)))
        XCTAssertNil(text.reset(now), "a reset at this very moment is not ahead")
        XCTAssertNil(text.reset(nil))
    }

    // MARK: - Age and status line

    func test_age() {
        XCTAssertEqual(text.age(of: now.addingTimeInterval(-20)), "just now")
        XCTAssertEqual(text.age(of: now.addingTimeInterval(-3 * 60)), "3 min ago")
        XCTAssertEqual(text.age(of: now.addingTimeInterval(-125 * 60)), "2 hr ago")
        XCTAssertEqual(text.age(of: now.addingTimeInterval(30)), "just now")
    }

    /// Grok Bot's reading is often days old, and "72 hr ago" makes a person do the sum.
    func test_age_aDayOrMoreCountsInDays() {
        let hour: TimeInterval = 3600
        XCTAssertEqual(text.age(of: now.addingTimeInterval(-23 * hour - 59 * 60)), "23 hr ago", "still under a day")
        XCTAssertEqual(text.age(of: now.addingTimeInterval(-24 * hour)), "1 day ago", "a day is a day, not 24 hr")
        XCTAssertEqual(text.age(of: now.addingTimeInterval(-47 * hour)), "1 day ago", "whole days only")
        XCTAssertEqual(text.age(of: now.addingTimeInterval(-48 * hour)), "2 days ago")
        XCTAssertEqual(text.age(of: now.addingTimeInterval(-72 * hour)), "3 days ago")
        XCTAssertEqual(text.age(of: now.addingTimeInterval(-10 * 24 * hour)), "10 days ago")
    }

    func test_status_aDayOldReadingSaysDays() {
        XCTAssertEqual(text.status(lastUpdated: now.addingTimeInterval(-2 * 24 * 3600), isFetching: false, failure: nil), "Updated 2 days ago")
        XCTAssertEqual(text.status(lastUpdated: now.addingTimeInterval(-24 * 3600), isFetching: false, failure: "Offline"),
                       "Couldn't refresh: Offline. Last updated 1 day ago.")
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

    // MARK: - Menu bar title

    func test_percentRemain() {
        XCTAssertEqual(text.percentRemain(40), "40% remain")
        XCTAssertEqual(text.percentRemain(100), "100% remain")
        XCTAssertEqual(text.percentRemain(0), "0% remain")
    }
}
