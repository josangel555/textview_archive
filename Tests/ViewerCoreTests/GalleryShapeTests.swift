import XCTest
import CoreGraphics
@testable import ViewerCore

/// TSK-1085 — the Win7 gallery-shape vertex geometry.
final class GalleryShapeTests: XCTestCase {

    private let rect = CGRect(x: 10, y: 20, width: 100, height: 60)

    func test_vertexCounts() {
        XCTAssertEqual(GalleryShape.triangle.vertices(in: rect).count, 3)
        XCTAssertEqual(GalleryShape.rightTriangle.vertices(in: rect).count, 3)
        XCTAssertEqual(GalleryShape.diamond.vertices(in: rect).count, 4)
        XCTAssertEqual(GalleryShape.pentagon.vertices(in: rect).count, 5)
        XCTAssertEqual(GalleryShape.hexagon.vertices(in: rect).count, 6)
        XCTAssertEqual(GalleryShape.star5.vertices(in: rect).count, 10, "5 tips + 5 inner")
        XCTAssertEqual(GalleryShape.star6.vertices(in: rect).count, 12)
        XCTAssertEqual(GalleryShape.arrowRight.vertices(in: rect).count, 7, "block arrow")
    }

    func test_allVerticesWithinBounds() {
        // A shape must fit its bounding rect (with a hair of float tolerance).
        for shape in GalleryShape.allCases {
            for v in shape.vertices(in: rect) {
                XCTAssertGreaterThanOrEqual(v.x, rect.minX - 0.001, "\(shape) x underflow")
                XCTAssertLessThanOrEqual(v.x, rect.maxX + 0.001, "\(shape) x overflow")
                XCTAssertGreaterThanOrEqual(v.y, rect.minY - 0.001, "\(shape) y underflow")
                XCTAssertLessThanOrEqual(v.y, rect.maxY + 0.001, "\(shape) y overflow")
            }
        }
    }

    func test_triangle_apexTopCentered() {
        let v = GalleryShape.triangle.vertices(in: rect)
        XCTAssertEqual(v[0].x, rect.midX, accuracy: 0.001, "apex is horizontally centered")
        XCTAssertEqual(v[0].y, rect.minY, accuracy: 0.001, "apex at the top")
        // Base corners at the bottom.
        XCTAssertEqual(v[1].y, rect.maxY, accuracy: 0.001)
        XCTAssertEqual(v[2].y, rect.maxY, accuracy: 0.001)
    }

    func test_diamond_isTheFourMidpoints() {
        let v = GalleryShape.diamond.vertices(in: rect)
        XCTAssertEqual(v[0], CGPoint(x: rect.midX, y: rect.minY))   // top
        XCTAssertEqual(v[1], CGPoint(x: rect.maxX, y: rect.midY))   // right
        XCTAssertEqual(v[2], CGPoint(x: rect.midX, y: rect.maxY))   // bottom
        XCTAssertEqual(v[3], CGPoint(x: rect.minX, y: rect.midY))   // left
    }

    func test_star_alternatesOuterInnerRadius() {
        // Outer tips are farther from center than inner vertices.
        let v = GalleryShape.star5.vertices(in: rect)
        let cx = rect.midX, cy = rect.midY
        func dist(_ p: CGPoint) -> Double { hypot(p.x - cx, p.y - cy) }
        // even indices = outer tips, odd = inner.
        XCTAssertGreaterThan(dist(v[0]), dist(v[1]))
        XCTAssertGreaterThan(dist(v[2]), dist(v[3]))
    }

    func test_arrowRight_pointsRight() {
        // The arrow tip (max x) is at the vertical center.
        let v = GalleryShape.arrowRight.vertices(in: rect)
        let tip = v.max { $0.x < $1.x }!
        XCTAssertEqual(tip.x, rect.maxX, accuracy: 0.001)
        XCTAssertEqual(tip.y, rect.midY, accuracy: 0.001)
    }

    func test_allShapes_produceAClosablePolygon() {
        // At least 3 distinct points (a fillable polygon), no NaN.
        for shape in GalleryShape.allCases {
            let v = shape.vertices(in: rect)
            XCTAssertGreaterThanOrEqual(v.count, 3, "\(shape) needs ≥3 points")
            XCTAssertTrue(v.allSatisfy { $0.x.isFinite && $0.y.isFinite }, "\(shape) has NaN/inf")
        }
    }
}
