import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import ViewerCore

@testable import ViewerUI

/// Paint-stroke undo (usability audit 2026-07-02) — brush/eraser/bucket
/// strokes were NOT undoable (the destructive paint session lived outside the
/// op-based undo stack). These pin the VM-level behavior: a stroke bracketed
/// by `beginStroke()` is undoable, restores the exact pre-stroke canvas,
/// redoes, and reports canUndo/canRedo.
@MainActor
final class ImageEditorPaintUndoTests: XCTestCase {

    private func solidPNG(width: Int = 12, height: Int = 10) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func makeVM() throws -> ImageEditorViewModel {
        ImageEditorViewModel(ImageDocument(data: try solidPNG()))
    }

    func test_paint_stroke_is_undoable_and_restores_exact_canvas() throws {
        let vm = try makeVM()
        vm.paintColor = RGBAColor(r: 255, g: 0, b: 0, a: 255)

        vm.beginStroke()                         // snapshot the clean baseline
        let before = vm.paintCanvas
        XCTAssertNotNil(before, "beginStroke bakes the session")
        let n = vm.brushDab(atX: 5, y: 5)        // paint
        XCTAssertGreaterThan(n, 0, "the dab wrote pixels")
        XCTAssertNotEqual(vm.paintCanvas, before, "canvas changed after painting")
        XCTAssertTrue(vm.canUndo, "a paint stroke is now undoable")

        XCTAssertTrue(vm.undoPaint(), "undo the stroke")
        XCTAssertEqual(vm.paintCanvas, before, "canvas restored to the exact pre-stroke pixels")
        XCTAssertFalse(vm.canUndoPaint, "no more paint undo")
        XCTAssertTrue(vm.canRedoPaint, "the undone stroke can be redone")
    }

    func test_multiple_strokes_undo_in_reverse_order_then_redo() throws {
        let vm = try makeVM()
        vm.paintColor = RGBAColor(r: 0, g: 0, b: 255, a: 255)

        vm.beginStroke(); _ = vm.brushDab(atX: 2, y: 2)
        let afterFirst = vm.paintCanvas
        vm.beginStroke(); _ = vm.brushDab(atX: 8, y: 8)
        let afterSecond = vm.paintCanvas
        XCTAssertNotEqual(afterFirst, afterSecond)

        XCTAssertTrue(vm.undoPaint())            // undo 2nd
        XCTAssertEqual(vm.paintCanvas, afterFirst, "back to after-first")
        XCTAssertTrue(vm.undoPaint())            // undo 1st
        XCTAssertNotEqual(vm.paintCanvas, afterFirst, "back to clean baseline")
        XCTAssertFalse(vm.canUndoPaint)

        XCTAssertTrue(vm.redoPaint())            // redo 1st
        XCTAssertEqual(vm.paintCanvas, afterFirst)
        XCTAssertTrue(vm.redoPaint())            // redo 2nd
        XCTAssertEqual(vm.paintCanvas, afterSecond)
    }

    func test_main_undo_prefers_paint_while_paint_history_exists() throws {
        let vm = try makeVM()
        vm.beginStroke(); _ = vm.brushDab(atX: 4, y: 4)
        let painted = vm.paintCanvas
        XCTAssertTrue(vm.canUndo)
        vm.undo()                                // routes to undoPaint
        XCTAssertNotEqual(vm.paintCanvas, painted, "main undo() undid the paint stroke")
    }

    func test_a_new_stroke_clears_the_redo_branch() throws {
        let vm = try makeVM()
        vm.beginStroke(); _ = vm.brushDab(atX: 3, y: 3)
        XCTAssertTrue(vm.undoPaint())
        XCTAssertTrue(vm.canRedoPaint)
        vm.beginStroke(); _ = vm.brushDab(atX: 6, y: 6)   // new stroke
        XCTAssertFalse(vm.canRedoPaint, "a new stroke discards the redo branch")
    }
}
