import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ViewerUI
import ViewerCore

/// Host teeth for `ImageEditorViewModel` — the image-editor model layer
/// (TSK-342). Pure headless Core Image (no window): exercises the real
/// slider→op→rendered-pixel path, the no-history-spam folding, geometry
/// commit/undo, and reset/revert. Runs on the host gate.
@MainActor
final class ImageEditorViewModelTests: XCTestCase {

    // MARK: - fixtures

    /// A solid-colour PNG blob (8-bit sRGB) for an `ImageDocument(data:)`.
    private func solidPNG(width: Int, height: Int,
                          r: CGFloat, g: CGFloat, b: CGFloat) throws -> Data {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private struct RGBA { let r, g, b, a: Int }

    /// Read one pixel (top-left origin) from a freshly-normalized RGBA8 raster.
    private func sample(_ image: CGImage, x: Int, y: Int) -> RGBA {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = buf.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: w, height: h,
                      bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let i = (y * w + x) * 4
        return RGBA(r: Int(buf[i]), g: Int(buf[i + 1]), b: Int(buf[i + 2]), a: Int(buf[i + 3]))
    }

    private func makeVM(r: CGFloat = 0.5, g: CGFloat = 0.4, b: CGFloat = 0.3) throws -> ImageEditorViewModel {
        let data = try solidPNG(width: 40, height: 30, r: r, g: g, b: b)
        return ImageEditorViewModel(ImageDocument(data: data))
    }

    // MARK: - tests

    func test_init_rendersPristineSource() throws {
        let vm = try makeVM()
        XCTAssertNotNil(vm.rendered)
        XCTAssertEqual(vm.rendered?.width, 40)
        XCTAssertEqual(vm.rendered?.height, 30)
        XCTAssertNotNil(vm.histogram)
        XCTAssertEqual(vm.histogram?.pixelCount, 40 * 30)
        XCTAssertTrue(vm.document.isPristine, "no edits → pristine document")
        XCTAssertFalse(vm.isEdited)
        XCTAssertNil(vm.lastError)
    }

    func test_brightnessUp_lightens_andFoldsToOneOp() throws {
        let vm = try makeVM()
        let before = sample(vm.rendered!, x: 20, y: 15)

        vm.brightness = 0.4
        vm.render()
        let after = sample(vm.rendered!, x: 20, y: 15)
        XCTAssertGreaterThan(after.r, before.r + 10, "brightness up lightens the pixel")

        // The whole tonal adjustment must fold into exactly ONE op...
        XCTAssertEqual(vm.document.ops.count, 1)
        if case .colorControls = vm.document.ops[0] {} else {
            XCTFail("expected a single colorControls op, got \(vm.document.ops)")
        }
        // ...and re-dragging the slider must NOT spam the history.
        vm.brightness = 0.6
        vm.render()
        XCTAssertEqual(vm.document.ops.count, 1, "second adjustment replaces, not appends")
        XCTAssertTrue(vm.isEdited)
    }

    func test_saturationZero_graysOutColor() throws {
        let vm = try makeVM(r: 0.7, g: 0.3, b: 0.15)
        vm.saturation = 0
        vm.render()
        let p = sample(vm.rendered!, x: 20, y: 15)
        XCTAssertLessThanOrEqual(abs(p.r - p.g), 3)
        XCTAssertLessThanOrEqual(abs(p.g - p.b), 3, "saturation 0 collapses to grey (R≈G≈B)")
    }

    func test_commitGeometry_resize_changesDims_andUndoRestores() throws {
        let vm = try makeVM()
        vm.commitGeometry(.resize(width: 20, height: 15))
        XCTAssertEqual(vm.rendered?.width, 20)
        XCTAssertEqual(vm.rendered?.height, 15)
        XCTAssertEqual(vm.base.ops.count, 1, "resize committed to the lossless history")

        vm.undoGeometry()
        XCTAssertEqual(vm.rendered?.width, 40)
        XCTAssertEqual(vm.rendered?.height, 30)
        XCTAssertTrue(vm.base.ops.isEmpty, "undo drops the geometry op")
    }

    func test_resetTonal_returnsRenderToPristine_keepsGeometry() throws {
        let vm = try makeVM()
        vm.commitGeometry(.resize(width: 20, height: 15))
        let pristine = sample(vm.rendered!, x: 10, y: 7)

        vm.brightness = 0.5
        vm.render()
        XCTAssertGreaterThan(sample(vm.rendered!, x: 10, y: 7).r, pristine.r + 10)

        vm.resetTonal()
        XCTAssertEqual(vm.brightness, 0)
        XCTAssertEqual(vm.base.ops.count, 1, "resetTonal keeps the geometry history")
        let restored = sample(vm.rendered!, x: 10, y: 7)
        XCTAssertLessThanOrEqual(abs(restored.r - pristine.r), 3, "tonal reset restores the pixel")
    }

    func test_revertAll_clearsGeometryAndTonal() throws {
        let vm = try makeVM()
        vm.commitGeometry(.resize(width: 20, height: 15))
        vm.brightness = 0.5
        vm.exposureEV = 1.0
        vm.render()
        XCTAssertTrue(vm.isEdited)

        vm.revertAll()
        XCTAssertTrue(vm.base.ops.isEmpty)
        XCTAssertEqual(vm.brightness, 0)
        XCTAssertEqual(vm.exposureEV, 0)
        XCTAssertEqual(vm.highlight, 1)
        XCTAssertFalse(vm.isEdited)
        XCTAssertEqual(vm.rendered?.width, 40, "reverted back to the full-size source")
    }

    func test_identitySliders_addNoOps() throws {
        let vm = try makeVM()
        // Setting every slider to its identity value must keep the document pristine.
        vm.brightness = 0; vm.contrast = 1; vm.saturation = 1
        vm.exposureEV = 0; vm.shadow = 0; vm.highlight = 1; vm.sharpness = 0
        vm.render()
        XCTAssertTrue(vm.document.isPristine, "identity sliders contribute no ops")
        XCTAssertNil(vm.lastError)
    }

    /// Decode encoded image bytes back to its pixel dimensions (nil if undecodable).
    private func decodedDims(_ data: Data) -> (w: Int, h: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return (img.width, img.height)
    }

    func test_exportData_png_reflectsGeometryEdit() throws {
        let vm = try makeVM()
        vm.commitGeometry(.resize(width: 20, height: 15))
        let data = try vm.exportData(format: .png)
        let dims = decodedDims(data)
        XCTAssertEqual(dims?.w, 20, "export encodes the EDITED document, not the 40px source")
        XCTAssertEqual(dims?.h, 15)
    }

    func test_exportData_jpeg_isDecodable() throws {
        let vm = try makeVM()
        let data = try vm.exportData(format: .jpeg, quality: 0.6)
        XCTAssertFalse(data.isEmpty)
        let dims = decodedDims(data)
        XCTAssertEqual(dims?.w, 40)
        XCTAssertEqual(dims?.h, 30, "JPEG export round-trips to the source dims")
    }

    func test_export_writesAtomicFile() throws {
        let vm = try makeVM()
        vm.brightness = 0.3   // ensure an edit is present
        vm.render()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-editor-export-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try vm.export(format: .png, to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(decodedDims(onDisk)?.w, 40, "written PNG decodes at the edited document's size")
    }
}
