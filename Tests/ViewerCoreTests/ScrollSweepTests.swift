import XCTest
@testable import ViewerCore

/// TSK-891 — the pure page-jump scroll schedule (measurement prep for the
/// Page-Up jank trace).
final class ScrollSweepTests: XCTestCase {

    func test_pagesDownThenUp_inPageSizedJumps() {
        // 100 lines, 20-line viewport → lastTop = 81; pages of 20.
        let s = ScrollSweep.self
        XCTAssertEqual(s.topLine(at: 0, totalLines: 100, pageLines: 20, steps: 10), 1)
        XCTAssertEqual(s.topLine(at: 1, totalLines: 100, pageLines: 20, steps: 10), 21)
        XCTAssertEqual(s.topLine(at: 2, totalLines: 100, pageLines: 20, steps: 10), 41)
        XCTAssertEqual(s.topLine(at: 3, totalLines: 100, pageLines: 20, steps: 10), 61)
        // Page 4 would be 81 (= lastTop, clamped) — the last full page top.
        XCTAssertEqual(s.topLine(at: 4, totalLines: 100, pageLines: 20, steps: 10), 81)
        // Then it folds and pages back UP (the janky direction).
        XCTAssertEqual(s.topLine(at: 5, totalLines: 100, pageLines: 20, steps: 10), 61)
        XCTAssertEqual(s.topLine(at: 6, totalLines: 100, pageLines: 20, steps: 10), 41)
    }

    func test_neverOverscrolls() {
        for i in 0..<50 {
            let top = ScrollSweep.topLine(at: i, totalLines: 100, pageLines: 20, steps: 20)
            XCTAssertGreaterThanOrEqual(top, 1)
            XCTAssertLessThanOrEqual(top, 81, "never past the last page-aligned top")
        }
    }

    func test_shortDocument_holdsAtTop() {
        // Doc shorter than a page → nothing to scroll.
        XCTAssertEqual(ScrollSweep.topLine(at: 3, totalLines: 10, pageLines: 20, steps: 5), 1)
    }

    func test_schedule_startsAndReturnsToTop_overAFullCycle() {
        // A schedule covering exactly one full down-up cycle returns to 1.
        let sched = ScrollSweep.schedule(totalLines: 100, pageLines: 20, steps: 8)
        XCTAssertEqual(sched.first, 1)
        XCTAssertEqual(sched.last, 1, "a full cycle of 8 (2*4 pages) folds back to the top")
        XCTAssertTrue(sched.contains(81), "the sweep reaches the last page")
    }

    func test_degenerateInputs_clampNoTrap() {
        XCTAssertEqual(ScrollSweep.topLine(at: 0, totalLines: 0, pageLines: 0, steps: 0), 1)
        XCTAssertEqual(ScrollSweep.schedule(totalLines: 100, pageLines: 20, steps: 0), [1])
        // Negative tick folds into range without trapping.
        XCTAssertGreaterThanOrEqual(
            ScrollSweep.topLine(at: -3, totalLines: 100, pageLines: 20, steps: 10), 1)
    }
}
