import XCTest
@testable import ViewerUI
import ViewerCore

/// Pure-logic tests for `WalkthroughAutoAdvance`'s dwell math + speed
/// handling. These don't spin a real Task.sleep (auto-advance scheduling
/// is timing-sensitive and would flake on a busy CI) — they exercise
/// the deterministic helpers.
@MainActor
final class WalkthroughAutoAdvanceTests: XCTestCase {

    func test_effectiveDwell_usesPerStepOverride_whenProvided() {
        let dwell = WalkthroughAutoAdvance.effectiveDwell(
            forStepDwell: 4.0, speed: .x1
        )
        XCTAssertEqual(dwell, 4.0, accuracy: 0.0001)
    }

    func test_effectiveDwell_fallsBackToDefault_whenNil() {
        let dwell = WalkthroughAutoAdvance.effectiveDwell(
            forStepDwell: nil, speed: .x1
        )
        XCTAssertEqual(dwell, 9.0, accuracy: 0.0001)  // 9000ms default
    }

    func test_effectiveDwell_dividesBySpeed_at1_5x() {
        let dwell = WalkthroughAutoAdvance.effectiveDwell(
            forStepDwell: 6.0, speed: .x1_5
        )
        XCTAssertEqual(dwell, 4.0, accuracy: 0.0001)
    }

    func test_effectiveDwell_dividesBySpeed_at2x() {
        let dwell = WalkthroughAutoAdvance.effectiveDwell(
            forStepDwell: 8.0, speed: .x2
        )
        XCTAssertEqual(dwell, 4.0, accuracy: 0.0001)
    }

    func test_effectiveDwell_atDefault_2x_halvesTo4_5s() {
        let dwell = WalkthroughAutoAdvance.effectiveDwell(
            forStepDwell: nil, speed: .x2
        )
        XCTAssertEqual(dwell, 4.5, accuracy: 0.0001)
    }

    func test_effectiveDwell_negativeBaseClampsToZero() {
        // Defense: a malformed script with a negative dwell shouldn't
        // crash or fire instantly with a wraparound nanos value.
        let dwell = WalkthroughAutoAdvance.effectiveDwell(
            forStepDwell: -5.0, speed: .x1
        )
        XCTAssertEqual(dwell, 0, accuracy: 0.0001)
    }

    func test_speedLabels_areCanonical() {
        XCTAssertEqual(WalkthroughAutoAdvance.Speed.x1.label, "1x")
        XCTAssertEqual(WalkthroughAutoAdvance.Speed.x1_5.label, "1.5x")
        XCTAssertEqual(WalkthroughAutoAdvance.Speed.x2.label, "2x")
    }

    func test_setSpeed_updatesSpeedProperty() {
        let adv = WalkthroughAutoAdvance()
        XCTAssertEqual(adv.speed, .x1)
        adv.setSpeed(.x2)
        XCTAssertEqual(adv.speed, .x2)
        adv.setSpeed(.x1_5)
        XCTAssertEqual(adv.speed, .x1_5)
    }

    func test_cancel_isIdempotent_whenNothingScheduled() {
        let adv = WalkthroughAutoAdvance()
        adv.cancel()
        adv.cancel()   // must not crash
        XCTAssertFalse(adv.isRunning)
    }

    func test_setSpeed_sameValue_noOps() {
        let adv = WalkthroughAutoAdvance()
        adv.setSpeed(.x1)
        // No public way to assert "didn't reschedule", but this should
        // not crash and `speed` stays unchanged.
        XCTAssertEqual(adv.speed, .x1)
    }
}
