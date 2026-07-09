import Testing
import CoreGraphics
@testable import ViewerCore

/// TSK-1574 — the freeform gallery members (heart / lightning / speech callout).
/// They're curve-based but returned as dense polygon rings for the existing
/// rasterizer; these teeth pin that each yields a valid, in-bounds ring.
struct GalleryShapeFreeformTests {

    private let rect = CGRect(x: 10, y: 20, width: 100, height: 80)

    @Test(arguments: [GalleryShape.heart, .lightning, .speechCallout])
    func freeformYieldsValidRing(shape: GalleryShape) {
        let pts = shape.vertices(in: rect)
        #expect(pts.count >= 3, "a fillable ring needs ≥3 vertices")
        // Every vertex sits within the bounding rect (with a hair of tolerance).
        for pt in pts {
            #expect(pt.x >= rect.minX - 0.001 && pt.x <= rect.maxX + 0.001)
            #expect(pt.y >= rect.minY - 0.001 && pt.y <= rect.maxY + 0.001)
        }
    }

    @Test func freeformMembersAreInAllCases() {
        #expect(GalleryShape.allCases.contains(.heart))
        #expect(GalleryShape.allCases.contains(.lightning))
        #expect(GalleryShape.allCases.contains(.speechCallout))
    }

    @Test func heartIsDeterministic_andSpansTheBox() {
        let a = GalleryShape.heart.vertices(in: rect)
        let b = GalleryShape.heart.vertices(in: rect)
        #expect(a == b, "pure — same rect ⇒ same ring")
        // The heart should actually use most of the box, not collapse to a dot.
        let xs = a.map(\.x), ys = a.map(\.y)
        #expect((xs.max()! - xs.min()!) > rect.width * 0.8)
        #expect((ys.max()! - ys.min()!) > rect.height * 0.8)
    }

    @Test func heartCuspIsAtTop() {
        // Image space is y-down; the heart's two lobes are at the top, so the
        // topmost sampled points should exist near y = rect.minY.
        let pts = GalleryShape.heart.vertices(in: rect)
        #expect(pts.map(\.y).min()! < rect.minY + rect.height * 0.15)
    }
}
