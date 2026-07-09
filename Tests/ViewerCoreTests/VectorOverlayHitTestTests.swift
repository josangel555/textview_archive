import Testing
import CoreGraphics
@testable import ViewerCore

/// TSK-1168 — `VectorOverlay.hitTest`: which placed shape a click selects.
/// Closed shapes by frame containment, open shapes (line/arrow) by segment
/// distance, front-most wins. Host teeth for the on-canvas pick.
struct VectorOverlayHitTestTests {

    @Test func closedShape_hitByFrameContainment() {
        var o = VectorOverlay()
        let id = o.add(VectorShape(kind: .rect, frame: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)))
        #expect(o.hitTest(CGPoint(x: 0.2, y: 0.2)) == id)      // inside
        #expect(o.hitTest(CGPoint(x: 0.8, y: 0.8)) == nil)     // outside → miss
    }

    @Test func frontMostShapeWins_whenOverlapping() {
        var o = VectorOverlay()
        _ = o.add(VectorShape(kind: .rect, frame: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)))     // back
        let front = o.add(VectorShape(kind: .ellipse, frame: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3))) // front
        // A point inside BOTH → the front-most (last-drawn) shape is selected.
        #expect(o.hitTest(CGPoint(x: 0.3, y: 0.3)) == front)
    }

    @Test func line_hitByProximityToSegment() {
        var o = VectorOverlay()
        // A line from (0.1,0.1) to (0.9,0.1) — horizontal.
        let id = o.add(VectorShape(kind: .line, frame: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.0)))
        #expect(o.hitTest(CGPoint(x: 0.5, y: 0.105), lineTolerance: 0.02) == id)   // near the line
        #expect(o.hitTest(CGPoint(x: 0.5, y: 0.4), lineTolerance: 0.02) == nil)    // far from the line
    }

    @Test func emptyOverlay_missesEverything() {
        #expect(VectorOverlay().hitTest(CGPoint(x: 0.5, y: 0.5)) == nil)
    }

    @Test func segmentDistance_isPerpendicularAndEndpointClamped() {
        // Perpendicular distance to a horizontal segment.
        let d = VectorOverlay.segmentDistance(
            CGPoint(x: 0.5, y: 0.2), CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0))
        #expect(abs(d - 0.2) < 1e-9)
        // Beyond an endpoint → distance to that endpoint.
        let d2 = VectorOverlay.segmentDistance(
            CGPoint(x: 2, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0))
        #expect(abs(d2 - 1.0) < 1e-9)
    }
}
