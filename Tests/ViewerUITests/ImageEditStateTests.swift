import AppKit
import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ViewerCore
@testable import ViewerUI

/// TSK-1303 — the image edit-state survives a serialize→restore round-trip. This is the host
/// foundation for persisting edits across a session switch (today the VM holds them only in-memory,
/// so a session switch loses them); the session-snapshot WIRING is the data-safety-sensitive tail.
@MainActor
final class ImageEditStateTests: XCTestCase {

    private func solidPNG(width: Int = 20, height: Int = 16) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func makeVM() throws -> ImageEditorViewModel {
        ImageEditorViewModel(ImageDocument(data: try solidPNG()))
    }

    func test_editState_roundTrips_acrossCaptureRestore_TSK1303() throws {
        let vm = try makeVM()
        // Pending tonal adjustments, a committed op, and a vector annotation.
        vm.brightness = 0.3; vm.contrast = 1.5; vm.saturation = 0.8
        vm.exposureEV = 0.5; vm.shadow = 0.2; vm.highlight = 0.9; vm.sharpness = 0.4
        vm.commitGeometry(.orient(.right90))
        _ = vm.drawShape(.rect, normalizedFrame: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))

        // Capture → Codable round-trip → restore onto a FRESH view-model.
        let state = vm.captureEditState()
        let back = try JSONDecoder().decode(ImageEditState.self, from: try JSONEncoder().encode(state))
        let fresh = try makeVM()
        fresh.restoreEditState(back)

        XCTAssertEqual(fresh.brightness, 0.3)
        XCTAssertEqual(fresh.contrast, 1.5)
        XCTAssertEqual(fresh.saturation, 0.8)
        XCTAssertEqual(fresh.exposureEV, 0.5)
        XCTAssertEqual(fresh.shadow, 0.2)
        XCTAssertEqual(fresh.highlight, 0.9)
        XCTAssertEqual(fresh.sharpness, 0.4)
        XCTAssertEqual(fresh.base.ops, vm.base.ops, "the committed op-list must restore")
        XCTAssertFalse(fresh.base.ops.isEmpty, "precondition: a committed op exists")
        XCTAssertEqual(fresh.overlay.shapes.count, 1, "the annotation overlay must restore")
        XCTAssertEqual(fresh.overlay.shapes.first?.kind, .rect)
    }
}
