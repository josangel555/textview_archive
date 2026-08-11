import CoreGraphics
import Testing
import ViewerCore

/// I-21 S4d — the pure divider-drag math: a drag rebalances exactly the
/// two neighboring panes, clamps at the minimum span, preserves the
/// weight sum (so spans stay window-relative), and refuses degenerate
/// input unchanged.
@Suite struct PaneResizeTests {

    @Test func drag_movesSpanBetweenTheTwoNeighbors_only() {
        // Three equal panes over 900px usable → 300px each.
        let out = PaneResize.dragDivider(
            weights: [1, 1, 1], divider: 0, deltaPx: 60, totalPx: 900)
        // Left grew 60px, middle shrank 60px, right untouched.
        let sum = out.reduce(0, +)
        #expect(abs(out[0] / sum * 900 - 360) < 0.01)
        #expect(abs(out[1] / sum * 900 - 240) < 0.01)
        #expect(abs(out[2] / sum * 900 - 300) < 0.01)
        #expect(abs(sum - 3) < 0.0001, "the weight sum is preserved")
    }

    @Test func drag_clampsAtTheMinimumSpan_bothDirections() {
        // Two panes, 600px: each 300. minPx 120 ⇒ max travel ±180.
        let right = PaneResize.dragDivider(
            weights: [1, 1], divider: 0, deltaPx: 500, totalPx: 600, minPx: 120)
        let sumR = right.reduce(0, +)
        #expect(abs(right[1] / sumR * 600 - 120) < 0.01,
                "the right pane stops at the floor")
        let left = PaneResize.dragDivider(
            weights: [1, 1], divider: 0, deltaPx: -500, totalPx: 600, minPx: 120)
        let sumL = left.reduce(0, +)
        #expect(abs(left[0] / sumL * 600 - 120) < 0.01,
                "the left pane stops at the floor")
    }

    @Test func drag_onAnAlreadyUnderFloorPane_onlyAllowsGrowthBack() {
        // A tiny window squeezed the left pane under the floor: shrinking
        // it further is refused (delta clamps to 0)…
        let squeezed = PaneResize.dragDivider(
            weights: [0.1, 1.9], divider: 0, deltaPx: -50, totalPx: 400, minPx: 120)
        #expect(squeezed == [0.1, 1.9])
        // …but growing it back works.
        let grown = PaneResize.dragDivider(
            weights: [0.1, 1.9], divider: 0, deltaPx: 50, totalPx: 400, minPx: 120)
        #expect(grown[0] > 0.1)
    }

    @Test func degenerateInput_returnsWeightsUnchanged() {
        #expect(PaneResize.dragDivider(
            weights: [1], divider: 0, deltaPx: 10, totalPx: 600) == [1])
        #expect(PaneResize.dragDivider(
            weights: [1, 1], divider: 1, deltaPx: 10, totalPx: 600) == [1, 1],
            "the last pane has no divider after it")
        #expect(PaneResize.dragDivider(
            weights: [1, 1], divider: -1, deltaPx: 10, totalPx: 600) == [1, 1])
        #expect(PaneResize.dragDivider(
            weights: [1, 1], divider: 0, deltaPx: 10, totalPx: 0) == [1, 1])
        #expect(PaneResize.dragDivider(
            weights: [0, 0], divider: 0, deltaPx: 10, totalPx: 600) == [0, 0],
            "a zero weight sum can't be renormalized")
    }
}
