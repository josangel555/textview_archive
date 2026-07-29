import Foundation
import Testing
import ViewerCore

/// A document that crashes the app during session restore used to make the app
/// permanently unstartable: restore is unconditional, so every launch reopened
/// it and died again, with no route to a menu to undo it.
@Suite("RestoreCrashGuard — the crash-on-launch loop breaker")
struct RestoreCrashGuardTests {

    private func makeGuard(threshold: Int = 2) -> (RestoreCrashGuard, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreGuard-\(UUID().uuidString)")
        let url = dir.appendingPathComponent("restore-in-flight")
        return (RestoreCrashGuard(markerURL: url, threshold: threshold), dir)
    }

    @Test("a clean run restores and leaves no marker behind")
    func cleanRun() throws {
        let (g, dir) = makeGuard()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(g.beginAttempt() == .restore)
        #expect(g.pendingAttempts == 1, "an attempt is in flight")
        g.markSucceeded()
        #expect(g.pendingAttempts == 0, "a completed restore clears the marker")

        // The next launch is unaffected.
        #expect(g.beginAttempt() == .restore)
    }

    /// One crash is forgiven — a force-quit during a slow restore looks
    /// identical to a crash, and it must not cost the user their session.
    @Test("a single unfinished attempt still restores")
    func singleCrashIsForgiven() throws {
        let (g, dir) = makeGuard()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = g.beginAttempt()          // launch 1: dies here, no markSucceeded
        #expect(g.beginAttempt() == .restore, "one crash must not disable restore")
    }

    @Test("consecutive unfinished attempts break the loop")
    func loopIsBroken() throws {
        let (g, dir) = makeGuard()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = g.beginAttempt()          // launch 1: crash
        _ = g.beginAttempt()          // launch 2: crash
        #expect(g.beginAttempt() == .skipRestore(failures: 2),
                "the third launch must come up WITHOUT restoring")
    }

    /// Skipping must be a one-off: the launch after a skip restores again, or a
    /// single bad day would disable restore permanently.
    @Test("restore resumes on the launch after a skip")
    func skipIsOneShot() throws {
        let (g, dir) = makeGuard()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = g.beginAttempt()
        _ = g.beginAttempt()
        #expect(g.beginAttempt() == .skipRestore(failures: 2))
        #expect(g.pendingAttempts == 0, "the skip resets the count")
        #expect(g.beginAttempt() == .restore, "the next launch tries again")
    }

    @Test("a threshold of 1 breaks the loop immediately")
    func tightThreshold() throws {
        let (g, dir) = makeGuard(threshold: 1)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = g.beginAttempt()
        #expect(g.beginAttempt() == .skipRestore(failures: 1))
    }

    /// The guard is worthless unwired — pin that launch actually consults it,
    /// and that a scripted/test launch gets its own marker via the sessions-dir
    /// override rather than inheriting the user's counter.
    @Test("launch consults the guard, and the marker honours the dir overrides")
    func wiredAtLaunch() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let main = try String(
            contentsOf: root.appendingPathComponent("Sources/MarkdownViewer/main.swift"),
            encoding: .utf8)
        #expect(main.contains("RestoreCrashGuard"),
                "restore must run behind the crash-loop breaker")
        #expect(main.contains("markSucceeded"),
                "a completed restore must clear the marker, or every launch counts as a crash")

        let scoped = RestoreCrashGuard.defaultMarkerURL(
            environment: ["MDV_SESSIONS_DIR": "/tmp/scratch-sessions"])
        #expect(scoped.path.hasPrefix("/tmp"),
                "a scripted launch must not share the user's marker")
    }

    @Test("a corrupt or missing marker reads as zero, never crashes")
    func corruptMarker() throws {
        let (g, dir) = makeGuard()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not a number".utf8).write(to: g.markerURL)

        #expect(g.pendingAttempts == 0)
        #expect(g.beginAttempt() == .restore)
    }
}
