import XCTest
import CoreGraphics
import ViewerCore
@testable import ViewerUI

/// TSK-1085 — host tests for the extended shape gallery's placement path:
/// drawGalleryShape projects the (host-tested) GalleryShape vertices onto the
/// drag box and commits a fillPolygon/strokePolygon raster op. The geometry
/// itself is pinned by GalleryShapeTests; these pin the vm wiring.
@MainActor
final class ImageEditorGalleryShapeTests: XCTestCase {

    private func solidPNG(width: Int = 40, height: Int = 40) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))   // white
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = ctx.makeImage()!
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])!
    }

    private func pixelBytes(_ cg: CGImage?) -> [UInt8]? {
        guard let cg, let data = cg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        return Array(UnsafeBufferPointer(start: ptr, count: CFDataGetLength(data)))
    }

    func test_drawGalleryShape_filled_commitsUndoableOp_andChangesPixels() throws {
        let vm = ImageEditorViewModel(ImageDocument(data: try solidPNG()))
        let before = pixelBytes(vm.rendered)
        vm.paintColor = RGBAColor(r: 200, g: 0, b: 0, a: 255)   // red over white
        vm.shapeFilled = true
        let ok = vm.drawGalleryShape(.star5, normalizedFrame: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
        XCTAssertTrue(ok, "a valid box commits the shape")
        XCTAssertTrue(vm.canUndo, "the placed gallery shape is undoable (U5)")
        XCTAssertEqual(vm.rendered?.width, 40, "the op didn't resize the canvas")
        let after = pixelBytes(vm.rendered)
        XCTAssertNotNil(after)
        XCTAssertNotEqual(before, after, "the filled star changed pixels — it actually drew")
    }

    func test_drawGalleryShape_degenerateBox_isRefused_andCommitsNothing() throws {
        let vm = ImageEditorViewModel(ImageDocument(data: try solidPNG()))
        // Zero-area box → no shape (guards the <3-vertex / empty case).
        XCTAssertFalse(vm.drawGalleryShape(.hexagon, normalizedFrame: CGRect(x: 0.5, y: 0.5, width: 0, height: 0)))
        XCTAssertFalse(vm.canUndo, "a refused placement commits no op")
    }

    func test_drawGalleryShape_strokeVsFill_bothDraw() throws {
        // Outline (unfilled) also changes pixels via strokePolygon.
        let vm = ImageEditorViewModel(ImageDocument(data: try solidPNG()))
        let before = pixelBytes(vm.rendered)
        vm.paintColor = RGBAColor(r: 0, g: 0, b: 200, a: 255)
        vm.shapeFilled = false
        XCTAssertTrue(vm.drawGalleryShape(.arrowRight, normalizedFrame: CGRect(x: 0.05, y: 0.3, width: 0.9, height: 0.4)))
        XCTAssertNotEqual(before, pixelBytes(vm.rendered), "the stroked arrow outline drew")
    }
}
