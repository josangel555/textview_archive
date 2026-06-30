import AppKit
import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ViewerCore
@testable import ViewerUI

/// TSK-1049 — the off-main render path (`performRenderOffMain`, the debounced
/// slider path) produces output IDENTICAL to the synchronous `render()`, so
/// moving the CoreImage tonal pipeline + the O(W*H) histogram off the main actor
/// (the responsiveness win — the render no longer freezes the UI) preserves
/// correctness. The histogram is derived from every pixel, so histogram parity is
/// a strong proxy for pixel parity.
@MainActor
final class TSK1049OffMainRenderTests: XCTestCase {

    private func solidPNG(width: Int = 24, height: Int = 18) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(CGColor(red: 0.6, green: 0.4, blue: 0.2, alpha: 1))
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

    func test_offMainRender_matchesSyncRender() async throws {
        // Reference: the synchronous render() output for a tonal state.
        let ref = try makeVM()
        ref.brightness = 0.3; ref.contrast = 1.4; ref.saturation = 0.7
        ref.render()
        let refImage = try XCTUnwrap(ref.rendered, "sync render produced an image")
        let refHist = try XCTUnwrap(ref.histogram, "sync render produced a histogram")

        // The off-main path on the SAME tonal state must produce an identical result.
        let vm = try makeVM()
        vm.brightness = 0.3; vm.contrast = 1.4; vm.saturation = 0.7
        await vm.performRenderOffMain()
        let offImage = try XCTUnwrap(vm.rendered, "off-main render produced an image")
        XCTAssertNil(vm.lastError, "off-main render had no error")
        XCTAssertEqual(offImage.width, refImage.width)
        XCTAssertEqual(offImage.height, refImage.height)
        XCTAssertEqual(vm.histogram, refHist,
                       "off-main render's histogram must match the sync render's (pixel parity)")
    }

    func test_offMainRender_endToEnd_producesPreviewWithoutError() async throws {
        // Exercises the method end-to-end on a clean doc (no tonal edits): it must
        // populate the preview and clear lastError without crashing.
        let vm = try makeVM()
        await vm.performRenderOffMain()
        XCTAssertNotNil(vm.rendered)
        XCTAssertNil(vm.lastError)
    }
}
