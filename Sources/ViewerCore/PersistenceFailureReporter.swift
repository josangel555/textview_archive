import Foundation

/// Rate-limits persistence-failure reports (`JSONFileStore.onWriteFailure`).
///
/// The dominant real cause is a FULL DISK, which fails every subsequent write
/// — history, bookmarks, sessions, review stores, all of them, repeatedly. One
/// user-facing report per failure would be a toast storm that buries the very
/// message it is trying to deliver. This coalesces: the FIRST failure reports
/// immediately (the user should know the moment saving starts failing), then
/// further failures accumulate silently until `window` has passed, at which
/// point the next failure reports again with everything since folded into a
/// count.
///
/// Pure bookkeeping over an injected clock — host-tested. Thread-safe: the
/// hook fires from the write queue, `flushSync` (main), or any store's thread.
public final class PersistenceFailureReporter: @unchecked Sendable {

    public struct Report: Equatable, Sendable {
        /// File that failed (the trigger for this report).
        public let url: URL
        /// Total failures folded into this report (≥ 1).
        public let count: Int

        /// One-line user-facing message.
        public var message: String {
            let name = url.lastPathComponent
            return count <= 1
                ? "Couldn't save \(name) — changes may be lost. Check free disk space."
                : "Couldn't save \(name) and \(count - 1) other change(s) — check free disk space."
        }
    }

    private let lock = NSLock()
    private let window: TimeInterval
    private var suppressedCount = 0
    private var lastReportAt: Date?

    public init(window: TimeInterval = 60) {
        self.window = window
    }

    /// Record one failure. Returns a `Report` when this failure should be
    /// surfaced to the user, nil when it was coalesced into the current window.
    public func record(url: URL, at now: Date = Date()) -> Report? {
        lock.lock()
        defer { lock.unlock() }
        suppressedCount += 1
        if let last = lastReportAt, now.timeIntervalSince(last) < window {
            return nil                                  // inside the window — coalesce
        }
        let report = Report(url: url, count: suppressedCount)
        suppressedCount = 0
        lastReportAt = now
        return report
    }
}
