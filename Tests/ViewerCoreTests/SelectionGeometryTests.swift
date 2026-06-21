import XCTest
import CoreGraphics
@testable import ViewerCore

/// TSK-1063 — teeth for the rectangular-marquee geometry (drag → canvas-pixel
/// selection, and back to a view rect). Pure; the gesture + overlay are VM-validated.
final class SelectionGeometryTests: XCTestCase {

    private let displayed = CGRect(x: 10, y: 20, width: 100, height: 200)

    func test_selectionRect_mapsDragToPixels() {
        let sel = SelectionGeometry.selectionRect(
            from: CGPoint(x: 35, y: 70), to: CGPoint(x: 85, y: 170),
            in: displayed, imageWidth: 50, imageHeight: 80)
        XCTAssertEqual(sel, .rect(x: 12, y: 20, width: 25, height: 40))
    }

    func test_selectionRect_reversedDrag_sameSelection() {
        let sel = SelectionGeometry.selectionRect(
            from: CGPoint(x: 85, y: 170), to: CGPoint(x: 35, y: 70),
            in: displayed, imageWidth: 50, imageHeight: 80)
        XCTAssertEqual(sel, .rect(x: 12, y: 20, width: 25, height: 40))
    }

    func test_selectionRect_clampsOffEdgeDrag() {
        let sel = SelectionGeometry.selectionRect(
            from: CGPoint(x: -100, y: -100), to: CGPoint(x: 500, y: 500),
            in: displayed, imageWidth: 50, imageHeight: 80)
        XCTAssertEqual(sel, .rect(x: 0, y: 0, width: 50, height: 80), "clamps to the whole image")
    }

    func test_selectionRect_zeroSize_isNil() {
        XCTAssertNil(SelectionGeometry.selectionRect(
            from: CGPoint(x: 50, y: 50), to: CGPoint(x: 50, y: 50),
            in: displayed, imageWidth: 50, imageHeight: 80))
    }

    func test_viewRect_inverseOfSelection() {
        let r = SelectionGeometry.viewRect(
            .rect(x: 12, y: 20, width: 25, height: 40),
            in: displayed, imageWidth: 50, imageHeight: 80)
        XCTAssertEqual(r?.minX ?? -1, 34, accuracy: 0.001)
        XCTAssertEqual(r?.minY ?? -1, 70, accuracy: 0.001)
        XCTAssertEqual(r?.width ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(r?.height ?? -1, 100, accuracy: 0.001)
    }

    // MARK: - lasso polygon (TSK-1064)

    func test_polygon_mapsViewPointsToPixels() {
        let poly = SelectionGeometry.polygon(
            from: [CGPoint(x: 10, y: 20), CGPoint(x: 110, y: 20), CGPoint(x: 60, y: 220)],
            in: displayed, imageWidth: 50, imageHeight: 80)
        guard case let .polygon(pts) = poly else { return XCTFail("expected a polygon") }
        XCTAssertEqual(pts.count, 3)
        XCTAssertEqual(pts[0], RasterPoint(x: 0, y: 0), "top-left view point → pixel (0,0)")
        XCTAssertEqual(pts[1], RasterPoint(x: 49, y: 0), "top-right clamps to the last column")
    }

    func test_polygon_fewerThan3Points_isNil() {
        XCTAssertNil(SelectionGeometry.polygon(
            from: [CGPoint(x: 10, y: 20), CGPoint(x: 110, y: 20)],
            in: displayed, imageWidth: 50, imageHeight: 80))
    }

    func test_viewPoints_polygonOnly() {
        let pts = SelectionGeometry.viewPoints(
            of: .polygon([RasterPoint(x: 0, y: 0), RasterPoint(x: 49, y: 0), RasterPoint(x: 0, y: 79)]),
            in: displayed, imageWidth: 50, imageHeight: 80)
        XCTAssertEqual(pts?.count, 3)
        XCTAssertNil(SelectionGeometry.viewPoints(
            of: .rect(x: 0, y: 0, width: 4, height: 4),
            in: displayed, imageWidth: 50, imageHeight: 80), "rect → nil (use viewRect)")
    }
}
