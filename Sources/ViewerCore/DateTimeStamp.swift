import Foundation

/// Pure formatter for the "Insert Date & Time" editor command (TSK-299,
/// Notepad's F5). Kept dependency-free and date-injected so it's fully
/// unit-testable with a fixed clock/locale/timezone — the live command
/// passes `Date()` + the current locale.
public enum DateTimeStamp {

    /// Locale-aware medium date + short time, e.g. en_US → "Jun 7, 2026
    /// at 2:34 PM". Matches the system's default `DateFormatter` joining
    /// so the inserted stamp reads naturally in the user's locale.
    public static func string(
        for date: Date,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
