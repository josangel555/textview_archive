import XCTest

@testable import RustCore

/// Regression coverage for the audit test-gap on `CoreClient.swift`'s session
/// state machine (`liveHandle` / `check` / `callBuf`, lines ~153-180): a caught
/// panic on a handle-taking session call must (1) throw `.panic`, (2) latch the
/// session's dead-flag, and (3) cause the NEXT real call to throw `.handleDead`
/// — never re-entering the suspect Rust state. Plus the `Busy` contention
/// contract: a contended single-writer lock maps to `.busy` and must NOT
/// dead-flag the session (contention is retryable, not fatal).
///
/// The audit suggested a Rust-side panicking session shim, but the FFI crate is
/// frozen for this fix; `_simulateSessionCall(_:)` is a DEBUG-only Swift hook
/// that drives the SAME `liveHandle()` + `check()` path every production session
/// call flows through, so it faithfully exercises the dead-flag logic under
/// audit without fabricating a Rust symbol. Headless (no SwiftUI /
/// NSApplication), so host-safe per the project's testing rules.
final class SessionPanicDeadFlagAuditTests: XCTestCase {

    private let csv = "name,city\nAlice,Paris\nBob,Parma\nCarol,Berlin\n"

    /// 1st call panics → `.panic` + dead latched; 2nd REAL call → `.handleDead`.
    func testPanicOnSessionCallDeadFlagsAndBlocksReuse() throws {
        let session = try CsvSession(csv: csv)

        // Live before any fault: a real call succeeds and dead is clear.
        XCTAssertFalse(session._isDead)
        _ = try session.table()

        // 1st call: a handle-taking session call panics in the core. The
        // boundary maps it to `.panic`; the wrapper must latch the dead-flag.
        XCTAssertThrowsError(try session._simulateSessionCall(.panic)) { error in
            XCTAssertEqual(error as? CoreError, .panic)
        }
        XCTAssertTrue(session._isDead, "a caught panic must latch the dead-flag")

        // 2nd call: a real session method must now refuse to touch suspect
        // state and throw `.handleDead` (not re-enter the core, not `.panic`).
        XCTAssertThrowsError(try session.table()) { error in
            XCTAssertEqual(error as? CoreError, .handleDead)
        }
        XCTAssertThrowsError(try session.snapshot()) { error in
            XCTAssertEqual(error as? CoreError, .handleDead)
        }
        XCTAssertThrowsError(try session.setFilter("x")) { error in
            XCTAssertEqual(error as? CoreError, .handleDead)
        }

        // The dead-flag is sticky: even the simulated path now short-circuits at
        // liveHandle() with `.handleDead` before reaching check().
        XCTAssertThrowsError(try session._simulateSessionCall(.ok)) { error in
            XCTAssertEqual(error as? CoreError, .handleDead)
        }
    }

    /// Busy contention: `MDV_STATUS_BUSY` → `.busy`, and the session must remain
    /// LIVE (contention on the single-writer lock is retryable, not a fault that
    /// poisons the handle). After a busy throw, a real call still works.
    func testBusyContentionMapsToBusyAndDoesNotDeadFlag() throws {
        let session = try CsvSession(csv: csv)

        XCTAssertThrowsError(try session._simulateSessionCall(.busy)) { error in
            XCTAssertEqual(error as? CoreError, .busy)
        }
        XCTAssertFalse(session._isDead, ".busy must NOT dead-flag — contention is retryable")

        // The session is unharmed: a real call still succeeds (the retry path).
        let table = try session.table()
        XCTAssertEqual(table.header, ["name", "city"])

        let snap = try session.snapshot()
        XCTAssertEqual(snap.totalRows, 3)
    }

    /// A `.busy` throw before a `.panic` on the same session: the busy must not
    /// pre-poison the handle, and the later panic must still latch correctly —
    /// pins the ordering independence of the two contention/fatal arms.
    func testBusyThenPanicLatchesOnlyOnPanic() throws {
        let session = try CsvSession(csv: csv)

        XCTAssertThrowsError(try session._simulateSessionCall(.busy)) { error in
            XCTAssertEqual(error as? CoreError, .busy)
        }
        XCTAssertFalse(session._isDead)

        XCTAssertThrowsError(try session._simulateSessionCall(.panic)) { error in
            XCTAssertEqual(error as? CoreError, .panic)
        }
        XCTAssertTrue(session._isDead)

        XCTAssertThrowsError(try session.snapshot()) { error in
            XCTAssertEqual(error as? CoreError, .handleDead)
        }
    }
}
