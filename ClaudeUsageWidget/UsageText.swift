import Foundation

/// Usage in plain words, for the popover rows, the status line, the menu bar tooltip and VoiceOver.
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
        guard let date = bucket.resetsAt, date > now else { return nil }
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

    func age(of date: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        return "\(Int(seconds / 3600)) hr ago"
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

    /// One line per limit, then how old the numbers are.
    func tooltip(for data: UsageData) -> String {
        var lines = data.buckets.map { bucket in
            let line = "\(bucket.kind.label): \(percentLeft(bucket))"
            return reset(bucket).map { line + ", " + lowercasedFirst($0) } ?? line
        }
        if lines.isEmpty { lines = ["No usage limits reported"] }
        lines.append("Updated \(age(of: data.lastUpdated))")
        return lines.joined(separator: "\n")
    }

    /// What VoiceOver reads for the menu bar item: the same two numbers the rings show.
    func accessibilityValue(for data: UsageData) -> String {
        let parts = [
            data.sessionBucket.map { "session \(percentLeft($0))" },
            data.weekBucket.map { "week \(percentLeft($0))" },
        ].compactMap { $0 }
        guard !parts.isEmpty else { return "No usage limits reported" }
        return uppercasedFirst(parts.joined(separator: ", "))
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

    private func lowercasedFirst(_ text: String) -> String { text.prefix(1).lowercased() + text.dropFirst() }
    private func uppercasedFirst(_ text: String) -> String { text.prefix(1).uppercased() + text.dropFirst() }
}
