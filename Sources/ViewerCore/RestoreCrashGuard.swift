import Foundation

/// Breaks the "crash on launch, forever" loop (audit THEME 2).
///
/// Session restore is unconditional at startup: the app reopens whatever was
/// open last time. If ONE of those documents crashes the app while it is being
/// restored, the next launch restores the same set and crashes again — the app
/// becomes permanently unstartable with no way out from the UI. That is the
/// worst failure mode in the product: the user cannot even reach a menu to
/// undo it.
///
/// The mechanism is the standard clean-shutdown flag. Before restoring we drop
/// a marker recording that an attempt is in flight; when restore returns we
/// delete it. A marker still present at the next launch therefore means the
/// previous attempt never finished — the app died inside restore. After
/// `threshold` consecutive unfinished attempts, restore is SKIPPED once so the
/// user gets a working app back, and the marker is cleared so the following
/// launch tries again (a transient crash must not disable restore forever).
///
/// A FILE, not `UserDefaults`: the whole point is surviving an abort, and
/// defaults writes are buffered. The marker is written atomically and its
/// content is just the attempt count.
public struct RestoreCrashGuard: Sendable {

    public enum Decision: Equatable, Sendable {
        /// Safe to restore; the caller must call `markSucceeded()` afterwards.
        case restore
        /// The previous `failures` attempts died mid-restore — skip this once.
        case skipRestore(failures: Int)
    }

    /// Consecutive unfinished attempts tolerated before skipping. 2 rather than
    /// 1 so a single unrelated crash (or a force-quit during a slow restore,
    /// which is indistinguishable from a crash) doesn't cost the user their
    /// session.
    public static let defaultThreshold = 2

    public let markerURL: URL
    public let threshold: Int

    public init(markerURL: URL, threshold: Int = RestoreCrashGuard.defaultThreshold) {
        self.markerURL = markerURL
        self.threshold = max(1, threshold)
    }

    /// Marker beside the Sessions store, so the `MDV_SESSIONS_DIR` /
    /// `MDV_APP_SUPPORT` overrides that keep test launches hermetic apply here
    /// too — a scripted launch must not inherit (or write) the user's counter.
    public static func defaultMarkerURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        SessionStore.defaultDirectory(environment: environment)
            .deletingLastPathComponent()
            .appendingPathComponent("restore-in-flight")
    }

    /// Number of attempts recorded as unfinished. 0 when the last shutdown was
    /// clean.
    public var pendingAttempts: Int {
        guard let raw = try? String(contentsOf: markerURL, encoding: .utf8),
              let n = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 0 }
        return max(0, n)
    }

    /// Call BEFORE restoring. Records the attempt and says whether to proceed.
    public func beginAttempt() -> Decision {
        let pending = pendingAttempts
        if pending >= threshold {
            // Give the user a working app, and clear the count so the NEXT
            // launch restores normally — otherwise one bad day disables
            // restore permanently.
            clear()
            return .skipRestore(failures: pending)
        }
        write(pending + 1)
        return .restore
    }

    /// Call once restore has returned. Clears the in-flight marker.
    public func markSucceeded() {
        clear()
    }

    public func clear() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    private func write(_ count: Int) {
        let dir = markerURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Atomic so a crash mid-write can't leave a torn marker that parses as
        // a different count.
        try? Data("\(count)".utf8).write(to: markerURL, options: .atomic)
    }
}
