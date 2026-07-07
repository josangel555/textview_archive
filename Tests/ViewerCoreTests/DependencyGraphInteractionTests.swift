import XCTest
import CoreGraphics
@testable import ViewerCore

/// TSK-1470 — the dep-graph interaction math (hit-test, zoom/pan, cap).
final class DependencyGraphInteractionTests: XCTestCase {

    private func pos(_ id: String, _ x: CGFloat, _ y: CGFloat) -> DependencyGraphLayout.Position {
        .init(id: id, point: CGPoint(x: x, y: y))
    }

    // MARK: hit-test

    func test_nodeAtPoint_insideRadius_hits() {
        let positions = [pos("a", 100, 100), pos("b", 300, 100)]
        XCTAssertEqual(DependencyGraphInteraction.node(
            at: CGPoint(x: 105, y: 96), positions: positions, radius: 12), "a")
    }

    func test_nodeAtPoint_emptyCanvas_misses() {
        let positions = [pos("a", 100, 100)]
        XCTAssertNil(DependencyGraphInteraction.node(
            at: CGPoint(x: 200, y: 200), positions: positions, radius: 12))
        // Just outside the disc misses too.
        XCTAssertNil(DependencyGraphInteraction.node(
            at: CGPoint(x: 113, y: 100), positions: positions, radius: 12))
    }

    func test_nodeAtPoint_overlappingDiscs_nearestWins() {
        // Two crowded nodes 10pt apart with radius 12 — the click at 4pt from
        // "a" and 6pt from "b" picks "a" deterministically.
        let positions = [pos("a", 100, 100), pos("b", 110, 100)]
        XCTAssertEqual(DependencyGraphInteraction.node(
            at: CGPoint(x: 104, y: 100), positions: positions, radius: 12), "a")
        XCTAssertEqual(DependencyGraphInteraction.node(
            at: CGPoint(x: 107, y: 100), positions: positions, radius: 12), "b")
    }

    // MARK: transform

    func test_transform_roundTrip() {
        let t = DependencyGraphInteraction.Transform(scale: 2, offset: CGPoint(x: 30, y: -10))
        let model = CGPoint(x: 55, y: 70)
        let back = t.toModel(t.toView(model))
        XCTAssertEqual(back.x, model.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, model.y, accuracy: 1e-9)
    }

    func test_zoom_keepsAnchorFixed() {
        // The pinch contract: the content under the cursor must not move.
        let t = DependencyGraphInteraction.Transform(scale: 1, offset: .zero)
        let anchor = CGPoint(x: 250, y: 180)
        let modelUnderAnchor = t.toModel(anchor)
        let zoomed = t.zoomed(by: 1.8, around: anchor)
        let after = zoomed.toView(modelUnderAnchor)
        XCTAssertEqual(after.x, anchor.x, accuracy: 1e-6)
        XCTAssertEqual(after.y, anchor.y, accuracy: 1e-6)
        XCTAssertEqual(zoomed.scale, 1.8, accuracy: 1e-9)
    }

    func test_zoom_clampsToBounds_offsetOnlyMovesWithRealChange() {
        let t = DependencyGraphInteraction.Transform(scale: 4.0, offset: CGPoint(x: 7, y: 7))
        // Already at max: zooming in further is a NO-OP (offset untouched).
        let still = t.zoomed(by: 2.0, around: CGPoint(x: 100, y: 100))
        XCTAssertEqual(still, t, "clamped zoom must not drift the offset")
        // Zooming way out clamps at min.
        let out = t.zoomed(by: 0.001, around: CGPoint(x: 100, y: 100))
        XCTAssertEqual(out.scale, DependencyGraphInteraction.Transform.minScale)
    }

    func test_pan_movesOffsetOnly() {
        let t = DependencyGraphInteraction.Transform(scale: 2, offset: CGPoint(x: 10, y: 10))
        let panned = t.panned(by: CGPoint(x: -5, y: 20))
        XCTAssertEqual(panned.scale, 2)
        XCTAssertEqual(panned.offset, CGPoint(x: 5, y: 30))
    }

    func test_fitting_centersAndScalesContent() {
        let content = CGRect(x: 0, y: 0, width: 100, height: 50)
        let viewport = CGRect(x: 0, y: 0, width: 440, height: 240)
        let t = DependencyGraphInteraction.Transform.fitting(
            content: content, in: viewport, inset: 20)
        // Limiting axis: width → (440-40)/100 = 4.0 vs height (240-40)/50 = 4.0
        // → scale 4 (also the max). The content center maps to the viewport center.
        XCTAssertEqual(t.scale, 4.0, accuracy: 1e-9)
        let center = t.toView(CGPoint(x: content.midX, y: content.midY))
        XCTAssertEqual(center.x, viewport.midX, accuracy: 1e-6)
        XCTAssertEqual(center.y, viewport.midY, accuracy: 1e-6)
    }

    func test_fitting_degenerateContent_isIdentity() {
        XCTAssertEqual(
            DependencyGraphInteraction.Transform.fitting(
                content: .zero, in: CGRect(x: 0, y: 0, width: 100, height: 100)),
            .identity)
    }

    // MARK: hit-test under transform (the composed click path)

    func test_clickThroughTransform_hitsTheModelNode() {
        // The view receives a click in VIEW space; converting through
        // toModel must hit the node the user actually clicked.
        let positions = [pos("a", 100, 100)]
        let t = DependencyGraphInteraction.Transform(scale: 2, offset: CGPoint(x: 50, y: 0))
        let viewClick = t.toView(CGPoint(x: 103, y: 98))  // on a's disc, model space
        let hit = DependencyGraphInteraction.node(
            at: t.toModel(viewClick), positions: positions, radius: 12)
        XCTAssertEqual(hit, "a")
    }

    // MARK: cap

    func test_nodeCap() {
        XCTAssertFalse(DependencyGraphInteraction.exceedsCap(nodeCount: 300))
        XCTAssertTrue(DependencyGraphInteraction.exceedsCap(nodeCount: 301))
    }
}
