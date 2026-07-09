import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ViewerUI
import ViewerCore

/// TSK-1168 — the on-canvas vector-EDIT VM closures the `.editShapes` drag
/// gesture calls: pick-by-hit-test, resize-by-handle, and their undoability.
/// The live drag is the VM/AX tail; these are the host teeth.
@MainActor
final class ImageEditorVectorEditTests: XCTestCase {

    private func solidPNG(_ w: Int, _ h: Int) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let img = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func makeVM() throws -> ImageEditorViewModel {
        ImageEditorViewModel(ImageDocument(data: try solidPNG(32, 32)))
    }

    func test_selectShapeAtPoint_picksFrontMost_orClears() throws {
        let vm = try makeVM()
        _ = vm.addShape(VectorShape(kind: .rect, frame: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)))
        let front = vm.addShape(VectorShape(kind: .ellipse, frame: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)))
        vm.selectShape(at: CGPoint(x: 0.3, y: 0.3))
        XCTAssertEqual(vm.selectedShapeID, front, "the overlapping front shape is picked")
        // A miss clears the selection.
        vm.selectShape(at: CGPoint(x: 0.95, y: 0.95))
        XCTAssertNil(vm.selectedShapeID)
    }

    func test_resizeSelectedByHandle_growsTheFrame() throws {
        let vm = try makeVM()
        let id = vm.addShape(VectorShape(kind: .rect, frame: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)))
        vm.selectShape(id: id)
        XCTAssertTrue(vm.resizeSelectedShape(handle: .bottomRight, byX: 0.1, y: 0.1))
        let f = vm.selectedShape!.frame
        XCTAssertEqual(f.maxX, 0.6, accuracy: 1e-6, "bottom-right handle grew the right edge")
        XCTAssertEqual(f.maxY, 0.6, accuracy: 1e-6, "…and the bottom edge")
        XCTAssertEqual(f.minX, 0.2, accuracy: 1e-6, "the opposite corner stayed put")
    }

    func test_resizeByHandle_noSelection_isNoOp() throws {
        let vm = try makeVM()
        _ = vm.addShape(VectorShape(kind: .rect, frame: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)))
        vm.deselectShape()
        XCTAssertFalse(vm.resizeSelectedShape(handle: .bottomRight, byX: 0.1, y: 0.1))
    }

    func test_resizeByHandle_isUndoable() throws {
        let vm = try makeVM()
        let id = vm.addShape(VectorShape(kind: .rect, frame: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)))
        vm.selectShape(id: id)
        let before = vm.selectedShape!.frame
        _ = vm.resizeSelectedShape(handle: .bottomRight, byX: 0.1, y: 0.1)
        XCTAssertNotEqual(vm.selectedShape!.frame, before)
        XCTAssertTrue(vm.canUndo)
        vm.undo()
        XCTAssertEqual(vm.overlay.shape(id: id)!.frame, before, "undo restores the pre-resize frame")
    }
}
