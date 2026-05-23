import AppKit
import Foundation

/// Left-edge recency stripe for file-tree rows.
///
/// The sidebar paints a thin (≈3 px) vertical color stripe on the
/// leading edge of each `FileRowView`, indicating how recently the
/// file's chosen time attribute was touched. The stripe's tier and
/// color are derived purely from an age (`TimeInterval` seconds);
/// this type is intentionally Foundation/AppKit-only so the tests
/// can exercise it without spinning up SwiftUI.
///
/// Three time attributes are user-selectable via a dropdown in the
/// FILES section header (persisted in `@AppStorage`):
///   • `.modified` — `attr[.modificationDate]` (default)
///   • `.added`    — currently aliases to modificationDate. True
///                   "date added" needs HFS+/APFS metadata which
///                   isn't exposed via FileManager attributes; the
///                   FILES sort menu's "Added" entry uses the same
///                   proxy so the dropdown behaves consistently.
///   • `.created`  — `attr[.creationDate]`
public enum FileTreeRecency {

    // MARK: - Mode

    /// Which timestamp drives the stripe color for each row.
    /// `AppStorage` persists the raw `String`.
    public enum RecencyMode: String, CaseIterable, Identifiable, Sendable {
        case modified = "Modified"
        case added    = "Added"
        case created  = "Created"
        public var id: String { rawValue }

        /// Default — matches the long-standing `FolderSortMode.modifiedDescending`
        /// convention of "recency == mtime" in the rest of the app.
        public static let `default`: RecencyMode = .modified
    }

    // MARK: - Tier

    /// Discrete recency buckets. Keeping the public surface small (5
    /// cases instead of an open-ended age->color map) makes the
    /// color contract easy to test and easy for designers to retheme.
    public enum RecencyTier: String, CaseIterable, Sendable {
        case today     // < 1 day
        case week      // 1d ..< 7d
        case month     // 7d ..< 30d
        case quarter   // 30d ..< 90d
        case older     // >= 90d (no stripe / barely visible)
    }

    // MARK: - Tier boundaries
    //
    // Seconds, not days — explicit so the call sites can't accidentally
    // pass minutes. Boundaries are inclusive-lower / exclusive-upper:
    // exactly 86400s lands in `.week`, not `.today`.
    public static let dayInSeconds:     TimeInterval = 60 * 60 * 24
    public static let weekInSeconds:    TimeInterval = dayInSeconds * 7
    public static let monthInSeconds:   TimeInterval = dayInSeconds * 30
    public static let quarterInSeconds: TimeInterval = dayInSeconds * 90

    /// Map an age (seconds since "now") to a tier.
    ///
    /// Negative ages (file timestamp in the future — clock skew, or a
    /// build process that backdates) clamp to `.today` rather than
    /// returning `.older`; future-dated files are clearly "fresh".
    public static func tier(forAge ageSeconds: TimeInterval) -> RecencyTier {
        if ageSeconds < dayInSeconds     { return .today }
        if ageSeconds < weekInSeconds    { return .week }
        if ageSeconds < monthInSeconds   { return .month }
        if ageSeconds < quarterInSeconds { return .quarter }
        return .older
    }

    /// Convenience overload: derive the tier from a timestamp + `now`.
    /// Pass `Date()` as `now` at call sites; tests inject a fixed date.
    public static func tier(for date: Date, now: Date = Date()) -> RecencyTier {
        tier(forAge: now.timeIntervalSince(date))
    }

    // MARK: - Color

    /// Stripe color for a tier. Dark/light variants are supplied via
    /// `NSColor(name:dynamicProvider:)` so the AppKit appearance
    /// switch is automatic.
    ///
    /// Color contract:
    ///   • Never returns `.clear` or zero-alpha — even `.older` is a
    ///     barely-visible grey. Callers can decide to skip drawing
    ///     for `.older` if they want a true no-stripe look, but the
    ///     color itself is always usable.
    ///   • The four "active" tiers are a monotone blue ramp
    ///     (darkest = freshest), so they read as a heatmap.
    public static func color(for tier: RecencyTier) -> NSColor {
        NSColor(name: "FileTreeRecency.\(tier.rawValue)") { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            switch tier {
            case .today:
                // Dark blue — clearly visible in both modes.
                return isDark
                    ? NSColor(calibratedRed: 0.40, green: 0.62, blue: 1.00, alpha: 0.95)
                    : NSColor(calibratedRed: 0.10, green: 0.36, blue: 0.85, alpha: 0.95)
            case .week:
                return isDark
                    ? NSColor(calibratedRed: 0.40, green: 0.62, blue: 1.00, alpha: 0.70)
                    : NSColor(calibratedRed: 0.18, green: 0.46, blue: 0.90, alpha: 0.70)
            case .month:
                return isDark
                    ? NSColor(calibratedRed: 0.40, green: 0.62, blue: 1.00, alpha: 0.45)
                    : NSColor(calibratedRed: 0.28, green: 0.56, blue: 0.95, alpha: 0.45)
            case .quarter:
                return isDark
                    ? NSColor(calibratedRed: 0.40, green: 0.62, blue: 1.00, alpha: 0.25)
                    : NSColor(calibratedRed: 0.38, green: 0.66, blue: 1.00, alpha: 0.25)
            case .older:
                // Barely-visible grey. Non-zero alpha so the contract
                // "always returns a usable color" holds; the SwiftUI
                // layer is free to elide drawing for `.older`.
                return isDark
                    ? NSColor(calibratedWhite: 0.55, alpha: 0.08)
                    : NSColor(calibratedWhite: 0.45, alpha: 0.08)
            }
        }
    }
}

// MARK: - Per-row attribute cache
//
// `FileManager.attributesOfItem(atPath:)` is a syscall — firing one
// per row per body re-eval would tank scrolling perf in any
// non-trivial tree. We cache the three timestamps per URL behind a
// bounded LRU (mirroring `BookmarksSection.dirCache`). Entries are
// invalidated externally when the FolderWatcher fires; otherwise the
// values are stable for the row's life.
//
// The cache is `nonisolated(unsafe)` + `NSLock` so it can be reached
// from the SwiftUI body (`@MainActor`) without `await` ceremony. The
// critical section is a single dictionary read/write — contention is
// negligible.

public struct FileTreeRecencyAttributes: Sendable {
    public let modifiedAt: Date?
    public let createdAt:  Date?

    public init(modifiedAt: Date?, createdAt: Date?) {
        self.modifiedAt = modifiedAt
        self.createdAt  = createdAt
    }

    /// Pick the timestamp that drives the stripe color for a given
    /// mode. `.added` aliases to `modifiedAt` (see RecencyMode docs).
    public func date(for mode: FileTreeRecency.RecencyMode) -> Date? {
        switch mode {
        case .modified, .added: return modifiedAt
        case .created:          return createdAt
        }
    }
}

public enum FileTreeRecencyCache {

    nonisolated(unsafe) private static var cache: [URL: FileTreeRecencyAttributes] = [:]
    private static let lock = NSLock()
    /// Soft cap — when exceeded we drop the whole map. Same strategy
    /// as `BookmarksSection.dirCache`; an LRU with per-key recency
    /// would be overkill for this hit pattern.
    private static let capacity = 2048

    /// Fast read with stat-on-miss. Safe to call from the main actor.
    public static func attributes(for url: URL) -> FileTreeRecencyAttributes {
        lock.lock()
        if let hit = cache[url] {
            lock.unlock()
            return hit
        }
        if cache.count > capacity {
            cache.removeAll(keepingCapacity: true)
        }
        lock.unlock()

        // Stat outside the lock — `attributesOfItem` is the slow part.
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let value = FileTreeRecencyAttributes(
            modifiedAt: attrs[.modificationDate] as? Date,
            createdAt:  attrs[.creationDate]     as? Date
        )

        lock.lock()
        cache[url] = value
        lock.unlock()
        return value
    }

    /// Drop a single URL — call on FolderWatcher fire for that path.
    public static func invalidate(_ url: URL) {
        lock.lock()
        cache.removeValue(forKey: url)
        lock.unlock()
    }

    /// Nuke the whole map — call on workspace switch or large-scale
    /// FS event storms where per-URL invalidation would be slower
    /// than a clean slate.
    public static func invalidateAll() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}
