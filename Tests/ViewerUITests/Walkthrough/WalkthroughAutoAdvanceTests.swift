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

    // MARK: - Self-rearming (regression: F-WCR-AUTOADV)

    /// The in-flight Task (and the zero-dwell fast path) call
    /// `engine.next()` DIRECTLY, bypassing the controller's `next()`.
    /// Re-arming therefore has to happen via the scheduler's `onAdvance`
    /// hook, not the SwiftUI strip lifecycle — otherwise a tour advances
    /// exactly one step and stalls when the window is occluded.
    ///
    /// We exercise the deterministic zero-dwell path (no `Task.sleep`):
    /// every `schedule` fires synchronously, so a correctly self-rearming
    /// scheduler walks an N-step script all the way to `.done` in one
    /// synchronous burst. Before the fix, the engine would stop after a
    /// single advance.
    func test_zeroDwellChain_selfRearmsThroughEveryStep() {
        let engine = WalkthroughEngine()
        let adv = WalkthroughAutoAdvance(engine: engine)

        // 3 zero-dwell steps — mirrors the F-WCR-AUTOADV probe
        // (main -> helper -> README). narrateOnly needs no DocumentModel.
        let script = WalkthroughScript(
            id: "auto-rearm", title: "rearm",
            steps: [
                Step(id: "main",   dwellSec: 0, actions: [.narrateOnly]),
                Step(id: "helper", dwellSec: 0, actions: [.narrateOnly]),
                Step(id: "readme", dwellSec: 0, actions: [.narrateOnly]),
            ]
        )
        engine.load(script)

        // Mirror the controller's re-arm: on each auto-fired advance,
        // schedule the now-current step (and stop at .done).
        var advanceCount = 0
        adv.onAdvance = { [weak engine] in
            advanceCount += 1
            guard let engine, engine.state == .playing else { return }
            adv.schedule(forStepDwell: engine.script?.steps[engine.stepIndex].dwellSec)
        }

        // Kick off: land step 0, then schedule its (zero) dwell.
        engine.next()
        XCTAssertEqual(engine.stepIndex, 0)
        adv.schedule(forStepDwell: script.steps[0].dwellSec)

        // The synchronous zero-dwell chain must have run to the end.
        XCTAssertEqual(engine.state, .done,
                       "auto-advance stalled instead of reaching .done")
        XCTAssertEqual(engine.stepIndex, 2,
                       "should land on the final step (readme), not stall on step 1")
        // 3 advances landed steps 1 and 2 and then stepped off the end.
        XCTAssertEqual(advanceCount, 3)
        XCTAssertFalse(adv.isRunning)
    }
}
