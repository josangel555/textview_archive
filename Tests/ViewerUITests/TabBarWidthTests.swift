import XCTest
@testable import ViewerUI

/// Coverage for `TabBar.computedTabWidth(available:count:scale:)` — the
/// tab-strip layout math. Was untested. Assertions are **relational** (no
/// hardcoded `minShrunkWidth`/`idealTabWidth` constants) so they survive a
/// constants tweak while still pinning the real contract: the
/// `count==0`/`available<=0` div-by-zero guard, the `[lower, upper]` clamp,
/// monotonic shrink as tab count grows, and linear `scale`.
@MainActor
final class TabBarWidthTests: XCTestCase {

    private func w(_ available: CGFloat, _ count: Int, _ scale: CGFloat = 1) -> CGFloat {
        TabBar.computedTabWidth(available: available, count: count, scale: scale)
    }

    /// `count == 0` (or non-positive `available`) hits the guard and returns
    /// the upper clamp — crucially WITHOUT dividing by zero.
    private var upper: CGFloat { w(100_000, 0) }
    /// A hugely crowded strip saturates at the lower clamp.
    private var lower: CGFloat { w(1, 100_000) }

    func test_boundsAreSanePositiveAndOrdered() {
        XCTAssertGreaterThan(lower, 0)
        XCTAssertGreaterThan(upper, lower, "ideal width must exceed the shrink floor")
    }

    func test_guard_zeroCount_and_nonPositiveAvailable_returnUpper_noDivByZero() {
        XCTAssertEqual(w(500, 0), upper)
        XCTAssertEqual(w(0, 5), upper)
        XCTAssertEqual(w(-10, 5), upper)
    }

    func test_sparse_saturatesToUpper() {
        // One tab in a wide strip → capped at the ideal width.
        XCTAssertEqual(w(100_000, 1), upper, accuracy: 0.001)
    }

    func test_crowded_saturatesToLower() {
        XCTAssertEqual(w(50, 10_000), lower, accuracy: 0.001)
    }

    func test_resultAlwaysWithinClampBounds() {
        for available: CGFloat in [10, 200, 800, 3000, 50_000] {
            for count in [1, 2, 5, 20, 200] {
                let r = w(available, count)
                XCTAssertGreaterThanOrEqual(r, lower - 0.001, "below floor at \(available)/\(count)")
                XCTAssertLessThanOrEqual(r, upper + 0.001, "above ideal at \(available)/\(count)")
            }
        }
    }

    func test_nonIncreasingAsCountGrows() {
        let available: CGFloat = 1500
        let widths = [1, 4, 8, 40, 400].map { w(available, $0) }
        for i in 1..<widths.count {
            XCTAssertLessThanOrEqual(widths[i], widths[i - 1] + 0.001,
                                     "more tabs must never widen a tab")
        }
    }

    func test_scale_isLinear_atBothSaturations() {
        // Upper clamp scales linearly.
        XCTAssertEqual(w(100_000, 0, 2), 2 * w(100_000, 0, 1), accuracy: 0.001)
        // Lower clamp scales linearly.
        XCTAssertEqual(w(1, 100_000, 2), 2 * w(1, 100_000, 1), accuracy: 0.001)
    }
}
