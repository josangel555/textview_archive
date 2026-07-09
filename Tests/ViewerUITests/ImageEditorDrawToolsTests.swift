import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ViewerUI
import ViewerCore

/// TSK-1083 / 1084 / 1089 — the curve / polygon / text tool COMMIT methods. The
/// raster ops (drawCurve, fill/strokePolygon) + the retained .text shape already
/// exist; these pin the tool→op / tool→shape wiring. The live drag / multi-click
/// gestures are the VM/AX render tail.
@MainActor
final class ImageEditorDrawToolsTests: XCTestCase {

    private func solidPNG(_ w: Int, _ h: Int) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let img = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func makeVM() throws -> ImageEditorViewModel {
        ImageEditorViewModel(ImageDocument(data: try solidPNG(40, 40)))
    }

    // MARK: - curve (1083)

    func test_drawCurve_commitsUndoableOp() throws {
        let vm = try makeVM()
        XCTAssertTrue(vm.drawCurveShape(fromNormalized: CGPoint(x: 0.1, y: 0.5),
                                        toNormalized: CGPoint(x: 0.9, y: 0.5)))
        XCTAssertTrue(vm.canUndo, "a curve is a single undoable op")
    }

    func test_drawCurve_zeroLength_isNoOp() throws {
        let vm = try makeVM()
        XCTAssertFalse(vm.drawCurveShape(fromNormalized: CGPoint(x: 0.5, y: 0.5),
                                         toNormalized: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertFalse(vm.canUndo)
    }

    // MARK: - polygon (1084)

    func test_polygon_accumulatesAndCommits() throws {
        let vm = try makeVM()
        vm.addPolygonPoint(CGPoint(x: 0.1, y: 0.1))
        vm.addPolygonPoint(CGPoint(x: 0.9, y: 0.1))
        vm.addPolygonPoint(CGPoint(x: 0.5, y: 0.9))
        XCTAssertEqual(vm.polygonPoints.count, 3)
        XCTAssertTrue(vm.commitPolygon())
        XCTAssertTrue(vm.canUndo)
        XCTAssertTrue(vm.polygonPoints.isEmpty, "committing clears the buffer")
    }

    func test_polygon_underThreePoints_refusedAndCleared() throws {
        let vm = try makeVM()
        vm.addPolygonPoint(CGPoint(x: 0.1, y: 0.1))
        vm.addPolygonPoint(CGPoint(x: 0.9, y: 0.1))
        XCTAssertFalse(vm.commitPolygon(), "a polygon needs ≥3 vertices")
        XCTAssertTrue(vm.polygonPoints.isEmpty)
        XCTAssertFalse(vm.canUndo)
    }

    func test_polygon_cancelClearsBuffer() throws {
        let vm = try makeVM()
        vm.addPolygonPoint(CGPoint(x: 0.2, y: 0.2))
        vm.cancelPolygon()
        XCTAssertTrue(vm.polygonPoints.isEmpty)
    }

    // MARK: - text (1089)

    func test_textTool_placesRetainedEditableShape() throws {
        let vm = try makeVM()
        let id = vm.placeTextShape(atNormalized: CGPoint(x: 0.2, y: 0.3), text: "Hello")
        let shape = vm.overlay.shape(id: id)
        XCTAssertEqual(shape?.kind, .text, "a retained .text vector shape (not a raster burn)")
        XCTAssertEqual(shape?.text, "Hello")
        XCTAssertEqual(vm.selectedShapeID, id, "the placed text is selected for immediate edit")
    }
}
