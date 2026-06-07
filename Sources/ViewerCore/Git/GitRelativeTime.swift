import Foundation

/// Compact "x ago" formatting for a unix timestamp, shared by the Git
/// panel's Log and Stash tabs (previously duplicated, and the Stash copy
/// had a bug: it collapsed every 1–7-day age to the literal "yesterday").
/// Pure logic — `now` is injectable so it's deterministic in tests.
public enum GitRelativeTime {
    public static func format(unix: Int, now: Date = Date()) -> String {
        let then = Date(timeIntervalSince1970: TimeInterval(unix))
        let diff = now.timeIntervalSince(then)
        switch diff {
        case ..<60:        return "just now"
        case ..<3600:      return "\(Int(diff / 60)) min ago"
        case ..<86_400:    return "\(Int(diff / 3600)) h ago"
        case ..<604_800:   return "\(Int(diff / 86_400)) d ago"
        default:           return "\(Int(diff / 604_800)) wk ago"
        }
    }
}
