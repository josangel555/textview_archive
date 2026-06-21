import XCTest
import CoreGraphics
@testable import ViewerCore

/// TSK-1101 — teeth for the paint gesture's view-point → canvas-pixel mapping.
/// Pure geometry; the `DragGesture` + live render are the VM-validated remainder.
final class PaintCoordinateMappingTests: XCTestCase {

    private let displayed = CGRect(x: 10, y: 20, width: 100, height: 200)

    func test_topLeftCorner_isPixelZero() {
        let p = PaintCoordinateMapping.canvasPixel(
            CGPoint(x: 10, y: 20), in: displayed, imageWidth: 50, imageHeight: 80)
        XCTAssertEqual(p?.x, 0)
        XCTAssertEqual(p?.y, 0)
    }

    func test_center_mapsToMidPixel() {
        let p = PaintCoordinateMapping.canvasPixel(
            CGPoint(x: 60, y: 120), in: displayed, imageWidth: 50, imageHeight: 80)
        XCTAssertEqual(p?.x, 25)
        XCTAssertEqual(p?.y, 40)
    }

    func test_nearBottomRight_clampsToLastPixel() {
        let p = PaintCoordinateMapping.canvasPixel(
            CGPoint(x: 109, y: 219), in: displayed, imageWidth: 50, imageHeight: 80)
        XCTAssertEqual(p?.x, 49)
        XCTAssertEqual(p?.y, 79)
    }

    func test_outsideRect_returnsNil() {
        XCTAssertNil(PaintCoordinateMapping.canvasPixel(
            CGPoint(x: 5, y: 5), in: displayed, imageWidth: 50, imageHeight: 80),
            "a point above/left of the image paints nothing")
        XCTAssertNil(PaintCoordinateMapping.canvasPixel(
            CGPoint(x: 300, y: 300), in: displayed, imageWidth: 50, imageHeight: 80),
            "a point past the image paints nothing")
    }

    func test_degenerateInputs_returnNil() {
        XCTAssertNil(PaintCoordinateMapping.canvasPixel(
            CGPoint(x: 50, y: 50), in: displayed, imageWidth: 0, imageHeight: 80))
        XCTAssertNil(PaintCoordinateMapping.canvasPixel(
            CGPoint(x: 50, y: 50), in: .zero, imageWidth: 50, imageHeight: 80))
    }
}
