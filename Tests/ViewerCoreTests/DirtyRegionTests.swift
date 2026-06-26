import CoreGraphics
import Testing
@testable import ViewerCore

/// TSK-1052 — the dirty-rect accumulator model: union + clamp + per-op math.
struct DirtyRegionTests {

    @Test func startsClean() {
        let r = DirtyRegion(width: 100, height: 80)
        #expect(r.isClean)
        #expect(r.bounds == nil)
    }

    @Test func addSetsClampedBounds() {
        var r = DirtyRegion(width: 100, height: 100)
        r.add(CGRect(x: 10, y: 20, width: 5, height: 5))
        #expect(r.bounds == CGRect(x: 10, y: 20, width: 5, height: 5))
        #expect(!r.isClean)
    }

    @Test func addUnionsMultiple() {
        var r = DirtyRegion(width: 100, height: 100)
        r.add(CGRect(x: 10, y: 10, width: 5, height: 5))   // → x[10,15] y[10,15]
        r.add(CGRect(x: 30, y: 40, width: 5, height: 5))   // → x[30,35] y[40,45]
        #expect(r.bounds == CGRect(x: 10, y: 10, width: 25, height: 35))
    }

    @Test func addClampsToCanvas() {
        var r = DirtyRegion(width: 100, height: 100)
        r.add(CGRect(x: 90, y: 90, width: 50, height: 50))   // spills past the edge
        #expect(r.bounds == CGRect(x: 90, y: 90, width: 10, height: 10))
    }

    @Test func addFullyOutsideIsIgnored() {
        var r = DirtyRegion(width: 100, height: 100)
        r.add(CGRect(x: 200, y: 200, width: 10, height: 10))
        #expect(r.isClean)
    }

    @Test func markAllCoversCanvas() {
        var r = DirtyRegion(width: 64, height: 48)
        r.markAll()
        #expect(r.bounds == CGRect(x: 0, y: 0, width: 64, height: 48))
    }

    @Test func consumeReturnsThenResets() {
        var r = DirtyRegion(width: 100, height: 100)
        r.add(CGRect(x: 5, y: 5, width: 10, height: 10))
        #expect(r.consume() == CGRect(x: 5, y: 5, width: 10, height: 10))
        #expect(r.isClean)            // reset after consume
        #expect(r.consume() == nil)   // nothing left
    }

    @Test func degenerateCanvasStaysClean() {
        var r = DirtyRegion(width: 0, height: 0)
        r.add(CGRect(x: 0, y: 0, width: 10, height: 10))
        r.markAll()
        #expect(r.isClean)
    }

    @Test func dabFootprintMatchesBrush() {
        #expect(DirtyRegion.dab(cx: 50, cy: 50, radius: 3) == CGRect(x: 47, y: 47, width: 7, height: 7))
        #expect(DirtyRegion.dab(cx: 8, cy: 9, radius: 0) == CGRect(x: 8, y: 9, width: 1, height: 1))
    }

    @Test func strokeUnionsEndpointDabs() {
        // dab(0,0,2)=(-2,-2,5,5) ∪ dab(10,0,2)=(8,-2,5,5) → (-2,-2,15,5)
        #expect(DirtyRegion.stroke(x0: 0, y0: 0, x1: 10, y1: 0, radius: 2)
                == CGRect(x: -2, y: -2, width: 15, height: 5))
    }
}
