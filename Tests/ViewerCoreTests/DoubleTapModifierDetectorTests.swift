import XCTest
@testable import ViewerCore

/// TSK-707: the pure double-Shift detector behind the IntelliJ-style command-
/// palette shortcut. These pin the fire/no-fire behaviour so a logic
/// regression fails the host gate even though the live `flagsChanged` monitor
/// is VM-only.
final class DoubleTapModifierDetectorTests: XCTestCase {

    /// Convenience: feed a sequence and return the index at which it fired (or
    /// nil), asserting it fires at most once.
    private func fireIndex(
        _ events: [DoubleTapModifierDetector.Event],
        interval: TimeInterval = 0.30
    ) -> Int? {
        var det = DoubleTapModifierDetector(interval: interval)
        var fired: Int?
        for (i, e) in events.enumerated() where det.handle(e) {
            XCTAssertNil(fired, "detector fired more than once at \(i)")
            fired = i
        }
        return fired
    }

    func testCleanDoubleTapFiresOnSecondPress() {
        // down → up → down within the interval → fire on the 2nd down (index 2).
        let idx = fireIndex([.modifierDown(at: 0.00), .modifierUp, .modifierDown(at: 0.15)])
        XCTAssertEqual(idx, 2)
    }

    func testSingleTapDoesNotFire() {
        XCTAssertNil(fireIndex([.modifierDown(at: 0.0), .modifierUp]))
    }

    func testSecondPressTooLateDoesNotFire() {
        // 0.40s > 0.30s interval → the second press starts a fresh first tap.
        XCTAssertNil(fireIndex([.modifierDown(at: 0.0), .modifierUp, .modifierDown(at: 0.40)]))
    }

    func testIntermediateKeyResetsSoTypingCapitalsDoesNotFire() {
        // The crucial anti-false-fire case: Shift down, a letter (reset), Shift
        // up, Shift down, a letter (reset)… — typing two capital letters must
        // NOT open the palette.
        let events: [DoubleTapModifierDetector.Event] = [
            .modifierDown(at: 0.00), .reset, .modifierUp,
            .modifierDown(at: 0.10), .reset, .modifierUp,
        ]
        XCTAssertNil(fireIndex(events))
    }

    func testResetBetweenTapsBlocksFire() {
        // down → up → (reset) → down: the reset clears the armed first tap.
        XCTAssertNil(fireIndex([
            .modifierDown(at: 0.0), .modifierUp, .reset, .modifierDown(at: 0.10),
        ]))
    }

    func testBoundaryIntervalFires() {
        // Exactly at the interval is inclusive (<=).
        XCTAssertEqual(
            fireIndex([.modifierDown(at: 0.0), .modifierUp, .modifierDown(at: 0.30)]),
            2
        )
    }

    func testTripleTapFiresOnlyOnce() {
        // down,up,down(FIRE),up,down — the 3rd press starts a fresh tap, so the
        // only fire is the 2nd press (index 2), not a second fire later.
        let idx = fireIndex([
            .modifierDown(at: 0.00), .modifierUp,
            .modifierDown(at: 0.10), .modifierUp,
            .modifierDown(at: 0.20),
        ])
        XCTAssertEqual(idx, 2)
    }

    func testQuadrupleTapFiresTwiceAcrossTwoPairs() {
        // Two independent double-taps in a row each fire once. Feed manually to
        // capture every fire (the helper asserts at-most-once).
        var det = DoubleTapModifierDetector(interval: 0.30)
        var fires: [Int] = []
        let events: [DoubleTapModifierDetector.Event] = [
            .modifierDown(at: 0.00), .modifierUp, .modifierDown(at: 0.10), // fire @2
            .modifierUp,
            .modifierDown(at: 0.50), .modifierUp, .modifierDown(at: 0.60), // fire @6
        ]
        for (i, e) in events.enumerated() where det.handle(e) { fires.append(i) }
        XCTAssertEqual(fires, [2, 6])
    }

    func testReleaseWithoutPriorPressIsInert() {
        // A stray modifierUp (e.g. monitor installed mid-hold) must not arm.
        XCTAssertNil(fireIndex([.modifierUp, .modifierDown(at: 0.0), .modifierUp]))
    }

    func testExplicitResetMethodClearsArmedState() {
        var det = DoubleTapModifierDetector(interval: 0.30)
        XCTAssertFalse(det.handle(.modifierDown(at: 0.0)))
        XCTAssertFalse(det.handle(.modifierUp)) // armed
        det.reset()
        // After reset, the next press is a fresh first tap, not a completion.
        XCTAssertFalse(det.handle(.modifierDown(at: 0.05)))
    }
}
