import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import ViewerCore
@testable import ViewerUI

/// Geometry-after-paint (usability audit 2026-07-02). The destructive paint
/// buffer shadows `base.ops` in render(), so a geometry op (resize/crop/rotate/
/// skew) committed AFTER painting used to be silently swallowed — invisible on
/// screen and lost on export. commitGeometry now transforms the paint buffer
/// THROUGH the op (same Renderer) so paint stays aligned with the geometry.
@MainActor
final class ImageEditorPaintGeometryTests: XCTestCase {
    private func solidPNG(width: Int = 12, height: Int = 10) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        _ = CGImageDestinationFinalize(dest)
        return out as Data
    }

    private func makePainted() throws -> ImageEditorViewModel {
        let vm = ImageEditorViewModel(ImageDocument(data: try solidPNG(width: 12, height: 10)))
        vm.paintColor = RGBAColor(r: 255, g: 0, b: 0, a: 255)
        vm.beginStroke()
        _ = vm.brushDab(atX: 5, y: 5)   // a red mark on white
        XCTAssertNotNil(vm.paintCanvas, "paint session active")
        return vm
    }

    func test_resizeAfterPaint_isReflectedInRender() throws {
        let vm = try makePainted()
        vm.commitGeometry(.resize(width: 24, height: 20))
        XCTAssertEqual(vm.rendered?.width, 24, "resize after paint must be reflected (was shadowed)")
        XCTAssertEqual(vm.rendered?.height, 20)
        XCTAssertEqual(vm.paintCanvas?.width, 24, "the paint buffer itself was transformed by the op")
    }

    func test_paintContentSurvivesTheGeometryOp() throws {
        let vm = try makePainted()
        // the painted buffer is non-uniform (white + a red dab) before the op
        let beforePixels = Set(vm.paintCanvas!.pixels)
        XCTAssertGreaterThan(beforePixels.count, 1, "painted buffer should not be uniform")
        vm.commitGeometry(.resize(width: 24, height: 20))
        let afterPixels = Set(vm.paintCanvas!.pixels)
        XCTAssertGreaterThan(afterPixels.count, 1,
            "paint content must survive the resize (buffer still non-uniform, not blanked)")
    }

    func test_paintRemainsUndoableAfterAGeometryOp() throws {
        let vm = try makePainted()
        vm.commitGeometry(.resize(width: 24, height: 20))
        XCTAssertTrue(vm.canUndo, "there is still something to undo after paint+geometry")
    }
}
