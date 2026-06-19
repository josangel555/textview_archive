import XCTest
@testable import ViewerCore

/// TSK-895: pins the horizontal-scroller visibility state machine that
/// replaces the CM6 editor's `overflow: auto` boundary flap.
///
/// The three load-bearing invariants (mirroring the doc comment on
/// `HorizontalScrollerVisibility`):
///
///   1. Output is a function of content-vs-viewport overflow ONLY — the
///      `typing` flag never moves it.
///   2. Consecutive same-overflow ticks never toggle the output (no flicker
///      while typing on a line whose width sits at the boundary).
///   3. Output only flips when overflow truly crosses the viewport boundary
///      AND clears the hysteresis band in that direction.
///
/// Teeth: `testKeystrokeFlapAtBoundaryIsStable` is the regression guard for
/// the actual bug — it replays the exact "type a glyph, measure wider,
/// scrollbar steals width, measure narrower, …" oscillation and asserts the
/// output never blinks. Remove the hysteresis (set margins to 0) and it goes
/// red, proving the test catches the flap.
final class HorizontalScrollerVisibilityTests: XCTestCase {

    // MARK: - Invariant 1: typing is ignored

    func testTypingFlagNeverChangesDecision() {
        // Same widths, only `typing` differs → identical output. A fitting
        // line stays hidden whether or not a keystroke is in flight.
        var fitting = HorizontalScrollerVisibility()
        XCTAssertFalse(fitting.update(contentWidth: 100, viewportWidth: 800, typing: false))
        XCTAssertFalse(fitting.update(contentWidth: 100, viewportWidth: 800, typing: true))

        // An overflowing line shows regardless of the typing flag.
        var overflowing = HorizontalScrollerVisibility()
        XCTAssertTrue(overflowing.update(contentWidth: 2000, viewportWidth: 800, typing: false))
        XCTAssertTrue(overflowing.update(contentWidth: 2000, viewportWidth: 800, typing: true))
    }

    func testTwoMachinesSameWidthsDifferentTypingConverge() {
        // Feed two independent machines the identical width trace but flip the
        // typing flag on alternate ticks of one of them. Final state + every
        // intermediate decision must match — typing carries zero signal.
        var a = HorizontalScrollerVisibility()
        var b = HorizontalScrollerVisibility()
        let widths: [(Double, Double)] = [
            (100, 800), (900, 800), (910, 800), (700, 800), (50, 800), (2000, 800),
        ]
        for (i, w) in widths.enumerated() {
            let ra = a.update(contentWidth: w.0, viewportWidth: w.1, typing: false)
            let rb = b.update(contentWidth: w.0, viewportWidth: w.1, typing: i.isMultiple(of: 2))
            XCTAssertEqual(ra, rb, "decision diverged at tick \(i) — typing leaked into the output")
        }
        XCTAssertEqual(a, b)
    }

    // MARK: - Invariant 2: no flap on same overflow

    func testFittingContentStaysHiddenAcrossKeystrokes() {
        var sm = HorizontalScrollerVisibility()
        for _ in 0..<50 {
            XCTAssertFalse(sm.update(contentWidth: 300, viewportWidth: 800, typing: true))
        }
    }

    func testOverflowingContentStaysVisibleAcrossKeystrokes() {
        var sm = HorizontalScrollerVisibility()
        for _ in 0..<50 {
            XCTAssertTrue(sm.update(contentWidth: 1500, viewportWidth: 800, typing: true))
        }
    }

    /// The actual TSK-895 regression: content width oscillates by a single
    /// glyph advance right at the viewport boundary while typing. With the
    /// hysteresis dead-band the output must NOT toggle — count transitions.
    func testKeystrokeFlapAtBoundaryIsStable() {
        // viewport = 800; content sits AT the boundary and a ~6px glyph
        // advance nudges it just over/under on alternating keystrokes —
        // exactly the width measurement that drove the original flap (and,
        // crucially, the scrollbar's own ~15px reservation that flips the
        // condition back once it appears).
        var sm = HorizontalScrollerVisibility()
        // Cross the boundary once so the scroller is shown.
        XCTAssertTrue(sm.update(contentWidth: 820, viewportWidth: 800, typing: true))

        var transitions = 0
        var prev = sm.isVisible
        // Now oscillate within the hysteresis band (797..803 around 800).
        let jitter: [Double] = [798, 802, 797, 803, 799, 801, 800, 798, 802]
        for w in jitter {
            let now = sm.update(contentWidth: w, viewportWidth: 800, typing: true)
            if now != prev { transitions += 1 }
            prev = now
        }
        XCTAssertEqual(transitions, 0, "scroller flapped within the hysteresis band — the keystroke flicker is back")
        XCTAssertTrue(sm.isVisible, "scroller should remain shown (sticky) through sub-band jitter")
    }

    /// Same flap, but starting from hidden: a fitting line whose width jitters
    /// just past the boundary by sub-band amounts must not start blinking the
    /// scroller in.
    func testHiddenStateHoldsThroughSubBandGrowth() {
        var sm = HorizontalScrollerVisibility()  // default showMargin = 2
        // 800..801 — within the +2 show band, so it must stay hidden.
        for w in [780.0, 800.0, 801.0, 799.0, 800.5, 801.5, 800.0] {
            XCTAssertFalse(sm.update(contentWidth: w, viewportWidth: 800, typing: true),
                           "scroller appeared on sub-show-margin growth (\(w)) — flap")
        }
    }

    // MARK: - Invariant 3: flips only on a true boundary cross

    func testShowsWhenContentClearlyExceedsViewport() {
        var sm = HorizontalScrollerVisibility()
        XCTAssertFalse(sm.isVisible)
        XCTAssertTrue(sm.update(contentWidth: 1200, viewportWidth: 800),
                      "clear overflow must show the scroller")
    }

    func testHidesWhenContentClearlyFitsAgain() {
        var sm = HorizontalScrollerVisibility(initiallyVisible: true)
        // Shrink well below the viewport (past the hide band).
        XCTAssertFalse(sm.update(contentWidth: 400, viewportWidth: 800),
                       "content shrinking well within the viewport must hide the scroller")
    }

    func testFullCrossingCycleShowsThenHides() {
        var sm = HorizontalScrollerVisibility()
        // Grow past the boundary → show.
        XCTAssertFalse(sm.update(contentWidth: 700, viewportWidth: 800))
        XCTAssertTrue(sm.update(contentWidth: 1000, viewportWidth: 800))
        // Shrink past the hide band → hide.
        XCTAssertFalse(sm.update(contentWidth: 500, viewportWidth: 800))
        // Grow again → show again.
        XCTAssertTrue(sm.update(contentWidth: 1000, viewportWidth: 800))
    }

    // MARK: - Hysteresis band semantics

    func testHysteresisHoldsPriorValueInsideDeadBand() {
        // Default: showMargin 2, hideMargin 8. The dead-band for a viewport of
        // 800 is roughly [792, 802]: a width in there keeps whatever the prior
        // decision was.
        var fromHidden = HorizontalScrollerVisibility(initiallyVisible: false)
        XCTAssertFalse(fromHidden.update(contentWidth: 801, viewportWidth: 800),
                       "801 is within the +2 show band → stays hidden")

        var fromShown = HorizontalScrollerVisibility(initiallyVisible: true)
        XCTAssertTrue(fromShown.update(contentWidth: 795, viewportWidth: 800),
                      "795 is within the -8 hide band → stays shown")
    }

    func testShowThresholdIsStrictlyGreaterThanMargin() {
        // overflow == showMargin exactly must NOT show (predicate is `>`).
        var sm = HorizontalScrollerVisibility(hysteresis: .init(showMargin: 5, hideMargin: 5))
        XCTAssertFalse(sm.update(contentWidth: 805, viewportWidth: 800),
                       "overflow exactly at showMargin must not show")
        XCTAssertTrue(sm.update(contentWidth: 805.01, viewportWidth: 800),
                      "overflow just past showMargin shows")
    }

    func testHideThresholdBoundary() {
        // shown; overflow == -hideMargin exactly must hide (predicate is `<=`).
        var sm = HorizontalScrollerVisibility(hysteresis: .init(showMargin: 2, hideMargin: 10),
                                              initiallyVisible: true)
        XCTAssertTrue(sm.update(contentWidth: 791, viewportWidth: 800),
                      "overflow -9 (inside the -10 hide band) stays shown")
        XCTAssertFalse(sm.update(contentWidth: 790, viewportWidth: 800),
                       "overflow exactly -hideMargin (-10) hides")
    }

    // MARK: - Degenerate inputs

    func testZeroViewportForcesHidden() {
        var sm = HorizontalScrollerVisibility(initiallyVisible: true)
        XCTAssertFalse(sm.update(contentWidth: 5000, viewportWidth: 0),
                       "a zero-width viewport must never show a scrollbar")
        XCTAssertFalse(sm.update(contentWidth: 5000, viewportWidth: -10),
                       "a negative viewport (degenerate) must never show a scrollbar")
    }

    func testNegativeContentWidthClampsToZero() {
        var sm = HorizontalScrollerVisibility(initiallyVisible: true)
        // Degenerate negative content can't overflow → must hide (it's well
        // below the viewport once clamped to 0).
        XCTAssertFalse(sm.update(contentWidth: -100, viewportWidth: 800))
    }

    func testNoHysteresisFlipsExactlyAtBoundary() {
        // The `.none` config is the raw predicate: overflow > 0 shows.
        var sm = HorizontalScrollerVisibility(hysteresis: .none)
        XCTAssertFalse(sm.update(contentWidth: 800, viewportWidth: 800),
                       "exactly fitting (overflow 0) does not show under .none")
        XCTAssertTrue(sm.update(contentWidth: 800.5, viewportWidth: 800),
                      "any overflow shows under .none")
        XCTAssertFalse(sm.update(contentWidth: 799.5, viewportWidth: 800),
                       "any underflow hides under .none")
    }

    // MARK: - Config clamping

    func testNegativeMarginsAreClampedToZero() {
        let h = HorizontalScrollerHysteresis(showMargin: -5, hideMargin: -3)
        XCTAssertEqual(h.showMargin, 0)
        XCTAssertEqual(h.hideMargin, 0)
    }

    // MARK: - Batch helper

    func testUpdateAllReturnsPerTickTrace() {
        var sm = HorizontalScrollerVisibility()
        let trace = sm.updateAll([
            (contentWidth: 100, viewportWidth: 800, typing: false),   // hidden
            (contentWidth: 1000, viewportWidth: 800, typing: true),   // show
            (contentWidth: 1010, viewportWidth: 800, typing: true),   // stay shown
            (contentWidth: 300, viewportWidth: 800, typing: false),   // hide
        ])
        XCTAssertEqual(trace, [false, true, true, false])
        XCTAssertFalse(sm.isVisible)
    }
}
