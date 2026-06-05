import XCTest
import Foundation
@testable import ViewerUI

/// Regression coverage for the two audited `PTYProcess` lifecycle defects
/// (see `AUDIT_BUGS.md`, location `Sources/ViewerUI/Terminal/PTYProcess.swift`):
///
///   • [S2/leak] `terminate()` / `handleEOF()` never reset `childPID` to its
///     `-1` sentinel, so the `start()` guard (`childPID <= 0`) short-circuits
///     and `forkpty` never re-runs — the "Restart shell" path silently
///     no-ops, leaving a dead pane. Fixed by resetting `childPID = -1` under
///     the lock in both teardown paths. Asserted here by `restart()` actually
///     producing a fresh, live shell that responds to input.
///
///   • [S3/leak] `terminate()` reaped with a single `WNOHANG` immediately
///     after SIGHUP, which reliably misses (delivery + exit are async),
///     leaking a zombie per teardown. Fixed with a bounded poll →
///     SIGKILL → blocking-waitpid ladder run OFF the main thread (on the
///     read queue). The owner-observable property asserted here is that
///     `terminate()` returns promptly (does not block the caller for the
///     full reap budget) — the reap correctness itself runs on the read
///     queue and is exercised by every teardown in these tests.
///
/// This spawns a REAL login shell via `forkpty(3)`, but that is a pure
/// fork/exec path — NO window, NO GUI session, NO TCC permission — so it is
/// host-safe and stays at the headless floor (`HeadlessUITestCase`). It is
/// the one place the live spawn path *is* exercisable without opening a UI.
@MainActor
final class Audit_Sources_ViewerUI_Terminal_PTYProcess_swift_LifecycleTests: HeadlessUITestCase {

    /// Spin until `predicate()` holds or `timeout` elapses. Returns whether
    /// it held. Polls without blocking the main run loop hard.
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return predicate()
    }

    /// Collect output bytes from a PTY until `marker` is seen or it times
    /// out. `onOutput` fires on a background queue, so the accumulator is
    /// guarded by a lock.
    private final class OutputSink: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
        func contains(_ marker: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: buffer, as: UTF8.self).contains(marker)
        }
    }

    /// Lock-guarded bool box: `onExit` fires on a background queue, so a bare
    /// captured `var` would be a Swift 6 concurrent-mutation error.
    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    // MARK: - S2: restart() must respawn a live shell

    func test_restart_respawnsLiveShell_afterTerminate() throws {
        let pty = PTYProcess()
        let sink = OutputSink()
        pty.onOutput = { [sink] data in sink.append(data) }

        XCTAssertTrue(pty.start(rows: 24, cols: 80), "initial start must spawn")
        XCTAssertTrue(waitUntil { pty.isRunning }, "shell should be running after start")

        // Tear the first shell down (the "Restart shell" path: terminate
        // then start on the SAME instance).
        pty.terminate()
        XCTAssertFalse(pty.isRunning, "terminate must mark the pty not-running")

        // Pre-fix, childPID stayed > 0 so this start() short-circuited and
        // forkpty never re-ran; isRunning would stay false.
        XCTAssertTrue(pty.start(rows: 24, cols: 80), "restart start() must return true")
        XCTAssertTrue(
            waitUntil { pty.isRunning },
            "restart must actually re-spawn a live shell (childPID reset to sentinel)"
        )

        // Prove the respawned shell is genuinely interactive: echo a unique
        // token and confirm it comes back over the master fd.
        let token = "MDV_RESPAWN_\(UUID().uuidString.prefix(8))"
        pty.writeString("echo \(token)\n")
        XCTAssertTrue(
            waitUntil(timeout: 3.0) { sink.contains(token) },
            "respawned shell must respond to input (proves a NEW forkpty)"
        )

        pty.terminate()
    }

    // MARK: - S2: restart() after the shell self-exits (handleEOF path)

    func test_start_afterSelfExit_respawns() throws {
        let pty = PTYProcess()
        let didExit = LockedFlag()
        pty.onExit = { _ in didExit.set() }

        XCTAssertTrue(pty.start(rows: 24, cols: 80))
        XCTAssertTrue(waitUntil { pty.isRunning })

        // Ask the shell to exit itself -> EOF on master -> handleEOF().
        pty.writeString("exit\n")
        XCTAssertTrue(
            waitUntil(timeout: 3.0) { didExit.value },
            "self-exit should drive handleEOF/onExit"
        )
        XCTAssertTrue(waitUntil { !pty.isRunning }, "pty should be not-running after self-exit")

        // handleEOF must also have reset childPID so a fresh start respawns.
        XCTAssertTrue(pty.start(rows: 24, cols: 80), "start after self-exit must respawn")
        XCTAssertTrue(
            waitUntil { pty.isRunning },
            "forkpty must re-run after a self-exit (childPID reset in handleEOF)"
        )

        pty.terminate()
    }

    // MARK: - S3: teardown does not block the calling (main) thread

    func test_terminate_doesNotBlockMainThread() throws {
        // The S3 fix moves the bounded reap ladder (poll up to ~200ms, then a
        // possible SIGKILL + blocking waitpid) OFF the main thread onto the
        // read queue. So `terminate()` itself — reached from the main actor
        // (restart button, applicationWillTerminate) — must return promptly,
        // not stall for the full reap budget. A well-behaved shell that has
        // already been SIGHUP'd is collected on the read queue asynchronously.
        let pty = PTYProcess()
        XCTAssertTrue(pty.start(rows: 24, cols: 80))
        XCTAssertTrue(waitUntil { pty.isRunning })

        let start = Date()
        pty.terminate()
        let elapsed = Date().timeIntervalSince(start)

        // Generous ceiling: the synchronous part is just signal + fd close +
        // an async dispatch — well under the ~200ms reap budget. If the reap
        // ran inline on this thread it could approach/exceed that.
        XCTAssertLessThan(
            elapsed, 0.15,
            "terminate() must dispatch the bounded reap off-thread, not block the caller"
        )
        XCTAssertFalse(pty.isRunning)
    }

    // MARK: - Idempotence: repeated terminate is safe

    func test_terminate_isIdempotent() throws {
        let pty = PTYProcess()
        XCTAssertTrue(pty.start(rows: 24, cols: 80))
        XCTAssertTrue(waitUntil { pty.isRunning })
        pty.terminate()
        // A second (and third) terminate must be a clean no-op — must not
        // block, double-close the fd, or double-reap.
        pty.terminate()
        pty.terminate()
        XCTAssertFalse(pty.isRunning)
    }
}
