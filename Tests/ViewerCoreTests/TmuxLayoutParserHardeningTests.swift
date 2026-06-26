import XCTest
@testable import ViewerCore

/// Hardening coverage for `TmuxLayoutParser`, targeting the highest-severity
/// gaps the happy-path suite (`TmuxLayoutParserTests`) leaves uncovered:
///   • HIGH — unbounded recursion on deeply-nested layouts (stack overflow,
///     weaponizable from a hostile/garbled control stream; worse on the small
///     ~512KB PTY-pump thread). The parser now caps nesting depth → `nil`.
///   • MEDIUM — the even-split epsilon (`1/total`) misclassifies genuine small
///     uneven splits (e.g. 40/60 on a 10-cell container) as even, discarding
///     the user's real pane proportions.
final class TmuxLayoutParserHardeningTests: XCTestCase {

    private func p(_ n: Int) -> TmuxPaneID { TmuxPaneID(n) }

    // MARK: - HIGH: deep nesting must not crash (stack-overflow guard)

    /// Build an N-deep nested layout: each level wraps the previous in a
    /// horizontal group `{ … }`. The innermost is a bare leaf.
    private func deeplyNested(depth: Int) -> String {
        var s = "80x24,0,0,1"
        for _ in 0..<depth {
            s = "80x24,0,0{" + s + "}"
        }
        return "9f2b," + s
    }

    /// A 50_000-deep nested layout — far past anything tmux emits, and past the
    /// ~18k a fresh MAIN thread tolerates — must return WITHOUT crashing. The
    /// pre-fix parser overflowed the stack here (SIGILL/SIGSEGV, exit 132).
    /// With the depth cap it returns `nil` (caller ignores the layout).
    func test_deepNesting_doesNotCrash_returnsNil() {
        let layout = deeplyNested(depth: 50_000)
        XCTAssertNil(TmuxLayoutParser.parse(layout),
                     "a layout nested past the depth cap must be rejected, not crash")
    }

    /// The same hostile input parsed on a Thread with a SMALL stack (512 KB,
    /// mirroring the PTY-pump thread slice-d will run the parser on) must ALSO
    /// not crash — proving the cap, not the generous main-thread stack, is what
    /// keeps us safe. The pre-fix parser crashed the whole process here at a far
    /// lower depth (~1-2k), so this is the load-bearing teeth for the fix.
    func test_deepNesting_onSmallStackThread_doesNotCrash() {
        let layout = deeplyNested(depth: 50_000)
        let done = XCTestExpectation(description: "parse completed on small-stack thread")
        var result: PaneNode??  // outer optional: did it run; inner: parse result
        let thread = Thread {
            result = TmuxLayoutParser.parse(layout)
            done.fulfill()
        }
        thread.stackSize = 512 * 1024   // 512 KB — the small off-main stack
        thread.start()
        wait(for: [done], timeout: 10)
        // It ran to completion (no crash) and rejected the over-deep layout.
        XCTAssertNotNil(result, "the parse closure never completed (likely crashed)")
        XCTAssertEqual(result, .some(nil), "over-deep layout must parse to nil")
    }

    /// A layout nested RIGHT AT a comfortably-legal depth still parses fine —
    /// the cap must not reject realistic (shallow) tmux layouts. 32 levels is
    /// already absurdly deep for a real window yet well under the 256 cap.
    func test_moderateNesting_withinCap_stillParses() {
        let layout = deeplyNested(depth: 32)
        XCTAssertNotNil(TmuxLayoutParser.parse(layout),
                        "a legal (shallow) layout must still parse under the cap")
    }

    // MARK: - MEDIUM: small-total uneven splits preserve real weights

    /// A 40/60 split on a 10-cell-wide container (`4x` vs `6x`) is a GENUINE
    /// user resize — it must yield proportional weights ≈ [0.4, 0.6], NOT be
    /// flattened to an equal split. The old epsilon (`1/total` = 0.1 of the
    /// container) treated each child's 1-cell deviation from the ideal-5 as
    /// "even" and emitted `nil`, drawing 50/50 instead of 40/60.
    func test_smallTotal_unevenSplit_preservesWeights() {
        let tree = TmuxLayoutParser.parse("9f2b,10x24,0,0{4x24,0,0,1,6x24,4,0,2}")
        guard case let .split(axis, children, weights) = tree else {
            return XCTFail("expected a split, got \(String(describing: tree))")
        }
        XCTAssertEqual(axis, .horizontal)
        XCTAssertEqual(children, [.leaf(paneID: p(1)), .leaf(paneID: p(2))])
        XCTAssertNotNil(weights, "a real 40/60 split must NOT collapse to equal")
        XCTAssertEqual(weights?[0] ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertEqual(weights?[1] ?? -1, 0.6, accuracy: 1e-9)
    }

    /// A 2:1 split (`2x` vs `1x`, total 3) must preserve ≈ [0.667, 0.333].
    func test_smallTotal_twoToOneSplit_preservesWeights() {
        let tree = TmuxLayoutParser.parse("9f2b,3x24,0,0{2x24,0,0,1,1x24,2,0,2}")
        guard case let .split(_, _, weights) = tree else {
            return XCTFail("expected a split, got \(String(describing: tree))")
        }
        XCTAssertNotNil(weights, "a real 2:1 split must NOT collapse to equal")
        XCTAssertEqual(weights?[0] ?? -1, 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(weights?[1] ?? -1, 1.0 / 3.0, accuracy: 1e-9)
    }

    /// A genuinely EVEN small split (`5x` vs `5x`, total 10) must still collapse
    /// to `nil` (equal) — the tightened epsilon must not over-correct and start
    /// emitting weights for clean halves.
    func test_smallTotal_evenSplit_stillCollapsesToEqual() {
        let tree = TmuxLayoutParser.parse("9f2b,10x24,0,0{5x24,0,0,1,5x24,5,0,2}")
        guard case let .split(_, _, weights) = tree else {
            return XCTFail("expected a split, got \(String(describing: tree))")
        }
        XCTAssertNil(weights, "a clean 50/50 split must remain an equal (nil-weight) split")
    }

    /// A near-even split that differs by exactly one cell on an EVEN-sized
    /// container (`88x` vs `89x`, the canonical tmux divider rounding) must
    /// still be treated as even — the ±1-cell rounding tolerance the docstring
    /// promises must survive the epsilon tightening. (Regression guard for the
    /// happy-path `test_horizontalSplit_twoLeaves_evenGeometry_equalWeights`.)
    func test_largeTotal_oneCleftDivider_stillEven() {
        let tree = TmuxLayoutParser.parse("bf3a,178x40,0,0{88x40,0,0,1,89x40,89,0,2}")
        guard case let .split(_, _, weights) = tree else {
            return XCTFail("expected a split, got \(String(describing: tree))")
        }
        XCTAssertNil(weights, "an 88/89 divider-rounded split must remain equal")
    }
}
