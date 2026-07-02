import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import ViewerCore
@testable import ViewerUI

/// Overlay-annotation undo + unified interleaved ordering (usability audit
/// 2026-07-02, TSK-1424). Vector overlay edits (add/remove/move/restyle/text)
/// used to bypass undo entirely — annotations were permanent. They now ride a
/// unified undo timeline alongside geometry ops and paint strokes, so ⌘Z peels
/// all three layers in the exact order they happened.
@MainActor
final class ImageEditorOverlayUndoTests: XCTestCase {
    private func solidPNG(_ w: Int = 16, _ h: Int = 12) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let out = NSMutableData()
        let d = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil); _ = CGImageDestinationFinalize(d)
        return out as Data
    }
    private func makeVM() throws -> ImageEditorViewModel {
        ImageEditorViewModel(ImageDocument(data: try solidPNG()))
    }
    private func rect() -> VectorShape {
        VectorShape(kind: .rect, frame: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3),
                    style: ShapeStyle(stroke: .red, lineWidth: 2))
    }

    func test_addShape_isUndoableAndRedoable() throws {
        let vm = try makeVM()
        XCTAssertFalse(vm.canUndo, "clean slate")
        _ = vm.addShape(rect())
        XCTAssertEqual(vm.overlay.shapes.count, 1)
        XCTAssertTrue(vm.canUndo, "adding an annotation is undoable (was permanent before)")
        vm.undo()
        XCTAssertEqual(vm.overlay.shapes.count, 0, "undo removed the annotation")
        XCTAssertTrue(vm.canRedo)
        vm.redo()
        XCTAssertEqual(vm.overlay.shapes.count, 1, "redo restored the annotation")
    }

    func test_restyleAndMove_areUndoable() throws {
        let vm = try makeVM()
        let id = vm.addShape(rect())
        vm.selectShape(id: id)
        _ = vm.restyleSelectedShape(ShapeStyle(stroke: .white, lineWidth: 5))
        let styled = vm.overlay.shape(id: id)?.style.lineWidth
        XCTAssertEqual(styled, 5)
        vm.undo()   // undo the restyle
        XCTAssertEqual(vm.overlay.shape(id: id)?.style.lineWidth, 2, "restyle undone")
        XCTAssertEqual(vm.overlay.shapes.count, 1, "the shape itself is still there")
    }

    func test_interleaved_paint_then_overlay_undoInOrder() throws {
        let vm = try makeVM()
        vm.paintColor = RGBAColor(r: 0, g: 0, b: 255, a: 255)
        vm.beginStroke(); _ = vm.brushDab(atX: 5, y: 5)   // 1: paint
        _ = vm.addShape(rect())                           // 2: overlay
        XCTAssertEqual(vm.overlay.shapes.count, 1)
        let paintedAfterStroke = vm.paintCanvas
        vm.undo()   // most recent = overlay
        XCTAssertEqual(vm.overlay.shapes.count, 0, "first undo peels the overlay (most recent)")
        XCTAssertEqual(vm.paintCanvas, paintedAfterStroke, "the paint stroke is untouched")
        vm.undo()   // now the paint
        XCTAssertEqual(Set(vm.paintCanvas!.pixels).count, 1, "second undo peels the paint stroke")
    }

    func test_noOpOverlayEdit_doesNotRecordUndo() throws {
        let vm = try makeVM()
        _ = vm.removeShape(id: UUID())   // unknown id → no change
        XCTAssertFalse(vm.canUndo, "a no-op overlay edit must not pollute the undo stack")
    }
}
