import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
import ViewerCore
@testable import ViewerUI

/// Tone-vs-paint gate (usability audit 2026-07-02). Painting bakes the current
/// tonal result into a destructive buffer that shadows the tonal pipeline in
/// render(), so a tone slider dragged AFTER painting is a silent no-op. Rather
/// than lie, the UI disables the Tone controls once painting starts — gated on
/// `isToneEditable`. These pin that contract.
@MainActor
final class ImageEditorTonePaintGateTests: XCTestCase {
    private func solidPNG(_ w: Int = 12, _ h: Int = 10) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let out = NSMutableData()
        let d = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, ctx.makeImage()!, nil); _ = CGImageDestinationFinalize(d)
        return out as Data
    }
    private func makeVM() throws -> ImageEditorViewModel {
        ImageEditorViewModel(ImageDocument(data: try solidPNG()))
    }

    func test_toneEditable_beforePaint() throws {
        let vm = try makeVM()
        XCTAssertTrue(vm.isToneEditable, "tone is editable before any paint session")
    }

    func test_toneLocked_oncePainting() throws {
        let vm = try makeVM()
        vm.beginStroke(); _ = vm.brushDab(atX: 5, y: 5)
        XCTAssertNotNil(vm.paintCanvas)
        XCTAssertFalse(vm.isToneEditable, "tone must be locked once a destructive paint session exists")
    }

    func test_toneEditableAgain_afterRevert() throws {
        let vm = try makeVM()
        vm.beginStroke(); _ = vm.brushDab(atX: 5, y: 5)
        XCTAssertFalse(vm.isToneEditable)
        vm.revertAll()   // discards the paint session (paintCanvas = nil)
        XCTAssertTrue(vm.isToneEditable, "reverting the paint session re-enables tone editing")
    }
}
