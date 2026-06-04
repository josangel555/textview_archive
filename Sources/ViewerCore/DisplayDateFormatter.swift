import Foundation

/// Single source of truth for user-visible file Created/Modified (and
/// comparable) date displays. Renders `yyyy-MM-dd HH:mm` — 24-hour clock,
/// zero-padded, e.g. `2026-06-03 14:07`.
///
/// Locale is pinned to `en_US_POSIX` so the literal pattern is never
/// reinterpreted by the user's locale (no `MM/dd/yyyy` vs `dd.MM.yyyy`
/// drift, no AM/PM). Time zone is the current zone so a "Modified" stamp
/// reads in the user's wall-clock time.
///
/// Reuse this everywhere a file's created/modified timestamp is shown.
/// Do NOT scatter ad-hoc `DateFormatter`s. Log / diagnostic timestamps
/// that intentionally carry seconds are a separate concern and keep their
/// own formatters.
public enum DisplayDateFormatter {
    /// `nonisolated(unsafe)`: `DateFormatter.string(from:)` is read-only on
    /// an immutable instance and documented thread-safe; the formatter is
    /// configured once at init and never mutated afterwards.
    nonisolated(unsafe) public static let fileDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// `2026-06-03 14:07` for the given date in the current time zone.
    public static func string(from date: Date) -> String {
        fileDate.string(from: date)
    }
}

public extension Date {
    /// User-visible file created/modified rendering: `yyyy-MM-dd HH:mm`
    /// (24h). See ``DisplayDateFormatter``.
    var fileDisplayString: String {
        DisplayDateFormatter.string(from: self)
    }
}
