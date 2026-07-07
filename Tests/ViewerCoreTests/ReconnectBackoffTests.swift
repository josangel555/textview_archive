import XCTest
@testable import ViewerCore

/// TSK-1556 — the reconnect backoff/degrade policy.
final class ReconnectBackoffTests: XCTestCase {

    func test_cappedExponentialSchedule() {
        let b = ReconnectBackoff(baseMs: 250, capMs: 4_000, degradeAfterMs: nil)
        // 250 → 500 → 1000 → 2000 → 4000 → 4000 (capped) …
        XCTAssertEqual(b.delayMs(attempt: 0), 250)
        XCTAssertEqual(b.delayMs(attempt: 1), 500)
        XCTAssertEqual(b.delayMs(attempt: 2), 1_000)
        XCTAssertEqual(b.delayMs(attempt: 3), 2_000)
        XCTAssertEqual(b.delayMs(attempt: 4), 4_000)
        XCTAssertEqual(b.delayMs(attempt: 5), 4_000, "held at the cap")
    }

    func test_capHoldsForLargeAttempt_noOverflow() {
        let b = ReconnectBackoff(baseMs: 250, capMs: 4_000)
        // A pathological attempt count must saturate to the cap, never wrap.
        XCTAssertEqual(b.delayMs(attempt: 100), 4_000)
        XCTAssertEqual(b.delayMs(attempt: Int.max), 4_000)
    }

    func test_baseAboveCap_clampsToCap() {
        let b = ReconnectBackoff(baseMs: 9_000, capMs: 4_000)
        XCTAssertEqual(b.delayMs(attempt: 0), 4_000, "base itself is clamped to the cap")
        XCTAssertEqual(b.delayMs(attempt: 3), 4_000)
    }

    func test_degrade_afterWindow() {
        let b = ReconnectBackoff(degradeAfterMs: 30_000)
        XCTAssertFalse(b.shouldDegradeToLocal(elapsedMs: 0))
        XCTAssertFalse(b.shouldDegradeToLocal(elapsedMs: 29_999))
        XCTAssertTrue(b.shouldDegradeToLocal(elapsedMs: 30_000), "at the window → degrade")
        XCTAssertTrue(b.shouldDegradeToLocal(elapsedMs: 120_000))
    }

    func test_degrade_neverWhenNil_retriesForever() {
        // The MCP-bridge behavior: reconnect forever, never fall back.
        let b = ReconnectBackoff(degradeAfterMs: nil)
        XCTAssertFalse(b.shouldDegradeToLocal(elapsedMs: UInt64.max))
    }

    func test_defaults_matchTheDesign() {
        let b = ReconnectBackoff()
        XCTAssertEqual(b.baseMs, 250)
        XCTAssertEqual(b.capMs, 4_000)
        XCTAssertEqual(b.degradeAfterMs, 30_000)
    }
}
