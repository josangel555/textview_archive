import Testing
import CoreGraphics
@testable import ViewerCore

/// TSK-1168 — the pure selection-handle geometry + resize math that drives the
/// on-canvas shape-edit tool. Host teeth so a regression in move/resize/hit-test
/// fails here, not just on the VM (where the live drag is validated).
struct ShapeDragGeometryHandleTests {

    private let frame = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)  // maxX 0.6, maxY 0.5

    private func near(_ p: CGPoint?, _ x: CGFloat, _ y: CGFloat) -> Bool {
        guard let p else { return false }
        return abs(p.x - x) < 1e-9 && abs(p.y - y) < 1e-9
    }

    @Test func handlePoints_areTheEightBoxAnchors() {
        let pts = Dictionary(uniqueKeysWithValues:
            ShapeDragGeometry.handlePoints(for: frame).map { ($0.handle, $0.point) })
        #expect(near(pts[.topLeft], 0.2, 0.3))
        #expect(near(pts[.topRight], 0.6, 0.3))
        #expect(near(pts[.bottomLeft], 0.2, 0.5))
        #expect(near(pts[.bottomRight], 0.6, 0.5))
        #expect(near(pts[.top], 0.4, 0.3))
        #expect(near(pts[.bottom], 0.4, 0.5))
        #expect(near(pts[.left], 0.2, 0.4))
        #expect(near(pts[.right], 0.6, 0.4))
        #expect(pts.count == 8)
    }

    @Test func handleHitTest_nearAHandle_returnsIt_elseNil() {
        // A point right on the top-left corner.
        #expect(ShapeDragGeometry.handleHitTest(CGPoint(x: 0.205, y: 0.305), in: frame, tolerance: 0.03) == .topLeft)
        // The frame centre is far from every handle.
        #expect(ShapeDragGeometry.handleHitTest(CGPoint(x: 0.4, y: 0.4), in: frame, tolerance: 0.03) == nil)
    }

    @Test func resize_bottomRight_movesBothEdges() {
        let r = ShapeDragGeometry.resizedFrame(frame, handle: .bottomRight, byX: 0.1, y: 0.1)
        #expect(abs(r.minX - 0.2) < 1e-9)      // left edge unchanged
        #expect(abs(r.minY - 0.3) < 1e-9)      // top edge unchanged
        #expect(abs(r.maxX - 0.7) < 1e-9)      // right edge +0.1
        #expect(abs(r.maxY - 0.6) < 1e-9)      // bottom edge +0.1
    }

    @Test func resize_leftEdge_movesOnlyLeft() {
        let r = ShapeDragGeometry.resizedFrame(frame, handle: .left, byX: 0.1, y: 0.05)
        #expect(abs(r.minX - 0.3) < 1e-9)      // left edge +0.1
        #expect(abs(r.maxX - 0.6) < 1e-9)      // right unchanged
        #expect(abs(r.minY - 0.3) < 1e-9)      // top unchanged (dy ignored — left owns no vertical edge)
        #expect(abs(r.maxY - 0.5) < 1e-9)
    }

    @Test func resize_clampsToUnitSquare() {
        // Drag the bottom-right way past the edge → clamped to 1.0.
        let r = ShapeDragGeometry.resizedFrame(frame, handle: .bottomRight, byX: 5, y: 5)
        #expect(r.maxX <= 1.0 + 1e-9)
        #expect(r.maxY <= 1.0 + 1e-9)
    }

    @Test func resize_enforcesMinSize() {
        // Collapse the box by dragging the right edge far left → floored at minSize.
        let r = ShapeDragGeometry.resizedFrame(frame, handle: .right, byX: -1, y: 0, minSize: 0.02)
        #expect(r.width >= 0.02 - 1e-9)
    }

    @Test func resize_flipPastOpposite_standardizes() {
        // Drag the right edge left past the left edge → a standardized (non-negative) frame.
        let r = ShapeDragGeometry.resizedFrame(frame, handle: .right, byX: -0.5, y: 0)
        #expect(r.width >= 0)
        #expect(r.height >= 0)
    }
}
