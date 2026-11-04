import Foundation

/// Usage in plain words, for the popover rows, the status line, the menu bar title and the menu bar tooltip and VoiceOver.
/// The clock, calendar and locale come in from outside, so every string can be tested exactly.
struct UsageText {
    var now: Date
    var calendar: Calendar
    var locale: Locale

    init(now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) {
        self.now = now
        self.calendar = calendar
        self.locale = locale
    }

    // MARK: - Rows

    /// "Resets in 3 hr 10 min" when the reset is under a day away, "Resets Thu 4:00 PM" further out,
    /// nil when there is no reset ahead.
    func reset(_ bucket: UsageBucket) -> String? {
        reset(bucket.resetsAt)
    }

    /// The same words for a reset time that does not come from a bucket (Grok Bot, Codex, the menu bar).
    func reset(_ date: Date?) -> String? {
        guard let date, date > now else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds < 24 * 3600 else { return "Resets " + dayAndTime(date) }
        let minutes = max(1, Int((seconds / 60).rounded()))   // never "0 min" while a reset is still ahead
        let (hours, rest) = (minutes / 60, minutes % 60)
        if hours == 0 { return "Resets in \(rest) min" }
        if rest == 0 { return "Resets in \(hours) hr" }
        return "Resets in \(hours) hr \(rest) min"
    }

    /// The line under a row's bar.
    func detail(_ bucket: UsageBucket) -> String {
        let reset = reset(bucket)
        guard bucket.isAtLimit else { return reset ?? "" }
        return reset.map { "Limit reached, " + lowercasedFirst($0) } ?? "Limit reached"
    }

    func percentLeft(_ bucket: UsageBucket) -> String {
        "\(bucket.percentLeft)% left"
    }

    // MARK: - Status line

    /// How long ago, in the biggest unit that fits: "3 min ago", "2 hr ago", "3 days ago". A reading from Grok Bot is
    /// often days old, and "72 hr ago" makes a person do the sum.
    func age(of date: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 24 * 3600 { return "\(Int(seconds / 3600)) hr ago" }
        let days = Int(seconds / (24 * 3600))
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }

    func status(lastUpdated: Date?, isFetching: Bool, failure: String?) -> String {
        if isFetching { return "Updating..." }
        if let failure {
            guard let lastUpdated else { return "Couldn't refresh: \(failure)" }
            return "Couldn't refresh: \(failure). Last updated \(age(of: lastUpdated))."
        }
        return lastUpdated.map { "Updated \(age(of: $0))" } ?? ""
    }

    // MARK: - Menu bar

    /// The menu bar title: "40% remain". The number is what is left, like every other number in the app.
    func percentRemain(_ left: Int) -> String {
        "\(left)% remain"
    }

    // MARK: - Helpers

    private func dayAndTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
        return formatter.string(from: date)
    }

    /// "Resets in 3 hr" as the end of a sentence: "..., resets in 3 hr".
    func lowercasedFirst(_ text: String) -> String { text.prefix(1).lowercased() + text.dropFirst() }
}
