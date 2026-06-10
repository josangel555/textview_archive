import XCTest
import ViewerCore

/// Pins the `resize-sweep` width schedule (TSK-592): triangle wave with
/// inclusive endpoints, peak at the midpoint, and clamped degenerate
/// inputs — the part of the profiling driver a host test can hold.
final class ResizeSweepTests: XCTestCase {

    func test_triangleWave_endpointsAndPeak() {
        XCTAssertEqual(ResizeSweep.width(at: 0,  minW: 700, maxW: 1400, steps: 90), 700)
        XCTAssertEqual(ResizeSweep.width(at: 45, minW: 700, maxW: 1400, steps: 90), 1400)
        XCTAssertEqual(ResizeSweep.width(at: 90, minW: 700, maxW: 1400, steps: 90), 700)
    }

    func test_monotonicOutThenBack() {
        var prev = -Double.infinity
        for i in 0...45 {
            let w = ResizeSweep.width(at: i, minW: 700, maxW: 1400, steps: 90)
            XCTAssertGreaterThanOrEqual(w, prev, "rising half must be monotonic")
            prev = w
        }
        for i in 45...90 {
            let w = ResizeSweep.width(at: i, minW: 700, maxW: 1400, steps: 90)
            XCTAssertLessThanOrEqual(w, prev, "falling half must be monotonic")
            prev = w
        }
    }

    func test_degenerateInputs_clampNotTrap() {
        // steps < 1 → hold at the low bound.
        XCTAssertEqual(ResizeSweep.width(at: 5, minW: 700, maxW: 1400, steps: 0), 700)
        // reversed bounds are swapped.
        XCTAssertEqual(ResizeSweep.width(at: 0, minW: 1400, maxW: 700, steps: 10), 700)
        // out-of-range i clamps to the endpoints.
        XCTAssertEqual(ResizeSweep.width(at: -3, minW: 700, maxW: 1400, steps: 10), 700)
        XCTAssertEqual(ResizeSweep.width(at: 99, minW: 700, maxW: 1400, steps: 10), 700)
    }
}
