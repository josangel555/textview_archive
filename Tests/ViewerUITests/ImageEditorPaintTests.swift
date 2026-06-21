import AppKit
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
        XCTAssertTrue(ImageEditorViewModel.RasterTool.pencil.isContinuous)
        XCTAssertFalse(ImageEditorViewModel.RasterTool.none.isContinuous)
        XCTAssertFalse(ImageEditorViewModel.RasterTool.colorPicker.isContinuous)
        XCTAssertFalse(ImageEditorViewModel.RasterTool.floodFill.isContinuous)
    }

    // MARK: - pencil (TSK-1056)

    func test_rasterTool_resolvedRadius_pencilIsHairline() {
        XCTAssertEqual(ImageEditorViewModel.RasterTool.pencil.resolvedRadius(base: 9), 0)
        XCTAssertEqual(ImageEditorViewModel.RasterTool.brush.resolvedRadius(base: 9), 9)
        XCTAssertEqual(ImageEditorViewModel.RasterTool.eraser.resolvedRadius(base: 9), 9)
    }

    func test_pencil_paintsSinglePixel_ignoringBrushSlider() throws {
        let vm = try makeVM(w: 12, h: 12, r: 1, g: 1, b: 1)   // white
        vm.tool = .pencil
        vm.paintColor = .black
        vm.brushRadius = 5                  // a fat slider the pencil must ignore
        let n = vm.applyTool(atX: 6, y: 6)
        XCTAssertEqual(n, 1, "pencil paints exactly one pixel")
        XCTAssertLessThanOrEqual(sample(vm.rendered!, x: 6, y: 6).r, 4, "the pencil pixel is black")
        XCTAssertGreaterThanOrEqual(sample(vm.rendered!, x: 6, y: 8).r, 250,
                                    "a pixel a brush-radius away is untouched (pencil ignored the slider)")
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

    // MARK: - shape tools (TSK-1059)

    func test_rasterTool_isShape() {
        XCTAssertTrue(ImageEditorViewModel.RasterTool.drawRect.isShape)
        XCTAssertTrue(ImageEditorViewModel.RasterTool.drawEllipse.isShape)
        XCTAssertFalse(ImageEditorViewModel.RasterTool.brush.isShape)
        XCTAssertFalse(ImageEditorViewModel.RasterTool.none.isShape)
    }

    func test_rasterTool_shapeKind() {
        XCTAssertEqual(ImageEditorViewModel.RasterTool.drawRect.shapeKind, .rect)
        XCTAssertEqual(ImageEditorViewModel.RasterTool.drawEllipse.shapeKind, .ellipse)
        XCTAssertEqual(ImageEditorViewModel.RasterTool.drawRoundedRect.shapeKind, .roundedRect)
        XCTAssertEqual(ImageEditorViewModel.RasterTool.drawLine.shapeKind, .line)
        XCTAssertEqual(ImageEditorViewModel.RasterTool.drawArrow.shapeKind, .arrow)
        XCTAssertNil(ImageEditorViewModel.RasterTool.brush.shapeKind)
        XCTAssertNil(ImageEditorViewModel.RasterTool.floodFill.shapeKind)
    }

    func test_rasterTool_isOpenShape() {
        XCTAssertTrue(ImageEditorViewModel.RasterTool.drawLine.isOpenShape)
        XCTAssertTrue(ImageEditorViewModel.RasterTool.drawArrow.isOpenShape)
        XCTAssertFalse(ImageEditorViewModel.RasterTool.drawRect.isOpenShape)
        XCTAssertFalse(ImageEditorViewModel.RasterTool.brush.isOpenShape)
    }

    func test_drawShape_addsEllipse() throws {
        let vm = try makeVM(w: 10, h: 10)
        _ = vm.drawShape(.ellipse, normalizedFrame: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.6))
        XCTAssertEqual(vm.overlay.shapes.last?.kind, .ellipse)
    }

    func test_drawShape_addsRoundedRect() throws {
        let vm = try makeVM(w: 10, h: 10)
        _ = vm.drawShape(.roundedRect, normalizedFrame: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.6))
        XCTAssertEqual(vm.overlay.shapes.last?.kind, .roundedRect)
    }

    func test_drawShape_lineKeepsSignedFrameDirection() throws {
        let vm = try makeVM(w: 10, h: 10)
        // An upward line: signed frame (negative height) → end above start.
        let frame = CGRect(x: 0.2, y: 0.8, width: 0.6, height: -0.6)
        _ = vm.drawShape(.line, normalizedFrame: frame)
        let shape = try XCTUnwrap(vm.overlay.shapes.last)
        XCTAssertEqual(shape.kind, .line)
        XCTAssertEqual(shape.start.y, 0.8, accuracy: 0.001)
        XCTAssertEqual(shape.end.y, 0.2, accuracy: 0.001, "drawn line keeps its upward direction")
    }

    func test_drawShape_addsRectWithPaintColorAndSliderWidth() throws {
        let vm = try makeVM(w: 10, h: 10)
        vm.paintColor = RGBAColor(r: 255, g: 0, b: 0, a: 255)   // red
        vm.brushRadius = 4
        let before = vm.overlay.count
        let frame = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        _ = vm.drawShape(.rect, normalizedFrame: frame)
        XCTAssertEqual(vm.overlay.count, before + 1)
        let shape = try XCTUnwrap(vm.overlay.shapes.last)
        XCTAssertEqual(shape.kind, .rect)
        XCTAssertEqual(shape.frame, frame)
        XCTAssertEqual(shape.style.stroke.r, 1, accuracy: 0.01, "stroke uses the red paint color")
        XCTAssertLessThanOrEqual(shape.style.stroke.g, 0.01)
        XCTAssertEqual(shape.style.lineWidth, 4, accuracy: 0.01, "line width from the brush slider")
    }

    func test_drawShape_fillToggle() throws {
        let vm = try makeVM(w: 10, h: 10)
        vm.paintColor = RGBAColor(r: 0, g: 0, b: 255, a: 255)   // blue
        // Default: outline only — no fill.
        _ = vm.drawShape(.rect, normalizedFrame: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        XCTAssertNil(vm.overlay.shapes.last?.style.fill, "default shape is outline only")
        // Fill on: the shape is filled with the paint color.
        vm.shapeFilled = true
        _ = vm.drawShape(.rect, normalizedFrame: CGRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3))
        let fill = try XCTUnwrap(vm.overlay.shapes.last?.style.fill)
        XCTAssertGreaterThan(fill.b, 0.9, "a filled shape fills with the blue paint color")
    }

    // MARK: - decode-once cache (TSK-1051)

    func test_decodeOnce_sourceDecodedOnceAcrossRenders() throws {
        let vm = try makeVM(w: 20, h: 16)
        vm.render()
        vm.render()
        XCTAssertEqual(vm.decodeCount, 1, "the source is decoded once and the base cached")
        vm.commitGeometry(.resize(width: 10, height: 8))   // op + re-render
        XCTAssertEqual(vm.decodeCount, 1, "ops replay on the cached base — no re-decode")
        XCTAssertEqual(vm.rendered?.width, 10, "and the op still applies")
    }

    // MARK: - off-main save (TSK-1053)

    func test_saveCopyAsync_writesDecodableFile() async throws {
        let vm = try makeVM(w: 8, h: 8, r: 1, g: 0, b: 0)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-save-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let ok = await vm.saveCopyAsync(format: .png, to: url)
        XCTAssertTrue(ok)
        XCTAssertNil(vm.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(img.width, 8, "the off-main save wrote the edited image")
    }

    func test_saveCopyAsync_failureSetsLastError() async throws {
        let vm = try makeVM(w: 8, h: 8)
        let bad = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/x.png")
        let ok = await vm.saveCopyAsync(format: .png, to: bad)
        XCTAssertFalse(ok)
        XCTAssertNotNil(vm.lastError, "a failed save is captured, not silently dropped")
    }

    // MARK: - square brush (TSK-1062)

    func test_squareBrush_paintsCornerThroughVM() throws {
        let vm = try makeVM(w: 11, h: 11, r: 1, g: 1, b: 1)   // white
        vm.tool = .brush
        vm.paintColor = .black
        vm.brushRadius = 2
        vm.squareBrush = true
        vm.applyTool(atX: 5, y: 5)
        // The block corner (7,7) — square paints it black; a round disc would leave white.
        XCTAssertLessThanOrEqual(sample(vm.rendered!, x: 7, y: 7).r, 4,
                                 "the square brush paints the block corner")
    }

    // MARK: - selection + crop (TSK-1063 / 1068)

    func test_rasterTool_isSelection() {
        XCTAssertTrue(ImageEditorViewModel.RasterTool.selectRect.isSelection)
        XCTAssertFalse(ImageEditorViewModel.RasterTool.brush.isSelection)
        XCTAssertFalse(ImageEditorViewModel.RasterTool.drawRect.isSelection)
    }

    func test_cropToSelection_cropsToSelectedRegion() throws {
        let vm = try makeVM(w: 20, h: 16, r: 1, g: 1, b: 1)
        vm.setSelection(.rect(x: 4, y: 2, width: 10, height: 8))
        XCTAssertNotNil(vm.selection)
        XCTAssertTrue(vm.cropToSelection())
        XCTAssertEqual(vm.rendered?.width, 10, "cropped to the selection width")
        XCTAssertEqual(vm.rendered?.height, 8, "cropped to the selection height")
        XCTAssertNil(vm.selection, "selection is cleared after the crop")
    }

    func test_cropToSelection_noSelection_isNoOp() throws {
        let vm = try makeVM(w: 20, h: 16)
        XCTAssertFalse(vm.cropToSelection())
        XCTAssertEqual(vm.rendered?.width, 20, "no selection → no crop")
    }

    func test_deleteSelection_clearsRegionToTransparent() throws {
        let vm = try makeVM(w: 10, h: 10, r: 1, g: 1, b: 1)   // opaque white
        vm.setSelection(.rect(x: 2, y: 2, width: 4, height: 4))
        XCTAssertTrue(vm.deleteSelection())
        XCTAssertLessThanOrEqual(sample(vm.rendered!, x: 3, y: 3).a, 4,
                                 "the deleted region is transparent")
        XCTAssertEqual(sample(vm.rendered!, x: 0, y: 0).a, 255,
                       "outside the selection stays opaque")
    }

    func test_selectAll_selectsWholeImage() throws {
        let vm = try makeVM(w: 12, h: 9)
        vm.selectAll()
        XCTAssertEqual(vm.selection, .rect(x: 0, y: 0, width: 12, height: 9))
    }

    func test_selectionImage_cropsToSelection() throws {
        let vm = try makeVM(w: 20, h: 16)
        vm.setSelection(.rect(x: 3, y: 4, width: 8, height: 6))
        let img = try XCTUnwrap(vm.selectionImage())
        XCTAssertEqual(img.width, 8)
        XCTAssertEqual(img.height, 6)
    }

    func test_copySelection_writesImageToPasteboard() throws {
        let vm = try makeVM(w: 20, h: 16)
        vm.setSelection(.rect(x: 0, y: 0, width: 10, height: 10))
        let pb = NSPasteboard(name: NSPasteboard.Name("mdv-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        XCTAssertTrue(vm.copySelection(to: pb))
        XCTAssertTrue(pb.canReadObject(forClasses: [NSImage.self], options: nil),
                      "copy wrote an image to the pasteboard")
    }

    func test_cutSelection_copiesThenClearsRegion() throws {
        let vm = try makeVM(w: 10, h: 10, r: 1, g: 1, b: 1)
        vm.setSelection(.rect(x: 2, y: 2, width: 4, height: 4))
        let pb = NSPasteboard(name: NSPasteboard.Name("mdv-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        XCTAssertTrue(vm.cutSelection(to: pb))
        XCTAssertTrue(pb.canReadObject(forClasses: [NSImage.self], options: nil),
                      "cut wrote the region to the pasteboard")
        XCTAssertLessThanOrEqual(sample(vm.rendered!, x: 3, y: 3).a, 4,
                                 "cut cleared the region to transparent")
    }
}
