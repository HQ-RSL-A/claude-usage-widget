import XCTest
@testable import ClaudeUsageWidget

/// The reset times the panel's rows show: a short one in the row, the full one in its tooltip.
final class UsageTextPanelTests: XCTestCase {

    private let now = ISO8601DateFormatter().date(from: "2026-11-04T12:00:00Z")!

    private func text(zone: String = "UTC", locale: String = "en_US_POSIX") -> UsageText {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return UsageText(now: now, calendar: calendar, locale: Locale(identifier: locale))
    }

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// The system formatter puts a narrow no-break space (U+202F) before "PM"; either space reads the same.
    private func plain(_ text: String?) -> String? { text?.replacingOccurrences(of: "\u{202F}", with: " ") }

    // MARK: - Short reset

    func testShortResetTimeWithinADayDateBeyond() {
        XCTAssertEqual(plain(text().shortReset(date("2026-11-04T14:10:00Z"))), "2:10 PM")
        XCTAssertEqual(text().shortReset(date("2026-11-10T21:21:00Z")), "Nov 10")
        XCTAssertEqual(text().shortReset(nil), "")
    }

    func testShortResetSwitchesToTheDateAtADay() {
        XCTAssertEqual(plain(text().shortReset(now.addingTimeInterval(24 * 3600 - 60))), "11:59 AM", "a minute short of a day is still a time")
        XCTAssertEqual(text().shortReset(now.addingTimeInterval(24 * 3600)), "Nov 5", "a day away is a date")
    }

    /// A reset that already happened is not "next": there is nothing to say until the numbers catch up.
    func testShortResetIsEmptyOnceItHasPassed() {
        XCTAssertEqual(text().shortReset(now.addingTimeInterval(-60)), "")
        XCTAssertEqual(text().shortReset(now), "")
        XCTAssertEqual(text().shortReset(now.addingTimeInterval(-3 * 24 * 3600)), "")
    }

    func testShortResetFollowsTheCalendarsTimeZoneAndLocale() {
        XCTAssertEqual(plain(text(zone: "America/Los_Angeles").shortReset(date("2026-11-04T22:10:00Z"))), "2:10 PM")
        XCTAssertEqual(text(zone: "America/Los_Angeles").shortReset(date("2026-11-10T07:30:00Z")), "Nov 9", "a date is the date where the reader is")
        XCTAssertEqual(text(locale: "en_GB").shortReset(date("2026-11-04T14:10:00Z")), "14:10")
        XCTAssertEqual(text(locale: "en_GB").shortReset(date("2026-11-10T21:21:00Z")), "10 Nov")
    }

    // MARK: - Full reset

    func testFullResetNamesTheDayTheDateAndTheTime() {
        XCTAssertEqual(plain(text().fullReset(date("2026-11-10T21:21:00Z"))), "Resets Tue Nov 10, 9:21 PM")
        XCTAssertEqual(plain(text().fullReset(date("2026-11-04T14:10:00Z"))), "Resets Wed Nov 4, 2:10 PM", "also when it is today")
        XCTAssertEqual(plain(text(zone: "America/Los_Angeles").fullReset(date("2026-11-10T21:21:00Z"))), "Resets Tue Nov 10, 1:21 PM")
    }

    func testFullResetIsNilWithoutAResetAhead() {
        XCTAssertNil(text().fullReset(nil))
        XCTAssertNil(text().fullReset(now.addingTimeInterval(-60)))
    }
}
