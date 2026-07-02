import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import ViewerCore
@testable import ViewerUI

/// Overlay-in-export (usability audit 2026-07-02, TSK-1422). The vector overlay
/// (annotation shapes + text) is drawn over the preview but was never baked, so
/// save-a-copy silently dropped every annotation. exportData now composites the
/// overlay via the same VectorOverlayView (WYSIWYG). Host-testable: ImageRenderer
/// rasterizes the Canvas headlessly.
@MainActor
final class ImageEditorOverlayExportTests: XCTestCase {
    private func solidPNG(_ w: Int = 40, _ h: Int = 30) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let out = NSMutableData()
        let d = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil); _ = CGImageDestinationFinalize(d)
        return out as Data
    }
    private func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
    private func hasStrongRed(_ img: CGImage) -> Bool {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in stride(from: 0, to: buf.count, by: 4) where buf[i] > 180 && buf[i+1] < 80 && buf[i+2] < 80 {
            return true
        }
        return false
    }

    func test_export_includesOverlayShape() throws {
        let vm = ImageEditorViewModel(ImageDocument(data: try solidPNG()))
        let plain = try vm.exportData(format: .png)
        vm.addShape(VectorShape(kind: .rect, frame: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.5),
                                style: ShapeStyle(stroke: .red, lineWidth: 3, fill: .red)))
        let annotated = try vm.exportData(format: .png)
        XCTAssertNotEqual(plain, annotated, "export must differ once an annotation is present")
        let img = try XCTUnwrap(decode(annotated))
        XCTAssertTrue(hasStrongRed(img), "the exported image must actually contain the red annotation pixels")
    }

    func test_export_withNoOverlay_isUnchanged() throws {
        let vm = ImageEditorViewModel(ImageDocument(data: try solidPNG()))
        let a = try vm.exportData(format: .png)
        let b = try vm.exportData(format: .png)
        XCTAssertEqual(a, b, "no overlay → export is stable (compositing is a no-op)")
    }
}
