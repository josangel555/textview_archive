import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ViewerUI
import ViewerCore

/// TSK-1114 — `fillSelection()` closes the selection-tool loop (marquee/lasso +
/// selection already exist; this adds the fill action). Host teeth on the
/// command path + undoability.
@MainActor
final class ImageEditorFillSelectionTests: XCTestCase {

    private func solidPNG(_ w: Int, _ h: Int) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let img = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func makeVM() throws -> ImageEditorViewModel {
        ImageEditorViewModel(ImageDocument(data: try solidPNG(16, 16)))
    }

    func test_fillSelection_noSelection_isNoOp() throws {
        let vm = try makeVM()
        vm.clearSelection()
        XCTAssertFalse(vm.fillSelection())
        XCTAssertFalse(vm.canUndo)
    }

    func test_fillSelection_withSelection_appliesAndIsUndoable() throws {
        let vm = try makeVM()
        vm.paintColor = RGBAColor(r: 255, g: 0, b: 0, a: 255)
        vm.selectAll()                       // whole-image rect selection
        XCTAssertTrue(vm.fillSelection())
        XCTAssertTrue(vm.canUndo, "a fill is a single undoable paint op")
        vm.undo()
        XCTAssertFalse(vm.canUndo, "undo peeled the fill")
    }

    func test_fillSelection_changesPixels() throws {
        let vm = try makeVM()
        vm.paintColor = RGBAColor(r: 255, g: 0, b: 0, a: 255)
        vm.selectAll()
        let before = vm.rendered.flatMap { Self.centrePixel($0) }
        _ = vm.fillSelection()
        let after = vm.rendered.flatMap { Self.centrePixel($0) }
        XCTAssertNotNil(after)
        XCTAssertNotEqual(before, after, "the filled region's pixels changed")
    }

    /// The centre pixel's RGBA as a comparable tuple, via a 1×1 draw.
    private static func centrePixel(_ img: CGImage) -> [UInt8]? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        var buf = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &buf, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Draw the image so its centre lands on the single pixel.
        ctx.draw(img, in: CGRect(x: -CGFloat(img.width) / 2 + 0.5,
                                 y: -CGFloat(img.height) / 2 + 0.5,
                                 width: CGFloat(img.width), height: CGFloat(img.height)))
        return buf
    }
}
