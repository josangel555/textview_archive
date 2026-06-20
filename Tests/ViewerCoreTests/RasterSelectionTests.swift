import XCTest
@testable import ViewerCore

/// TSK-406: selection model (rect + freeform polygon) + selection-constrained
/// fill. Pure geometry — host-tested with teeth (any contains/clip bug breaks
/// these).
final class RasterSelectionTests: XCTestCase {

    // MARK: contains — rect (half-open)

    func test_rect_contains_isHalfOpen() {
        let sel = RasterSelection.rect(x: 2, y: 3, width: 4, height: 2)  // x∈[2,6), y∈[3,5)
        XCTAssertTrue(sel.contains(x: 2, y: 3), "top-left corner inside")
        XCTAssertTrue(sel.contains(x: 5, y: 4), "last in-bounds pixel inside")
        XCTAssertFalse(sel.contains(x: 6, y: 4), "far x edge is exclusive")
        XCTAssertFalse(sel.contains(x: 5, y: 5), "far y edge is exclusive")
        XCTAssertFalse(sel.contains(x: 1, y: 3), "left of region")
    }

    func test_rect_zeroSize_containsNothing() {
        XCTAssertFalse(RasterSelection.rect(x: 0, y: 0, width: 0, height: 5).contains(x: 0, y: 0))
        XCTAssertFalse(RasterSelection.rect(x: 0, y: 0, width: 5, height: 0).contains(x: 0, y: 0))
    }

    // MARK: contains — polygon (ray-cast, even-odd)

    func test_polygon_triangle_contains() {
        // Triangle (0,0)-(10,0)-(0,10): interior below the hypotenuse y < 10 - x.
        let tri = RasterSelection.polygon([
            RasterPoint(x: 0, y: 0), RasterPoint(x: 10, y: 0), RasterPoint(x: 0, y: 10),
        ])
        XCTAssertTrue(tri.contains(x: 1, y: 1), "well inside")
        XCTAssertTrue(tri.contains(x: 2, y: 2), "inside near hypotenuse")
        XCTAssertFalse(tri.contains(x: 8, y: 8), "outside, beyond the hypotenuse")
        XCTAssertFalse(tri.contains(x: 20, y: 20), "far outside")
    }

    func test_polygon_degenerate_isEmpty() {
        XCTAssertFalse(RasterSelection.polygon([]).contains(x: 0, y: 0))
        XCTAssertFalse(RasterSelection.polygon([RasterPoint(x: 0, y: 0),
                                                RasterPoint(x: 1, y: 1)]).contains(x: 0, y: 0))
    }

    // MARK: fill(_:in:) — selection-constrained paint

    func test_fill_rect_paintsOnlyInside() {
        var canvas = RasterCanvas(width: 6, height: 6, fill: .white)
        canvas.fill(.red, in: .rect(x: 1, y: 1, width: 2, height: 2))
        XCTAssertEqual(canvas.pixel(x: 1, y: 1), .red, "inside the selection")
        XCTAssertEqual(canvas.pixel(x: 2, y: 2), .red, "inside the selection")
        XCTAssertEqual(canvas.pixel(x: 3, y: 3), .white, "outside the selection is untouched")
        XCTAssertEqual(canvas.pixel(x: 0, y: 0), .white, "outside the selection is untouched")
    }

    func test_fill_rect_clampsToCanvasBounds() {
        var canvas = RasterCanvas(width: 4, height: 4, fill: .white)
        // Selection spills past the right/bottom edges — must clamp, not crash.
        canvas.fill(.blue, in: .rect(x: 2, y: 2, width: 10, height: 10))
        XCTAssertEqual(canvas.pixel(x: 3, y: 3), .blue, "in-bounds part filled")
        XCTAssertEqual(canvas.pixel(x: 1, y: 1), .white, "outside the selection untouched")
    }

    func test_fill_polygon_paintsInterior() {
        var canvas = RasterCanvas(width: 12, height: 12, fill: .white)
        canvas.fill(.green, in: .polygon([
            RasterPoint(x: 0, y: 0), RasterPoint(x: 10, y: 0), RasterPoint(x: 0, y: 10),
        ]))
        XCTAssertEqual(canvas.pixel(x: 1, y: 1), .green, "polygon interior filled")
        XCTAssertEqual(canvas.pixel(x: 8, y: 8), .white, "outside the polygon untouched")
    }
}
