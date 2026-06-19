import XCTest
import CoreGraphics
@testable import ViewerCore

/// Headless coverage for the pure tmux split-tree model (TSK-964): nominal
/// split-frame geometry, leaf enumeration, click hit-testing, and active-pane
/// key-routing target selection. The on-screen render + real keystroke
/// delivery + divider drag are the VM pixel/interaction tier.
final class TerminalPaneTreeTests: XCTestCase {

    private func p(_ n: Int) -> TmuxPaneID { TmuxPaneID(n) }
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    // MARK: - Geometry

    func test_singleLeaf_fillsBounds() {
        let frames = TerminalPaneTree.frames(for: .leaf(paneID: p(1)), in: bounds)
        XCTAssertEqual(frames, [PaneFrame(paneID: p(1), rect: bounds)])
    }

    func test_horizontalSplit_dividesWidthLeftToRight() {
        let node = PaneNode.split(axis: .horizontal, children: [
            .leaf(paneID: p(1)), .leaf(paneID: p(2)),
        ])
        let frames = TerminalPaneTree.frames(for: node, in: bounds)
        XCTAssertEqual(frames, [
            PaneFrame(paneID: p(1), rect: CGRect(x: 0, y: 0, width: 400, height: 600)),
            PaneFrame(paneID: p(2), rect: CGRect(x: 400, y: 0, width: 400, height: 600)),
        ])
    }

    func test_verticalSplit_dividesHeightTopToBottom() {
        let node = PaneNode.split(axis: .vertical, children: [
            .leaf(paneID: p(1)), .leaf(paneID: p(2)),
        ])
        let frames = TerminalPaneTree.frames(for: node, in: bounds)
        XCTAssertEqual(frames, [
            PaneFrame(paneID: p(1), rect: CGRect(x: 0, y: 0, width: 800, height: 300)),
            PaneFrame(paneID: p(2), rect: CGRect(x: 0, y: 300, width: 800, height: 300)),
        ])
    }

    func test_nestedSplit_recursesIntoChildContainer() {
        // Left pane full-height; right column split vertically into two.
        let node = PaneNode.split(axis: .horizontal, children: [
            .leaf(paneID: p(1)),
            .split(axis: .vertical, children: [.leaf(paneID: p(2)), .leaf(paneID: p(3))]),
        ])
        let frames = TerminalPaneTree.frames(for: node, in: bounds)
        XCTAssertEqual(frames, [
            PaneFrame(paneID: p(1), rect: CGRect(x: 0, y: 0, width: 400, height: 600)),
            PaneFrame(paneID: p(2), rect: CGRect(x: 400, y: 0, width: 400, height: 300)),
            PaneFrame(paneID: p(3), rect: CGRect(x: 400, y: 300, width: 400, height: 300)),
        ])
    }

    func test_weights_giveProportionalShares() {
        // 1:3 split → left quarter, right three-quarters.
        let node = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(paneID: p(1)), .leaf(paneID: p(2))],
            weights: [1, 3]
        )
        let frames = TerminalPaneTree.frames(for: node, in: bounds)
        XCTAssertEqual(frames[0].rect, CGRect(x: 0, y: 0, width: 200, height: 600))
        XCTAssertEqual(frames[1].rect, CGRect(x: 200, y: 0, width: 600, height: 600))
    }

    func test_mismatchedOrNonPositiveWeights_fallBackToEqual() {
        // Wrong count → equal halves.
        let wrongCount = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(paneID: p(1)), .leaf(paneID: p(2))],
            weights: [1, 2, 3]
        )
        let f1 = TerminalPaneTree.frames(for: wrongCount, in: bounds)
        XCTAssertEqual(f1[0].rect.width, 400)
        XCTAssertEqual(f1[1].rect.width, 400)

        // Non-positive sum → equal halves (no NaN, no zero-width pane).
        let zeroSum = PaneNode.split(
            axis: .horizontal,
            children: [.leaf(paneID: p(1)), .leaf(paneID: p(2))],
            weights: [0, 0]
        )
        let f2 = TerminalPaneTree.frames(for: zeroSum, in: bounds)
        XCTAssertEqual(f2[0].rect.width, 400)
        XCTAssertEqual(f2[1].rect.width, 400)
    }

    func test_dividerThickness_reservesGutterBetweenChildren() {
        let node = PaneNode.split(axis: .horizontal, children: [
            .leaf(paneID: p(1)), .leaf(paneID: p(2)),
        ])
        let frames = TerminalPaneTree.frames(for: node, in: bounds, dividerThickness: 10)
        // 800 − 10 gutter = 790 usable → 395 each; right starts after gutter.
        XCTAssertEqual(frames[0].rect, CGRect(x: 0, y: 0, width: 395, height: 600))
        XCTAssertEqual(frames[1].rect, CGRect(x: 405, y: 0, width: 395, height: 600))
    }

    func test_singleChildSplit_fillsContainer() {
        let node = PaneNode.split(axis: .horizontal, children: [.leaf(paneID: p(7))])
        let frames = TerminalPaneTree.frames(for: node, in: bounds, dividerThickness: 12)
        XCTAssertEqual(frames, [PaneFrame(paneID: p(7), rect: bounds)])
    }

    func test_degenerateBounds_yieldNoFrames() {
        XCTAssertTrue(TerminalPaneTree.frames(for: .leaf(paneID: p(1)),
                                              in: CGRect(x: 0, y: 0, width: 0, height: 600)).isEmpty)
        XCTAssertTrue(TerminalPaneTree.frames(for: .leaf(paneID: p(1)),
                                              in: CGRect(x: 0, y: 0, width: 800, height: 0)).isEmpty)
    }

    func test_framesTileBoundsExactly_threeWayVerticalStack() {
        let node = PaneNode.split(axis: .vertical, children: [
            .leaf(paneID: p(1)), .leaf(paneID: p(2)), .leaf(paneID: p(3)),
        ])
        let frames = TerminalPaneTree.frames(for: node, in: bounds)
        XCTAssertEqual(frames.map(\.rect.height), [200, 200, 200])
        // Contiguous: each starts where the previous ended.
        XCTAssertEqual(frames[0].rect.minY, 0)
        XCTAssertEqual(frames[1].rect.minY, 200)
        XCTAssertEqual(frames[2].rect.minY, 400)
    }

    // MARK: - Enumeration

    func test_paneIDs_arePreOrderStable() {
        let node = PaneNode.split(axis: .horizontal, children: [
            .leaf(paneID: p(5)),
            .split(axis: .vertical, children: [.leaf(paneID: p(2)), .leaf(paneID: p(9))]),
            .leaf(paneID: p(1)),
        ])
        XCTAssertEqual(TerminalPaneTree.paneIDs(in: node), [p(5), p(2), p(9), p(1)])
    }

    func test_contains_findsLeavesAtAnyDepth() {
        let node = PaneNode.split(axis: .vertical, children: [
            .leaf(paneID: p(1)),
            .split(axis: .horizontal, children: [.leaf(paneID: p(8))]),
        ])
        XCTAssertTrue(TerminalPaneTree.contains(p(8), in: node))
        XCTAssertFalse(TerminalPaneTree.contains(p(99), in: node))
    }

    // MARK: - Key routing

    func test_keyRouting_prefersRequestedActiveWhenPresent() {
        let node = PaneNode.split(axis: .horizontal, children: [
            .leaf(paneID: p(1)), .leaf(paneID: p(2)),
        ])
        XCTAssertEqual(
            TerminalPaneTree.keyRoutingTarget(for: node, requestedActive: p(2)),
            p(2)
        )
    }

    func test_keyRouting_fallsBackToFirstWhenActiveMissing() {
        // Active pane closed (no longer in the tree) → keystrokes go to the
        // first pane, never stranded.
        let node = PaneNode.split(axis: .horizontal, children: [
            .leaf(paneID: p(3)), .leaf(paneID: p(4)),
        ])
        XCTAssertEqual(
            TerminalPaneTree.keyRoutingTarget(for: node, requestedActive: p(99)),
            p(3)
        )
        XCTAssertEqual(
            TerminalPaneTree.keyRoutingTarget(for: node, requestedActive: nil),
            p(3)
        )
    }

    func test_keyRouting_emptyTreeHasNoTarget() {
        let empty = PaneNode.split(axis: .horizontal, children: [])
        XCTAssertNil(TerminalPaneTree.keyRoutingTarget(for: empty, requestedActive: p(1)))
    }

    // MARK: - Click hit-testing

    func test_paneAtPoint_hitsCorrectLeaf() {
        let node = PaneNode.split(axis: .horizontal, children: [
            .leaf(paneID: p(1)),
            .split(axis: .vertical, children: [.leaf(paneID: p(2)), .leaf(paneID: p(3))]),
        ])
        XCTAssertEqual(TerminalPaneTree.pane(at: CGPoint(x: 100, y: 300), for: node, in: bounds), p(1))
        XCTAssertEqual(TerminalPaneTree.pane(at: CGPoint(x: 600, y: 100), for: node, in: bounds), p(2))
        XCTAssertEqual(TerminalPaneTree.pane(at: CGPoint(x: 600, y: 400), for: node, in: bounds), p(3))
    }

    func test_paneAtPoint_missesInDividerGutterAndOutsideBounds() {
        let node = PaneNode.split(axis: .horizontal, children: [
            .leaf(paneID: p(1)), .leaf(paneID: p(2)),
        ])
        // x in [395,405) is the gutter → no pane.
        XCTAssertNil(TerminalPaneTree.pane(at: CGPoint(x: 400, y: 300),
                                           for: node, in: bounds, dividerThickness: 10))
        // Outside bounds.
        XCTAssertNil(TerminalPaneTree.pane(at: CGPoint(x: 5000, y: 5000),
                                           for: node, in: bounds))
    }

    // MARK: - Identifiers

    func test_paneID_descriptionAndOrdering() {
        XCTAssertEqual(p(3).description, "%3")
        XCTAssertLessThan(p(1), p(2))
    }
}
