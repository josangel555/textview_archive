import XCTest
@testable import ViewerCore

/// Pure-logic coverage for the shared subprocess-drain helper (decision
/// H, 2026-05-25). Exercises the contract callers rely on:
///
///   1. stdout + stderr are drained concurrently (no pipe-buffer
///      deadlock when stderr is chatty);
///   2. `stdin` bytes round-trip through the child;
///   3. the `timeout` watchdog fires SIGTERM and the result reports
///      `timedOut == true`;
///   4. `processFailedToStart` is thrown for an unrunnable executable.
///
/// All four use system tools (`/bin/cat`, `/bin/sh`, `/usr/bin/yes`,
/// `/usr/bin/false`) that are guaranteed present on macOS 15 hosts.
final class ProcessRunnerTests: XCTestCase {

    // MARK: stdin round-trip

    func test_run_capturesStdoutAndZeroExit() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/echo")
        p.arguments = ["hello", "world"]
        let r = try ProcessRunner.run(p)
        XCTAssertEqual(r.terminationStatus, 0)
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(String(data: r.stdout, encoding: .utf8), "hello world\n")
        XCTAssertEqual(r.stderr.count, 0)
    }

    func test_run_pipesStdinThroughToChild() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/cat")
        let payload = "payload-\(UUID().uuidString)"
        let r = try ProcessRunner.run(p, stdin: Data(payload.utf8))
        XCTAssertEqual(r.terminationStatus, 0)
        XCTAssertEqual(String(data: r.stdout, encoding: .utf8), payload)
    }

    // MARK: stderr drain (would deadlock without concurrent drain)

    func test_run_drainsStderrConcurrentlyWithStdout() throws {
        // 80 KB to stderr is just over the 64 KB pipe-buffer cap that
        // bit early callers. If we read stderr only after waitUntilExit
        // returns, the child blocks on write(2) and we deadlock.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [
            "-c",
            // ~80 KB of "x" to stderr; nothing to stdout.
            "yes x | head -c 81920 1>&2",
        ]
        let r = try ProcessRunner.run(p)
        XCTAssertEqual(r.terminationStatus, 0)
        XCTAssertGreaterThanOrEqual(r.stderr.count, 80_000)
    }

    // MARK: timeout watchdog

    func test_run_timeoutTerminatesChild() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        let start = Date()
        let r = try ProcessRunner.run(p, timeout: 0.5)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(r.timedOut, "expected watchdog to fire SIGTERM")
        XCTAssertLessThan(elapsed, 5.0,
                          "timeout watchdog should land well under sleep duration")
        XCTAssertNotEqual(r.terminationStatus, 0)
    }

    func test_run_doesNotTimeOutWhenChildExitsQuickly() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let r = try ProcessRunner.run(p, timeout: 10)
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(r.terminationStatus, 0)
    }

    // MARK: spawn failure surface

    func test_run_throwsProcessFailedToStartForBogusBinary() {
        let p = Process()
        p.executableURL = URL(
            fileURLWithPath: "/nonexistent/path/to/binary-\(UUID().uuidString)"
        )
        do {
            _ = try ProcessRunner.run(p)
            XCTFail("expected ProcessRunner.Error.processFailedToStart")
        } catch ProcessRunner.Error.processFailedToStart {
            // Expected.
        } catch {
            XCTFail("expected processFailedToStart, got: \(error)")
        }
    }

    // MARK: non-zero exit doesn't throw — caller decides

    func test_run_nonZeroExitReturnsResultDoesNotThrow() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/false")
        let r = try ProcessRunner.run(p)
        XCTAssertNotEqual(r.terminationStatus, 0)
        XCTAssertFalse(r.timedOut)
    }
}
