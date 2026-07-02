import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import ViewerCore
@testable import ViewerUI

/// Interleaved paint + geometry undo ordering (usability audit 2026-07-02,
/// TSK-1421). During a destructive paint session, geometry ops ride the UNIFIED
/// paint-undo timeline (not the separate op stack), so undo peels strokes and
/// transforms one at a time in order — before this, one undo reverted both a
/// resize AND the preceding stroke, and the op desynced into the shadowed base.ops.
@MainActor
final class ImageEditorUndoOrderingTests: XCTestCase {
    private func solidPNG(_ w: Int = 12, _ h: Int = 10) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let out = NSMutableData()
        let d = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil); _ = CGImageDestinationFinalize(d)
        return out as Data
    }
    private func painted() throws -> ImageEditorViewModel {
        let vm = ImageEditorViewModel(ImageDocument(data: try solidPNG()))
        vm.paintColor = RGBAColor(r: 255, g: 0, b: 0, a: 255)
        vm.beginStroke(); _ = vm.brushDab(atX: 5, y: 5)   // stroke on 12x10
        vm.commitGeometry(.resize(width: 24, height: 20))  // now 24x20, painted
        return vm
    }

    func test_undo_peelsResizeFirst_keepingTheStroke() throws {
        let vm = try painted()
        XCTAssertEqual(vm.paintCanvas?.width, 24)
        vm.undo()  // peel the resize
        XCTAssertEqual(vm.paintCanvas?.width, 12, "resize peeled → back to 12 wide")
        XCTAssertGreaterThan(Set(vm.paintCanvas!.pixels).count, 1, "the STROKE is kept (only the resize was undone)")
    }

    func test_secondUndo_peelsTheStroke() throws {
        let vm = try painted()
        vm.undo()  // resize
        vm.undo()  // stroke
        XCTAssertEqual(vm.paintCanvas?.width, 12)
        XCTAssertEqual(Set(vm.paintCanvas!.pixels).count, 1, "both undone → clean uniform baseline")
    }

    func test_redo_reappliesTheResize() throws {
        let vm = try painted()
        vm.undo()  // resize → 12 wide painted
        XCTAssertEqual(vm.paintCanvas?.width, 12)
        vm.redo()  // redo the resize
        XCTAssertEqual(vm.paintCanvas?.width, 24, "redo re-applies the resize")
        XCTAssertGreaterThan(Set(vm.paintCanvas!.pixels).count, 1)
    }
}
