import XCTest
@testable import ViewerUI

/// TSK-138 — terminate() must actually COLLECT the shell child, not just
/// signal it. The audited leak: a single WNOHANG immediately after SIGHUP
/// reliably misses (the shell hasn't exited yet), leaving one zombie per
/// teardown/restart/quit. The existing lifecycle suite only asserts that
/// terminate() returns promptly — its own doc concedes collection is
/// unasserted. This pins it: after terminate(), `kill(pid, 0)` must reach
/// ESRCH (pid fully gone). A ZOMBIE keeps `kill(pid, 0)` succeeding —
/// which is exactly how a reverted reap ladder goes red here.
final class PTYReapTests: XCTestCase {

    func test_terminate_collectsChild_noZombie() throws {
        let pty = PTYProcess()
        guard pty.start(rows: 24, cols: 80) else {
            throw XCTSkip("PTY spawn unavailable in this environment")
        }
        let pid = pty.childPID
        XCTAssertGreaterThan(pid, 0, "start() must record the child pid")

        pty.terminate()

        // The reap runs off-thread (readQueue) and may take the ~200ms
        // WNOHANG grace + SIGKILL escalation. Poll for the pid to be GONE:
        // ESRCH means collected; a zombie answers kill(pid,0) == 0 forever.
        let deadline = Date().addingTimeInterval(5)
        var collected = false
        while Date() < deadline {
            errno = 0
            let r = kill(pid, 0)
            if r != 0 && errno == ESRCH { collected = true; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(collected,
            "child \(pid) still exists after terminate() — kill(pid,0) keeps "
            + "succeeding, i.e. a ZOMBIE was left unreaped (the TSK-138 leak)")
    }
}
