import Foundation

/// The reset times in the panel's rows: a short one in the row, the full one in its tooltip.
extension UsageText {

    /// What a row's last column says: the time when the reset is under a day away ("2:10 PM"), the date beyond
    /// that ("Nov 10"), and nothing when there is no reset ahead.
    func shortReset(_ date: Date?) -> String {
        guard let date, date > now else { return "" }
        let isWithinADay = date.timeIntervalSince(now) < 24 * 3600
        return panelFormat(date, template: isWithinADay ? "jmm" : "MMMd")
    }

    /// The whole answer, for a row's tooltip: "Resets Tue Nov 10, 1:21 PM". Nil when there is no reset ahead.
    func fullReset(_ date: Date?) -> String? {
        guard let date, date > now else { return nil }
        return "Resets \(panelFormat(date, template: "EEE")) \(panelFormat(date, template: "MMMd")), \(panelFormat(date, template: "jmm"))"
    }

    /// Each piece is spelled the way the reader's locale spells it, in the calendar's own time zone.
    private func panelFormat(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
