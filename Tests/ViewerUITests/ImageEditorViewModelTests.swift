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

    // MARK: - TSK-1050: slider render is debounced (no per-delta CoreImage run)

    /// `scheduleRender()` must NOT render synchronously — that's the per-drag
    /// stall the audit flagged (the slider used to call `render()` on every
    /// value delta). Reverting the slider to call `render()` directly would make
    /// this bump synchronously and fail.
    func test_scheduleRender_doesNotRenderSynchronously() throws {
        let vm = try makeVM()
        let before = vm.renderCount
        vm.brightness = 0.5
        vm.scheduleRender()
        XCTAssertEqual(vm.renderCount, before,
                       "scheduleRender must defer — no synchronous per-delta render")
    }

    /// A burst of slider changes (a drag) must collapse into exactly ONE render
    /// once the debounce window elapses, not one render per delta.
    func test_scheduleRender_coalescesBurstIntoOneRender() async throws {
        let vm = try makeVM()
        let before = vm.renderCount
        for v in stride(from: 0.0, through: 1.0, by: 0.05) {
            vm.brightness = v
            vm.scheduleRender()
        }
        // Wait comfortably past the debounce window for the single flush.
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(vm.renderCount, before + 1,
                       "a drag's burst of changes must coalesce to ONE render")
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

    // MARK: - Undo / redo stack (TSK-749)

    func test_commitGeometry_pushesUndoStack_undoRedoRoundTrip() throws {
        let vm = try makeVM()
        XCTAssertFalse(vm.canUndo)
        XCTAssertFalse(vm.canRedo)

        vm.commitGeometry(.resize(width: 20, height: 15))
        XCTAssertTrue(vm.canUndo)
        XCTAssertFalse(vm.canRedo)
        XCTAssertEqual(vm.rendered?.width, 20)

        vm.undo()
        XCTAssertEqual(vm.rendered?.width, 40, "undo restores the source dims")
        XCTAssertTrue(vm.base.ops.isEmpty)
        XCTAssertFalse(vm.canUndo)
        XCTAssertTrue(vm.canRedo, "undone resize is redoable")

        vm.redo()
        XCTAssertEqual(vm.rendered?.width, 20, "redo re-applies the resize")
        XCTAssertEqual(vm.base.ops.count, 1)
        XCTAssertFalse(vm.canRedo)
    }

    func test_commitAfterUndo_truncatesRedo() throws {
        let vm = try makeVM()
        vm.commitGeometry(.resize(width: 20, height: 20))
        vm.commitGeometry(.orient(.right90))
        vm.undo()                       // back to the resize-only state
        XCTAssertTrue(vm.canRedo)
        vm.commitGeometry(.resize(width: 10, height: 10)) // new edit discards redo
        XCTAssertFalse(vm.canRedo, "a fresh commit after undo discards the redo branch")
        XCTAssertEqual(vm.rendered?.width, 10)
    }

    func test_commitDraw_isUndoable_andPaintsPixels() throws {
        let vm = try makeVM(r: 1, g: 1, b: 1) // white 40x30 canvas
        vm.commitDraw(.fillRect(CGRect(x: 0, y: 0, width: 40, height: 30),
                                DrawColor(red: 1, green: 0, blue: 0)))
        // The whole canvas should now be red.
        let painted = sample(vm.rendered!, x: 20, y: 15)
        XCTAssertGreaterThan(painted.r, 200)
        XCTAssertLessThan(painted.g, 60)
        XCTAssertTrue(vm.canUndo, "a draw op is committed history (undoable)")

        vm.undo()
        let restored = sample(vm.rendered!, x: 20, y: 15)
        XCTAssertGreaterThan(restored.r, 200)
        XCTAssertGreaterThan(restored.g, 200, "undo removes the red fill (back to white)")
        XCTAssertGreaterThan(restored.b, 200)
    }

    func test_revertAll_clearsUndoAndRedo() throws {
        let vm = try makeVM()
        vm.commitGeometry(.resize(width: 20, height: 15))
        vm.undo()
        XCTAssertTrue(vm.canRedo)
        vm.commitGeometry(.orient(.right90))
        XCTAssertTrue(vm.canUndo)

        vm.revertAll()
        XCTAssertFalse(vm.canUndo, "revertAll clears the undo history")
        XCTAssertFalse(vm.canRedo, "revertAll clears the redo branch")
        XCTAssertTrue(vm.base.ops.isEmpty)
    }

    func test_undoStack_handlesManyDrawCommits() throws {
        let vm = try makeVM(r: 1, g: 1, b: 1)
        // A long draw session — well into the 1000+ undo regime (kept modest so
        // the headless render loop stays fast; the deep cap is pinned in the
        // pure EditUndoStack tests).
        for i in 0..<60 {
            vm.commitDraw(.fillRect(CGRect(x: 0, y: 0, width: 1, height: 1),
                                    DrawColor(red: Double(i % 2), green: 0, blue: 0)))
        }
        XCTAssertEqual(vm.undoStack.count, 61, "60 draw commits + baseline retained")
        XCTAssertTrue(vm.canUndo)
        // Undo all the way back to the pristine baseline.
        for _ in 0..<60 { vm.undo() }
        XCTAssertFalse(vm.canUndo)
        XCTAssertTrue(vm.base.ops.isEmpty, "deep undo reaches the pristine document")
    }

    // MARK: - Vector annotations (TSK-287)

    /// The view-model passthroughs over the host-tested `VectorOverlay` — the
    /// exact closures the editor's annotation buttons fire. Pins the interaction
    /// BEHAVIOUR (add / clear / move / z-order) so a wiring regression fails the
    /// host gate even though the on-screen draw is VM-only.

    func test_addShape_appendsToOverlay_andReturnsId() throws {
        let vm = try makeVM()
        XCTAssertTrue(vm.overlay.isEmpty)
        let id = vm.addShape(ImageEditorView.centeredShape(.rect))
        XCTAssertEqual(vm.overlay.count, 1)
        XCTAssertEqual(vm.overlay.shapes.first?.id, id)
        XCTAssertEqual(vm.overlay.shapes.first?.kind, .rect)
        // Annotations are an overlay, NOT a raster edit: the document stays
        // pristine and the rendered size is unchanged.
        XCTAssertTrue(vm.document.isPristine)
        XCTAssertEqual(vm.rendered?.width, 40)
    }

    func test_centeredShape_kindsAndDefaults() {
        for kind in VectorShape.Kind.allCases {
            let s = ImageEditorView.centeredShape(kind)
            XCTAssertEqual(s.kind, kind)
            XCTAssertEqual(s.style.stroke, .red)
            // The frame sits inside the normalized canvas.
            XCTAssertGreaterThanOrEqual(s.frame.minX, 0)
            XCTAssertLessThanOrEqual(s.frame.maxX, 1)
        }
    }

    func test_removeAndClearShapes() throws {
        let vm = try makeVM()
        let a = vm.addShape(ImageEditorView.centeredShape(.rect))
        vm.addShape(ImageEditorView.centeredShape(.line))
        XCTAssertTrue(vm.removeShape(id: a))
        XCTAssertEqual(vm.overlay.count, 1)
        XCTAssertFalse(vm.removeShape(id: a))   // already gone
        vm.clearShapes()
        XCTAssertTrue(vm.overlay.isEmpty)
    }

    func test_moveShape_translatesOrigin() throws {
        let vm = try makeVM()
        let id = vm.addShape(VectorShape(
            kind: .rect, frame: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)))
        XCTAssertTrue(vm.moveShape(id: id, byX: 0.2, y: 0.1))
        let moved = vm.overlay.shape(id: id)!
        XCTAssertEqual(moved.frame.origin.x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(moved.frame.origin.y, 0.2, accuracy: 1e-9)
    }

    func test_zOrderPassthroughs() throws {
        let vm = try makeVM()
        let a = vm.addShape(ImageEditorView.centeredShape(.rect))   // back
        let b = vm.addShape(ImageEditorView.centeredShape(.ellipse))// front
        XCTAssertTrue(vm.bringShapeForward(id: a))   // a -> front
        XCTAssertEqual(vm.overlay.index(of: a), 1)
        XCTAssertEqual(vm.overlay.index(of: b), 0)
        XCTAssertTrue(vm.sendShapeBackward(id: a))   // a -> back
        XCTAssertEqual(vm.overlay.index(of: a), 0)
    }

    // MARK: - Vector-shape selection + edit-after-placement (TSK-1321)

    func test_selectLatestShape_thenMove_translatesOnlyThatShape() throws {
        let vm = try makeVM()
        let a = vm.addShape(VectorShape(kind: .rect, frame: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)))
        let b = vm.addShape(VectorShape(kind: .ellipse, frame: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)))
        vm.selectLatestShape()
        XCTAssertEqual(vm.selectedShapeID, b, "latest = the front-most (most-recently-added)")
        let before = try XCTUnwrap(vm.selectedShape).frame.origin
        XCTAssertTrue(vm.moveSelectedShape(byX: 0.1, y: 0.05))
        let after = try XCTUnwrap(vm.selectedShape).frame.origin
        XCTAssertEqual(after.x, before.x + 0.1, accuracy: 1e-9)
        XCTAssertEqual(after.y, before.y + 0.05, accuracy: 1e-9)
        XCTAssertEqual(vm.overlay.shape(id: a)?.frame.minX ?? -1, 0.1, accuracy: 1e-9, "other shapes untouched")
    }

    func test_resizeAndRestyleSelected_thenRemoveClearsSelection() throws {
        let vm = try makeVM()
        let id = vm.addShape(VectorShape(kind: .rect, frame: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)))
        vm.selectShape(id: id)
        XCTAssertTrue(vm.resizeSelectedShape(to: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)))
        XCTAssertEqual(vm.selectedShape?.frame, CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4))
        let red = ShapeStyle(stroke: OverlayColor(r: 1, g: 0, b: 0, a: 1), lineWidth: 5, fill: nil)
        XCTAssertTrue(vm.restyleSelectedShape(red))
        XCTAssertEqual(vm.selectedShape?.style.lineWidth, 5)
        _ = vm.removeShape(id: id)
        XCTAssertNil(vm.selectedShapeID, "removing the selected shape clears the selection")
        XCTAssertNil(vm.selectedShape)
    }

    func test_selectedShapeOps_noopWithoutSelection() throws {
        let vm = try makeVM()
        _ = vm.addShape(VectorShape(kind: .rect, frame: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)))
        vm.deselectShape()
        XCTAssertFalse(vm.moveSelectedShape(byX: 0.1, y: 0))
        XCTAssertFalse(vm.resizeSelectedShape(to: .zero))
        XCTAssertFalse(vm.restyleSelectedShape(
            ShapeStyle(stroke: OverlayColor(r: 0, g: 0, b: 0, a: 1), lineWidth: 1, fill: nil)))
    }

    /// `ImageEditorView.aspectFitRect` maps the overlay's normalized coords into
    /// the rect the fitted image occupies — the load-bearing geometry the draw
    /// path relies on. Host-test the math (no rendering).
    func test_aspectFitRect_centersFittedImage() {
        // 100x50 image fit into a 200x200 box: scale 2 ⇒ 200x100, centered vert.
        let r = ImageEditorView.aspectFitRect(
            imageSize: CGSize(width: 100, height: 50),
            in: CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(r.width, 200, accuracy: 1e-9)
        XCTAssertEqual(r.height, 100, accuracy: 1e-9)
        XCTAssertEqual(r.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(r.minY, 50, accuracy: 1e-9)   // (200-100)/2
        // Degenerate inputs ⇒ .zero (overlay draws nothing).
        XCTAssertEqual(ImageEditorView.aspectFitRect(
            imageSize: .zero, in: CGRect(x: 0, y: 0, width: 10, height: 10)), .zero)
    }

    // MARK: - L-eh1: Save-a-Copy surfaces write failures (TSK-1008)

    /// A write into a directory that does NOT exist makes the atomic write
    /// throw. The OLD view used `try? vm.export(...)` and swallowed that —
    /// no `lastError`, no signal, silent data loss. `saveCopy` must capture
    /// the failure in `lastError` and return `false`. FAILS on the old code
    /// path (which had no `lastError`-capturing wrapper at all).
    func test_saveCopy_writeFailure_setsLastError_returnsFalse() throws {
        let vm = try makeVM()
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-no-such-dir-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("out.png")
        XCTAssertNil(vm.lastError)
        let ok = vm.saveCopy(format: .png, to: bogus)
        XCTAssertFalse(ok, "a failed write must report failure, not success")
        XCTAssertNotNil(vm.lastError, "the swallowed export failure must surface in lastError")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bogus.path))
    }

    /// A successful save returns `true` and clears any prior `lastError`.
    func test_saveCopy_success_writesFile_clearsLastError() throws {
        let vm = try makeVM()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-editor-savecopy-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        // Seed a stale error to prove a clean save clears it.
        _ = vm.saveCopy(format: .png, to: FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-no-such-dir-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("x.png"))
        XCTAssertNotNil(vm.lastError)
        let ok = vm.saveCopy(format: .png, to: url)
        XCTAssertTrue(ok)
        XCTAssertNil(vm.lastError, "a clean save clears the prior error")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
