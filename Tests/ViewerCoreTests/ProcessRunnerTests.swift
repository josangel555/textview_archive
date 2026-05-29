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

    // MARK: Resource limits (S, 2026-05-29)

    /// An empty `ResourceLimits` (all-nil) must NOT change behavior —
    /// the wrapper is bypassed and the child runs as if `limits` were
    /// never passed. Guards against accidentally regressing every
    /// existing call-site if someone hands in `ResourceLimits()` by
    /// reflex.
    func test_run_emptyLimitsBypassesWrapper() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/echo")
        p.arguments = ["hi"]
        let r = try ProcessRunner.run(
            p,
            limits: ProcessRunner.ResourceLimits()
        )
        XCTAssertEqual(r.terminationStatus, 0)
        XCTAssertEqual(String(data: r.stdout, encoding: .utf8), "hi\n")
        // Sanity: with no-limits, the spawned binary should be the
        // one the caller asked for, not `/bin/sh`. We can't observe
        // the pid argv from here, but we *can* observe that no
        // shell-quoting nonsense leaked into stdout.
        XCTAssertEqual(r.stderr.count, 0)
    }

    /// CPU cap actually kills a CPU-bound child. We spin a tight
    /// busy loop in `/bin/sh` and assert the kernel sends SIGXCPU
    /// (default action: terminate) within a few wall-clock seconds.
    /// Without the cap, the loop would burn until the wall-clock
    /// timeout — which is also asserted on as a backstop so a broken
    /// implementation doesn't hang the test suite.
    func test_run_cpuLimitKillsRunawayChild() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Spin without yielding. `while :;` is the cheapest POSIX
        // busy loop; ":" is the shell no-op builtin.
        p.arguments = ["-c", "while :; do :; done"]
        let limits = ProcessRunner.ResourceLimits(cpuSeconds: 1)
        let start = Date()
        // Generous wall-clock backstop: if rlimit doesn't fire, the
        // watchdog must still bail us out before the test bot times
        // out.
        let r = try ProcessRunner.run(p, timeout: 10, limits: limits)
        let elapsed = Date().timeIntervalSince(start)
        // The CPU cap should land well before the wall-clock backstop.
        // 1s of CPU on a busy loop ≈ 1s of wall time on an idle host,
        // ≈ 2-3s on a loaded CI host. 8s gives plenty of slack.
        XCTAssertLessThan(elapsed, 8.0,
                          "CPU cap should kill the busy loop in ~1-2s, " +
                          "watchdog backstop is 10s — got \(elapsed)s")
        // The watchdog should NOT have fired: rlimit kills first.
        XCTAssertFalse(r.timedOut,
                       "RLIMIT_CPU should fire before the 10s watchdog")
        // SIGXCPU = 24, default action terminate. Exit code is then
        // 128 + 24 = 152 (when killed by a signal, Process surfaces
        // 128 + signal). Some shells/runtimes may report -SIGXCPU or
        // a different shape; we accept any non-zero exit as proof
        // the cap landed.
        XCTAssertNotEqual(r.terminationStatus, 0,
                          "expected non-zero exit from SIGXCPU")
    }

    /// CPU cap must NOT regress a quick honest child. A trivial
    /// `/usr/bin/true` under a low CPU cap should still exit 0
    /// cleanly — proves the wrapper isn't injecting noise or
    /// reordering signals.
    func test_run_cpuLimitDoesNotRegressFastChild() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        let limits = ProcessRunner.ResourceLimits(cpuSeconds: 5)
        let r = try ProcessRunner.run(p, limits: limits)
        XCTAssertEqual(r.terminationStatus, 0)
        XCTAssertFalse(r.timedOut)
    }

    /// `currentDirectoryURL` set on the original `Process` must
    /// survive the shell wrapper — the target binary should see the
    /// caller's cwd, not `/`. We confirm by running `/bin/pwd` under
    /// limits with cwd pointed at the test temp dir.
    func test_run_cwdPropagatesThroughLimitsWrapper() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProcessRunnerTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/pwd")
        p.currentDirectoryURL = tmp
        let limits = ProcessRunner.ResourceLimits(cpuSeconds: 5)
        let r = try ProcessRunner.run(p, limits: limits)
        XCTAssertEqual(r.terminationStatus, 0)
        let stdout = String(data: r.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // macOS realpath always resolves /var -> /private/var; the
        // shell wrapper drops $PWD across `sh -c` + `exec`, so the
        // child's getcwd returns the kernel's resolved path, not the
        // string Swift handed `currentDirectoryURL`. Resolve both
        // sides via realpath(3) for a stable compare regardless of
        // which form the child reports.
        let expected = URL(fileURLWithPath: tmp.path)
            .resolvingSymlinksInPath().path
        let stdoutResolved = URL(fileURLWithPath: stdout)
            .resolvingSymlinksInPath().path
        XCTAssertEqual(
            stdoutResolved, expected,
            "pwd inside limits wrapper should equal cwd; got '\(stdout)' " +
            "expected '\(expected)'"
        )
    }

    /// `environment` set on the original `Process` must survive the
    /// shell wrapper — the target sees the caller's env vars
    /// (inherited across `exec` from the shell).
    func test_run_environmentPropagatesThroughLimitsWrapper() throws {
        let token = "MDV_TEST_\(UUID().uuidString.prefix(8))"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf %s \"$MDV_PROBE\""]
        p.environment = ["MDV_PROBE": token, "PATH": "/usr/bin:/bin"]
        let limits = ProcessRunner.ResourceLimits(cpuSeconds: 5)
        let r = try ProcessRunner.run(p, limits: limits)
        XCTAssertEqual(r.terminationStatus, 0)
        XCTAssertEqual(String(data: r.stdout, encoding: .utf8), token)
    }

    /// stdin must still round-trip through the wrapper. Reuses the
    /// existing cat-echo idiom under a CPU cap.
    func test_run_stdinRoundTripsThroughLimitsWrapper() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/cat")
        let payload = "wrapped-\(UUID().uuidString)"
        let limits = ProcessRunner.ResourceLimits(cpuSeconds: 5)
        let r = try ProcessRunner.run(
            p, stdin: Data(payload.utf8), limits: limits
        )
        XCTAssertEqual(r.terminationStatus, 0)
        XCTAssertEqual(String(data: r.stdout, encoding: .utf8), payload)
    }
}
