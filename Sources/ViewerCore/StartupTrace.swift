import Foundation
import os

/// Owner 2026-08-16 ("why is the app taking way too long to start up?") —
/// permanent, always-on startup milestones in the UNIFIED LOG, so a slow
/// launch on the REAL machine/data is diagnosable after the fact:
///
///   log show --last 30m --info --predicate \
///     'subsystem == "com.markdownviewer.MarkdownViewer" && category == "startup"'
///
/// Design: os.Logger `.info` lines (persisted by default config) + an
/// os_signpost interval per milestone for Instruments. Each `mark` logs the
/// delta since process start and since the previous mark — the timeline
/// reads directly off `log show`, no math. Cost: a handful of log calls at
/// launch — nil in steady state. Finder launches have no stderr, and the
/// app's print()s go nowhere; the unified log is the ONLY after-the-fact
/// channel (LESSONS 2026-08-16: log show came back EMPTY for a launch
/// because the app logged nothing).
public enum StartupTrace {
    private static let log = Logger(
        subsystem: "com.markdownviewer.MarkdownViewer", category: "startup")
    private static let signposter = OSSignposter(
        subsystem: "com.markdownviewer.MarkdownViewer", category: "startup")

    /// Process start (approximated by static-init time of this type — the
    /// first `mark` call touches it, which happens at the top of module
    /// scope, within ms of exec for our launch path).
    private static let t0 = ContinuousClock.now
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last = t0
    nonisolated(unsafe) private static var state: OSSignpostIntervalState?

    /// The bulletproof channel: a tiny append-only trace file. The
    /// unified log DROPPED the first version's `.info` lines (info is
    /// memory-buffer-only unless a logging profile persists it — the
    /// owner's launch left NOTHING readable), so the file is the record
    /// of truth; `.notice` (persisted by default) is the convenience view.
    /// Truncated on each launch — it holds ONE launch's timeline.
    private static let traceFile: URL = {
        // TestStateRedirect so host tests never write the dev's real
        // ~/Library state (the drift guard caught the bypass — CI 7e68dcfc).
        let d = TestStateRedirect.markdownViewerDir()
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("startup-trace.log")
    }()
    nonisolated(unsafe) private static var fileHandle: FileHandle? = nil

    /// Record a milestone. Thread-safe; callable from any context.
    public static func mark(_ label: StaticString) {
        let now = ContinuousClock.now
        lock.lock()
        let sincePrev = last.duration(to: now)
        last = now
        if let s = state { signposter.endInterval("startup", s) }
        state = signposter.beginInterval("startup")
        let line = "\(Date()) \(label) +\(ms(sincePrev))ms (t=\(ms(t0.duration(to: now)))ms)\n"
        if fileHandle == nil {
            FileManager.default.createFile(atPath: traceFile.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: traceFile)
        }
        fileHandle?.write(Data(line.utf8))
        lock.unlock()
        let total = t0.duration(to: now)
        log.notice("\(label, privacy: .public) +\(Self.ms(sincePrev), privacy: .public)ms (t=\(Self.ms(total), privacy: .public)ms)")
    }

    private static func ms(_ d: Duration) -> Int64 {
        d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000
    }
}
