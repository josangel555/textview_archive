import XCTest
@testable import ViewerCore

/// Pure coverage for the leading-edge frame throttle that drives terminal
/// re-render coalescing. The key property under test is the LATENCY fix:
/// the first event after an idle gap must emit immediately (leading edge),
/// not wait a frame — the previous trailing-edge throttle delayed every
/// keystroke echo and read as "typing is slow".
final class FrameThrottleTests: XCTestCase {

    func test_firstEventAfterIdle_emitsImmediately() {
        var t = FrameThrottle()
        XCTAssertEqual(t.requestFrame(), .emitNow)   // leading edge — no wait
        XCTAssertTrue(t.isThrottling)
    }

    func test_eventDuringCooldown_isCoalesced() {
        var t = FrameThrottle()
        XCTAssertEqual(t.requestFrame(), .emitNow)
        // Anything during the cooldown window does NOT emit on its own.
        XCTAssertEqual(t.requestFrame(), .coalesced)
        XCTAssertEqual(t.requestFrame(), .coalesced)
    }

    func test_cooldownWithPendingOutput_emitsOneTrailingFrame_andStaysThrottling() {
        var t = FrameThrottle()
        _ = t.requestFrame()              // emitNow, opens cooldown
        _ = t.requestFrame()              // coalesced — trailing now owed
        // Cooldown elapses: a trailing frame is owed, and the throttle
        // remains in cooldown for that trailing frame's own window.
        XCTAssertTrue(t.cooldownElapsed())
        XCTAssertTrue(t.isThrottling)
    }

    func test_cooldownWithNoPendingOutput_goesIdle() {
        var t = FrameThrottle()
        _ = t.requestFrame()              // emitNow, opens cooldown
        // No further events. Cooldown elapses with nothing owed → idle.
        XCTAssertFalse(t.cooldownElapsed())
        XCTAssertFalse(t.isThrottling)
    }

    func test_afterIdle_nextEventIsAFreshLeadingEdge() {
        var t = FrameThrottle()
        _ = t.requestFrame()              // emitNow
        XCTAssertFalse(t.cooldownElapsed())   // idle (nothing accumulated)
        // The next event after going idle emits immediately again — proves
        // every keystroke typed slower than one frame paints with no delay.
        XCTAssertEqual(t.requestFrame(), .emitNow)
    }

    func test_trailingFrameThenIdle_converges() {
        var t = FrameThrottle()
        _ = t.requestFrame()              // emitNow
        _ = t.requestFrame()              // coalesced (trailing owed)
        XCTAssertTrue(t.cooldownElapsed())    // emit trailing, still throttling
        // No new output during the trailing frame's window → converge to idle.
        XCTAssertFalse(t.cooldownElapsed())
        XCTAssertFalse(t.isThrottling)
    }

    func test_sustainedBurst_emitsTrailingEveryWindow() {
        var t = FrameThrottle()
        _ = t.requestFrame()              // emitNow
        // Simulate a sustained burst: output keeps landing each window.
        for _ in 0..<5 {
            _ = t.requestFrame()          // coalesced — keeps trailing owed
            XCTAssertTrue(t.cooldownElapsed())   // one frame per window
            XCTAssertTrue(t.isThrottling)
        }
        // Burst ends: the window after the last output drains to idle.
        XCTAssertFalse(t.cooldownElapsed())
        XCTAssertFalse(t.isThrottling)
    }
}
