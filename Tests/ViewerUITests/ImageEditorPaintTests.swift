import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import ViewerUI
import ViewerCore

/// Host teeth for the raster paint wiring on `ImageEditorViewModel` (TSK-285):
/// the model-state outcome of the color-picker / brush / flood-fill tools, the
/// lazy paint-session bake, paint→preview shadowing, and export of the painted
/// buffer. Pure headless Core Image — runs on the host gate. The point-to-pixel
/// gesture mapping in the SwiftUI preview is the render-gated remainder (VM).
@MainActor
final class ImageEditorPaintTests: XCTestCase {

    /// A solid-colour PNG blob for an `ImageDocument(data:)`.
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

    private func makeVM(w: Int = 20, h: Int = 16,
                        r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1) throws -> ImageEditorViewModel {
        let data = try solidPNG(width: w, height: h, r: r, g: g, b: b)
        return ImageEditorViewModel(ImageDocument(data: data))
    }

    private struct RGBA { let r, g, b, a: Int }
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

    // MARK: - defaults / session lifecycle

    func test_defaults_noToolNoPaint() throws {
        let vm = try makeVM()
        XCTAssertEqual(vm.tool, .none)
        XCTAssertFalse(vm.hasPaint)
        XCTAssertNil(vm.paintCanvas)
        // applyTool with .none is a no-op and does NOT bake a session.
        XCTAssertEqual(vm.applyTool(atX: 5, y: 5), 0)
        XCTAssertFalse(vm.hasPaint, ".none never bakes a paint session")
    }

    func test_beginPaintSession_bakesFromRender() throws {
        let vm = try makeVM(w: 20, h: 16)
        XCTAssertTrue(vm.beginPaintSessionIfNeeded())
        XCTAssertNotNil(vm.paintCanvas)
        XCTAssertEqual(vm.paintCanvas?.width, 20)
        XCTAssertEqual(vm.paintCanvas?.height, 16)
        // Bake is idempotent — a second call keeps the same buffer.
        let first = vm.paintCanvas
        XCTAssertTrue(vm.beginPaintSessionIfNeeded())
        XCTAssertEqual(vm.paintCanvas, first, "second bake is a no-op")
    }

    // MARK: - color picker (eyedropper)

    func test_colorPicker_readsPixelIntoPaintColor() throws {
        // A red source: picking any pixel loads a predominantly-red color into
        // paintColor. (Exact byte equality across the decode→sRGB round-trip is
        // pinned engine-side in RasterCanvasTests; here we assert the picker WIRES
        // the sampled pixel into `paintColor` — red dominant, opaque.)
        let vm = try makeVM(r: 1, g: 0, b: 0)
        vm.tool = .colorPicker
        let n = vm.applyTool(atX: 10, y: 8)
        XCTAssertEqual(n, 1, "a successful pick reports 1")
        XCTAssertGreaterThanOrEqual(vm.paintColor.r, 240, "picked color is red-dominant")
        XCTAssertGreaterThan(Int(vm.paintColor.r), Int(vm.paintColor.g) + 100)
        XCTAssertGreaterThan(Int(vm.paintColor.r), Int(vm.paintColor.b) + 100)
        XCTAssertEqual(vm.paintColor.a, 255)
    }

    func test_colorPicker_offCanvas_isNoOp() throws {
        let vm = try makeVM()
        vm.tool = .colorPicker
        XCTAssertEqual(vm.applyTool(atX: 999, y: 999), 0)
    }

    // MARK: - brush

    func test_brush_marksSurface_andShadowsPreview() throws {
        let vm = try makeVM(r: 1, g: 1, b: 1)         // white source
        vm.tool = .brush
        vm.paintColor = .black
        vm.brushRadius = 0
        let n = vm.applyTool(atX: 5, y: 5)
        XCTAssertEqual(n, 1)
        XCTAssertTrue(vm.hasPaint)
        // The painted pixel shadows the tonal/geometry preview.
        let painted = sample(vm.rendered!, x: 5, y: 5)
        XCTAssertLessThanOrEqual(painted.r, 4)
        XCTAssertLessThanOrEqual(painted.g, 4)
        XCTAssertLessThanOrEqual(painted.b, 4, "brushed pixel is black in the rendered preview")
        // An un-brushed pixel is still white.
        let clean = sample(vm.rendered!, x: 0, y: 0)
        XCTAssertGreaterThanOrEqual(clean.r, 250)
        XCTAssertTrue(vm.isEdited, "a paint mark counts as an edit")
    }

    func test_brushStroke_drawsContinuousLine() throws {
        let vm = try makeVM(w: 20, h: 4, r: 1, g: 1, b: 1)
        vm.paintColor = .black
        vm.brushRadius = 0
        let n = vm.brushStroke(fromX: 0, y0: 2, toX: 19, y1: 2)
        XCTAssertEqual(n, 20, "the whole horizontal line is painted")
        XCTAssertLessThanOrEqual(sample(vm.rendered!, x: 10, y: 2).r, 4, "midpoint painted black")
    }

    // MARK: - flood fill

    func test_floodFill_fillsContiguousRegion() throws {
        let vm = try makeVM(w: 8, h: 8, r: 1, g: 1, b: 1)   // uniform white
        vm.tool = .floodFill
        vm.paintColor = .blue
        let n = vm.applyTool(atX: 4, y: 4)
        XCTAssertEqual(n, 64, "the whole uniform canvas is one region")
        let p = sample(vm.rendered!, x: 4, y: 4)
        XCTAssertLessThanOrEqual(p.r, 4)
        XCTAssertLessThanOrEqual(p.g, 4)
        XCTAssertGreaterThanOrEqual(p.b, 250, "filled region is blue")
    }

    // MARK: - discard / revert interplay

    func test_discardPaint_returnsToTonalRender() throws {
        let vm = try makeVM(r: 1, g: 1, b: 1)
        vm.tool = .brush
        vm.paintColor = .black
        vm.brushRadius = 0
        vm.applyTool(atX: 5, y: 5)
        XCTAssertTrue(vm.hasPaint)

        vm.discardPaint()
        XCTAssertFalse(vm.hasPaint)
        // The pixel is white again (back to the source render).
        XCTAssertGreaterThanOrEqual(sample(vm.rendered!, x: 5, y: 5).r, 250)
    }

    func test_revertAll_alsoDiscardsPaint() throws {
        let vm = try makeVM(r: 1, g: 1, b: 1)
        vm.commitGeometry(.resize(width: 10, height: 8))
        vm.tool = .brush
        vm.paintColor = .black
        vm.brushRadius = 0
        vm.applyTool(atX: 3, y: 3)
        XCTAssertTrue(vm.hasPaint)

        vm.revertAll()
        XCTAssertFalse(vm.hasPaint, "revertAll discards the paint session")
        XCTAssertTrue(vm.base.ops.isEmpty)
        XCTAssertEqual(vm.rendered?.width, 20, "back to the full-size source")
    }

    // MARK: - export honors the painted buffer

    func test_exportData_encodesPaintedPixels() throws {
        let vm = try makeVM(w: 6, h: 6, r: 1, g: 1, b: 1)
        vm.tool = .floodFill
        vm.paintColor = .red
        vm.applyTool(atX: 3, y: 3)

        let data = try vm.exportData(format: .png)
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return XCTFail("export PNG did not decode")
        }
        XCTAssertEqual(img.width, 6)
        XCTAssertEqual(img.height, 6)
        let p = sample(img, x: 3, y: 3)
        XCTAssertGreaterThanOrEqual(p.r, 250)
        XCTAssertLessThanOrEqual(p.g, 4)
        XCTAssertLessThanOrEqual(p.b, 4, "exported PNG carries the painted red, not the white source")
    }

    // MARK: - tool enum coverage

    func test_rasterTool_dispatch() throws {
        let vm = try makeVM()
        // brush
        vm.tool = .brush; vm.brushRadius = 0; vm.paintColor = .black
        XCTAssertEqual(vm.applyTool(atX: 1, y: 1), 1)
        // flood (already has a session; fill the rest that isn't the one black px)
        vm.tool = .floodFill; vm.paintColor = .green
        let filled = vm.applyTool(atX: 5, y: 5)
        XCTAssertGreaterThan(filled, 0, "flood fills the remaining region")
        // picker reads back
        vm.tool = .colorPicker
        XCTAssertEqual(vm.applyTool(atX: 5, y: 5), 1)
        XCTAssertEqual(vm.paintColor.g, 255, "picker read the green we just filled")
    }

    // MARK: - eraser (TSK-1057)

    func test_rasterTool_resolvedColor_eraserIsClear() {
        XCTAssertEqual(ImageEditorViewModel.RasterTool.eraser.resolvedColor(base: .black), .clear)
        XCTAssertEqual(ImageEditorViewModel.RasterTool.brush.resolvedColor(base: .black), .black)
        XCTAssertEqual(ImageEditorViewModel.RasterTool.floodFill.resolvedColor(base: .red), .red)
    }

    func test_rasterTool_isContinuous() {
        XCTAssertTrue(ImageEditorViewModel.RasterTool.brush.isContinuous)
        XCTAssertTrue(ImageEditorViewModel.RasterTool.eraser.isContinuous)
        XCTAssertFalse(ImageEditorViewModel.RasterTool.none.isContinuous)
        XCTAssertFalse(ImageEditorViewModel.RasterTool.colorPicker.isContinuous)
        XCTAssertFalse(ImageEditorViewModel.RasterTool.floodFill.isContinuous)
    }

    func test_eraser_paintsTransparency() throws {
        let vm = try makeVM(w: 10, h: 10, r: 1, g: 1, b: 1)   // opaque white
        XCTAssertEqual(sample(vm.rendered!, x: 5, y: 5).a, 255, "source is opaque")
        vm.tool = .eraser
        vm.paintColor = .black            // ignored by the eraser (it paints .clear)
        vm.brushRadius = 0
        let n = vm.applyTool(atX: 5, y: 5)
        XCTAssertEqual(n, 1)
        XCTAssertTrue(vm.hasPaint)
        XCTAssertLessThanOrEqual(sample(vm.rendered!, x: 5, y: 5).a, 4,
                                 "the erased pixel is transparent, not the black paintColor")
        XCTAssertEqual(sample(vm.rendered!, x: 0, y: 0).a, 255, "an un-erased pixel stays opaque")
    }
}
