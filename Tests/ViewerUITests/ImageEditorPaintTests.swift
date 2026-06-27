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

    // MARK: - TSK-1052 dirty-rect / incremental compositing (no full-canvas rebuild per dab)

    func test_dirtyBounds_brushDab_isFootprintNotFullCanvas() throws {
        let vm = try makeVM(w: 64, h: 64, r: 1, g: 1, b: 1)
        vm.tool = .brush
        vm.paintColor = .black
        vm.brushRadius = 2
        // First dab opens the paint session (which may mark a baseline dirty);
        // consume that so the SECOND dab is a clean incremental measurement.
        _ = vm.brushDab(atX: 30, y: 30)
        _ = vm.consumeDirtyBounds()
        let n = vm.brushDab(atX: 30, y: 30)
        XCTAssertGreaterThan(n, 0, "dab painted pixels")
        // TSK-1052 CONTRACT: the dab dirties only its ~5x5 footprint (radius 2),
        // NOT the 64x64 canvas — so the renderer re-composites a sub-rect, not a
        // full rebuild per dab.
        let dirty = try XCTUnwrap(vm.consumeDirtyBounds(), "a dab must mark a dirty region")
        XCTAssertLessThan(dirty.width, 16,
            "dab dirty width is the brush footprint, not the full 64-wide canvas, got \(dirty.width)")
        XCTAssertLessThan(dirty.height, 16, "dab dirty height is the footprint, got \(dirty.height)")
        XCTAssertTrue(dirty.insetBy(dx: -1, dy: -1).contains(CGPoint(x: 30, y: 30)),
            "dirty region covers the dab centre, got \(dirty)")
        // consume RESETS — with no further paint the next consume is nil.
        XCTAssertNil(vm.consumeDirtyBounds(), "consume resets the accumulator")
    }

    func test_dirtyBounds_floodFill_marksFullCanvas() throws {
        let vm = try makeVM(w: 16, h: 16, r: 1, g: 1, b: 1)
        vm.tool = .floodFill
        vm.paintColor = .blue
        _ = vm.consumeDirtyBounds()   // clear any baseline
        _ = vm.applyTool(atX: 8, y: 8)
        // A flood fill can touch any contiguous region → it marks the FULL canvas
        // dirty (the incremental path correctly falls back to a full re-composite).
        let dirty = try XCTUnwrap(vm.consumeDirtyBounds(), "flood fill must mark dirty")
        XCTAssertEqual(dirty.width, 16, "flood fill dirties the full canvas width, got \(dirty.width)")
        XCTAssertEqual(dirty.height, 16, "flood fill dirties the full canvas height, got \(dirty.height)")
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

    func test_pasteImage_blitsClipboardImageAtSelectionOrigin() throws {
        let vm = try makeVM(w: 12, h: 12, r: 1, g: 1, b: 1)   // white
        // Stage a small red image on a scratch pasteboard (copy it from another VM).
        let red = try makeVM(w: 4, h: 4, r: 1, g: 0, b: 0)
        red.selectAll()
        let pb = NSPasteboard(name: NSPasteboard.Name("mdv-paste-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        XCTAssertTrue(red.copySelection(to: pb))
        // Paste into vm at the selection origin (2,2).
        vm.setSelection(.rect(x: 2, y: 2, width: 1, height: 1))
        XCTAssertTrue(vm.pasteImage(from: pb))
        let p = sample(vm.rendered!, x: 2, y: 2)
        XCTAssertGreaterThanOrEqual(p.r, 200)
        XCTAssertLessThanOrEqual(p.g, 60)
        XCTAssertLessThanOrEqual(p.b, 60, "pasted red landed at the selection origin")
        XCTAssertGreaterThanOrEqual(sample(vm.rendered!, x: 11, y: 11).r, 200,
                                    "the far corner stays white (paste was local)")
    }

    func test_canPaste_falseForEmptyPasteboard() throws {
        let vm = try makeVM(w: 8, h: 8)
        let pb = NSPasteboard(name: NSPasteboard.Name("mdv-empty-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        pb.clearContents()
        XCTAssertFalse(vm.canPaste(from: pb))
        XCTAssertFalse(vm.pasteImage(from: pb), "no image on the pasteboard → no-op")
    }

    // MARK: - move selection (TSK-1065)

    func test_moveSelection_movesPixelsAndClearsOriginal() throws {
        let vm = try makeVM(w: 12, h: 12, r: 1, g: 1, b: 1)   // white
        vm.tool = .brush
        vm.paintColor = .red
        vm.brushRadius = 0
        vm.applyTool(atX: 1, y: 1)                            // a red pixel at (1,1)
        vm.setSelection(.rect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertTrue(vm.moveSelection(byX: 6, y: 0))
        XCTAssertEqual(vm.selection, .rect(x: 6, y: 0, width: 4, height: 4),
                       "the selection follows the move")
        let moved = sample(vm.rendered!, x: 7, y: 1)
        XCTAssertGreaterThanOrEqual(moved.r, 200)
        XCTAssertLessThanOrEqual(moved.g, 60, "the red pixel moved to (7,1)")
        XCTAssertLessThanOrEqual(sample(vm.rendered!, x: 1, y: 1).a, 4,
                                 "the original region is cleared to transparent")
    }

    func test_moveSelection_noSelectionOrZero_isNoOp() throws {
        let vm = try makeVM(w: 8, h: 8)
        XCTAssertFalse(vm.moveSelection(byX: 2, y: 2), "no selection → no-op")
        vm.setSelection(.rect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertFalse(vm.moveSelection(byX: 0, y: 0), "zero move → no-op")
    }

    // MARK: - mask-aware ops for a polygon selection (TSK-1064 foundation)

    func test_deleteSelection_polygon_clearsOnlyInsideMask() throws {
        let vm = try makeVM(w: 10, h: 10, r: 1, g: 1, b: 1)   // opaque white
        vm.setSelection(.polygon([
            RasterPoint(x: 0, y: 0), RasterPoint(x: 8, y: 0), RasterPoint(x: 0, y: 8),
        ]))   // top-left triangle
        XCTAssertTrue(vm.deleteSelection())
        XCTAssertLessThanOrEqual(sample(vm.rendered!, x: 1, y: 1).a, 4,
                                 "inside the triangle → cleared")
        XCTAssertEqual(sample(vm.rendered!, x: 7, y: 7).a, 255,
                       "outside the triangle → opaque")
    }

    func test_selectionImage_polygon_masksOutsideToTransparent() throws {
        let vm = try makeVM(w: 10, h: 10, r: 1, g: 1, b: 1)
        vm.setSelection(.polygon([
            RasterPoint(x: 0, y: 0), RasterPoint(x: 8, y: 0), RasterPoint(x: 0, y: 8),
        ]))
        let img = try XCTUnwrap(vm.selectionImage())
        XCTAssertEqual(img.width, 9, "bbox width = maxX-minX+1")
        XCTAssertEqual(img.height, 9)
        XCTAssertLessThanOrEqual(sample(img, x: 8, y: 8).a, 4,
                                 "outside the polygon → transparent in the extract")
        XCTAssertEqual(sample(img, x: 1, y: 1).a, 255, "inside the polygon → opaque")
    }

    // MARK: - invert selection (TSK-1066)

    func test_invertSelection_togglesComplement() throws {
        let vm = try makeVM(w: 10, h: 10)
        vm.setSelection(.rect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertTrue(vm.invertSelection())
        guard case .everythingExcept = vm.selection else { return XCTFail("expected a complement") }
        XCTAssertTrue(vm.invertSelection(), "inverting again unwraps to the base")
        XCTAssertEqual(vm.selection, .rect(x: 0, y: 0, width: 4, height: 4))
    }

    func test_deleteSelection_inverted_clearsOutsideTheBase() throws {
        let vm = try makeVM(w: 10, h: 10, r: 1, g: 1, b: 1)   // white
        vm.setSelection(.rect(x: 0, y: 0, width: 4, height: 4))
        vm.invertSelection()                                  // everything EXCEPT the 4x4
        XCTAssertTrue(vm.deleteSelection())
        XCTAssertEqual(sample(vm.rendered!, x: 1, y: 1).a, 255,
                       "inside the excluded base → kept opaque")
        XCTAssertLessThanOrEqual(sample(vm.rendered!, x: 8, y: 8).a, 4,
                                 "the complement is cleared to transparent")
    }

    // MARK: - flip / rotate orient verbs (TSK-1072)

    func test_commitOrient_rotate90SwapsDimensions() throws {
        let vm = try makeVM(w: 20, h: 12)
        XCTAssertEqual(vm.rendered?.width, 20)
        vm.commitGeometry(.orient(.right90))
        XCTAssertEqual(vm.rendered?.width, 12, "90° rotate swaps width/height (orient op wired)")
        XCTAssertEqual(vm.rendered?.height, 20)
    }

    func test_commitOrient_flipPreservesDimensions() throws {
        let vm = try makeVM(w: 20, h: 12)
        vm.commitGeometry(.orient(.upMirrored))    // flip H
        XCTAssertEqual(vm.rendered?.width, 20, "a flip keeps dimensions")
        XCTAssertEqual(vm.rendered?.height, 12)
        vm.commitGeometry(.orient(.downMirrored))  // flip V
        XCTAssertEqual(vm.rendered?.width, 20)
        XCTAssertEqual(vm.rendered?.height, 12)
    }

    // MARK: - clear image (TSK-1077) + two-color (TSK-1069)

    func test_clearImage_fillsCanvasWithBackgroundColor() throws {
        let vm = try makeVM(w: 8, h: 8, r: 1, g: 1, b: 1)   // white
        vm.bgColor = RGBAColor(r: 0, g: 0, b: 255, a: 255)  // blue background
        XCTAssertTrue(vm.clearImage())
        let a = sample(vm.rendered!, x: 0, y: 0)
        let b = sample(vm.rendered!, x: 7, y: 7)
        XCTAssertGreaterThanOrEqual(a.b, 200); XCTAssertLessThanOrEqual(a.r, 60)
        XCTAssertGreaterThanOrEqual(b.b, 200, "the whole canvas is filled with the background color")
    }

    func test_swapColors_exchangesForegroundAndBackground() throws {
        let vm = try makeVM(w: 4, h: 4)
        vm.paintColor = .black
        vm.bgColor = .white
        vm.swapColors()
        XCTAssertEqual(vm.paintColor, .white)
        XCTAssertEqual(vm.bgColor, .black)
    }

    // MARK: - invert colors (TSK-1075)

    func test_invertColors_negatesPixels() throws {
        let vm = try makeVM(w: 6, h: 6, r: 1, g: 1, b: 1)   // white
        XCTAssertEqual(sample(vm.rendered!, x: 2, y: 2).r, 255)
        vm.commitGeometry(.invertColors)
        XCTAssertLessThanOrEqual(sample(vm.rendered!, x: 2, y: 2).r, 8, "white → black")
        XCTAssertLessThanOrEqual(sample(vm.rendered!, x: 2, y: 2).g, 8)
        XCTAssertLessThanOrEqual(sample(vm.rendered!, x: 2, y: 2).b, 8)
    }

    // MARK: - resize (TSK-1073)

    func test_commitResize_changesDimensions() throws {
        let vm = try makeVM(w: 20, h: 12)
        vm.commitGeometry(.resize(width: 40, height: 24))
        XCTAssertEqual(vm.rendered?.width, 40, "resize op applies the target dims")
        XCTAssertEqual(vm.rendered?.height, 24)
    }

    // MARK: - canvas size (TSK-1076)

    func test_commitCanvasSize_padsTopLeftWithoutScaling() throws {
        let vm = try makeVM(w: 8, h: 8, r: 1, g: 0, b: 0)   // red
        vm.commitGeometry(.canvasSize(width: 16, height: 12))
        XCTAssertEqual(vm.rendered?.width, 16, "canvas grew")
        XCTAssertEqual(vm.rendered?.height, 12)
        XCTAssertGreaterThanOrEqual(sample(vm.rendered!, x: 1, y: 1).r, 200,
                                    "the image stays at the top-left (not scaled)")
        XCTAssertLessThanOrEqual(sample(vm.rendered!, x: 15, y: 11).a, 4,
                                 "the new padded area is transparent")
    }

    func test_commitCanvasSize_cropsWhenSmaller() throws {
        let vm = try makeVM(w: 10, h: 10)
        vm.commitGeometry(.canvasSize(width: 4, height: 4))
        XCTAssertEqual(vm.rendered?.width, 4, "smaller canvas crops")
        XCTAssertEqual(vm.rendered?.height, 4)
    }

    // MARK: - BMP / GIF / TIFF write (TSK-1078/1079/1080)

    func test_exportData_bmpGifTiff_roundTrip() throws {
        let vm = try makeVM(w: 8, h: 8, r: 1, g: 0, b: 0)
        for fmt in [ExportSpec.Format.bmp, .gif, .tiff] {
            let data = try vm.exportData(format: fmt)
            XCTAssertFalse(data.isEmpty, "\(fmt) export produced bytes")
            let src = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil),
                                    "\(fmt) export decodes")
            let img = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
            XCTAssertEqual(img.width, 8, "\(fmt) width preserved")
            XCTAssertEqual(img.height, 8, "\(fmt) height preserved")
        }
    }

    // MARK: - dirty-rect accumulation (TSK-1052)

    func test_brushDab_accumulatesDirtyRect_thenConsumeResets() throws {
        let vm = try makeVM(w: 30, h: 30, r: 1, g: 1, b: 1)
        _ = vm.brushDab(atX: 15, y: 15)
        let dirty = try XCTUnwrap(vm.consumeDirtyBounds(), "a dab must mark a dirty rect")
        XCTAssertTrue(dirty.contains(CGPoint(x: 15.5, y: 15.5)), "dirty rect covers the dab centre")
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 30, height: 30).contains(dirty), "clamped to canvas")
        XCTAssertNil(vm.consumeDirtyBounds(), "consume resets to clean")
    }

    func test_floodFill_marksWholeCanvasDirty() throws {
        let vm = try makeVM(w: 20, h: 20, r: 1, g: 1, b: 1)
        _ = vm.floodFill(atX: 5, y: 5)
        XCTAssertEqual(vm.consumeDirtyBounds(), CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    func test_brushStroke_dirtyRectSpansBothEndpoints() throws {
        let vm = try makeVM(w: 40, h: 40, r: 1, g: 1, b: 1)
        _ = vm.brushStroke(fromX: 5, y0: 5, toX: 30, y1: 5)
        let dirty = try XCTUnwrap(vm.consumeDirtyBounds())
        XCTAssertTrue(dirty.contains(CGPoint(x: 5.5, y: 5.5)), "covers start")
        XCTAssertTrue(dirty.contains(CGPoint(x: 30.5, y: 5.5)), "covers end")
    }

    // MARK: - copy-to-file / paste-from-file (TSK-1067)

    func test_copyToFile_andPasteFromFile_roundTrip() throws {
        let src = try makeVM(w: 6, h: 6, r: 1, g: 0, b: 0)   // red
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-cf-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(src.copyToFile(to: url, format: .png))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let dest = try makeVM(w: 12, h: 12, r: 1, g: 1, b: 1)   // white
        dest.setSelection(.rect(x: 2, y: 2, width: 1, height: 1))
        XCTAssertTrue(dest.pasteImageFromFile(from: url))
        let p = sample(dest.rendered!, x: 3, y: 3)              // inside the pasted 6x6
        XCTAssertGreaterThanOrEqual(p.r, 200)
        XCTAssertLessThanOrEqual(p.g, 60, "pasted red from the file landed at the selection origin")
    }

    func test_pasteImageFromFile_missingFile_isNoOp() throws {
        let vm = try makeVM(w: 8, h: 8)
        XCTAssertFalse(vm.pasteImageFromFile(
            from: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).png")))
    }

    // MARK: - airbrush (TSK-1082)

    func test_airbrushDab_spraysAtCenter() throws {
        let vm = try makeVM(w: 20, h: 20, r: 1, g: 1, b: 1)   // white
        vm.tool = .airbrush
        vm.paintColor = .black
        vm.brushRadius = 5
        vm.airbrushDensity = 1.0   // full coverage → deterministic for the test
        let n = vm.airbrushDab(atX: 10, y: 10)
        XCTAssertGreaterThan(n, 0, "airbrush sprayed pixels")
        XCTAssertLessThanOrEqual(sample(vm.rendered!, x: 10, y: 10).r, 8,
                                 "the center is painted after a full-density spray")
    }

    func test_rasterTool_airbrush_isContinuous() {
        XCTAssertTrue(ImageEditorViewModel.RasterTool.airbrush.isContinuous)
    }

    // MARK: - in-place Save / Save As (TSK-1081)

    func test_sourceURL_reflectsDocumentSource() throws {
        let dataVM = try makeVM(w: 4, h: 4)
        XCTAssertNil(dataVM.sourceURL, "a data-backed (New Image) document has no source URL")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-src-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try solidPNG(width: 4, height: 4, r: 1, g: 0, b: 0).write(to: url)
        let urlVM = ImageEditorViewModel(ImageDocument(contentsOf: url))
        XCTAssertEqual(urlVM.sourceURL?.lastPathComponent, url.lastPathComponent,
                       "a file-backed document reports its URL")
    }

    func test_saveInPlace_overwritesSourceFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-ip-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try solidPNG(width: 8, height: 8, r: 0, g: 0, b: 1).write(to: url)   // blue
        let vm = ImageEditorViewModel(ImageDocument(contentsOf: url))
        vm.commitGeometry(.invertColors)                                     // blue → yellow
        let saved = await vm.saveCopyAsync(format: .png, to: url)
        XCTAssertTrue(saved, "in-place save writes back to the source URL")
        let reVM = ImageEditorViewModel(ImageDocument(contentsOf: url))
        let p = sample(reVM.rendered!, x: 4, y: 4)
        XCTAssertGreaterThanOrEqual(p.r, 200)
        XCTAssertGreaterThanOrEqual(p.g, 200)
        XCTAssertLessThanOrEqual(p.b, 60, "the re-read file shows the saved (inverted) edit")
    }

    // MARK: - skew (TSK-1074)

    func test_skew_horizontalGrowsWidthKeepsContent() throws {
        let vm = try makeVM(w: 20, h: 20, r: 1, g: 0, b: 0)   // red
        vm.commitGeometry(.skew(horizontalDegrees: 30, verticalDegrees: 0))
        let img = vm.rendered!
        XCTAssertGreaterThan(img.width, 20, "horizontal skew grows the width")
        XCTAssertEqual(img.height, 20, "vertical extent unchanged")
        let c = sample(img, x: img.width / 2, y: img.height / 2)
        XCTAssertGreaterThanOrEqual(c.r, 150, "image content survives at the center (not off-canvas)")
    }

    func test_skew_verticalGrowsHeight() throws {
        let vm = try makeVM(w: 20, h: 20)
        vm.commitGeometry(.skew(horizontalDegrees: 0, verticalDegrees: 30))
        XCTAssertGreaterThan(vm.rendered!.height, 20)
        XCTAssertEqual(vm.rendered!.width, 20)
    }

    func test_skew_zero_isNoOp() throws {
        let vm = try makeVM(w: 20, h: 12)
        vm.commitGeometry(.skew(horizontalDegrees: 0, verticalDegrees: 0))
        XCTAssertEqual(vm.rendered?.width, 20)
        XCTAssertEqual(vm.rendered?.height, 12)
    }

    // MARK: - recent colors (TSK-1118)

    func test_recordRecentColor_updatesRecentColorsNewestFirst() throws {
        let vm = try makeVM(w: 4, h: 4)
        vm.recordRecentColor(.red)
        vm.recordRecentColor(.blue)
        XCTAssertEqual(vm.recentColors, [.blue, .red], "newest-first MRU exposed on the VM")
    }

    func test_eyedropper_recordsRecentColor() throws {
        let vm = try makeVM(w: 4, h: 4, r: 0, g: 0, b: 1)   // blue
        _ = vm.pickColor(atX: 1, y: 1)
        XCTAssertEqual(vm.recentColors.first?.b, 255, "the eyedropper records the picked color")
    }
}
