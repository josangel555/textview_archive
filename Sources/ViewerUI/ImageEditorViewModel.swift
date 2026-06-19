import Combine
import CoreGraphics
import Foundation
import ViewerCore

/// Host-testable model layer for the image editor (TSK-342 UI enablement over
/// the TSK-344 engine). A SwiftUI editor view binds to this; the heavy lifting
/// (decode → ops → CGImage, histogram, export) all lives in the already-tested
/// `ViewerCore.Renderer` / `ImageDocument`, which run headless via Core Image
/// (no window) — so this layer carries REAL host teeth even though the view
/// that draws the preview + sliders is the render-gated remainder.
///
/// ## Why split tonal state from the op-list
/// `ImageDocument` is a *lossless* op-list. A naive editor that appended a new
/// `EditOp` on every slider tick would balloon the history with hundreds of
/// near-duplicate `colorControls` ops. Instead the live tonal sliders are held
/// as explicit STATE here (`brightness`, `contrast`, …) and folded into **one
/// op each** at render time via `document`. Dragging a slider mutates a single
/// derived op; the lossless history (`base.ops`) only ever holds the committed
/// GEOMETRY edits (crop / resize / orient), each individually undoable.
@MainActor
public final class ImageEditorViewModel: ObservableObject {

    /// Source + committed GEOMETRY/DRAW ops (crop / resize / orient / shapes /
    /// text). Tonal ops are NOT stored here — they are derived from the live
    /// slider state below so a drag never spams the lossless history. `base.ops`
    /// is kept in lock-step with `undoStack.current` (the source of truth for
    /// undo/redo); mutate it only through `commitGeometry` / `undo` / `redo` /
    /// `revertAll`, which drive the stack.
    @Published public private(set) var base: ImageDocument

    /// Bounded undo/redo history of the committed op list (TSK-749). Supports
    /// 1000+ entries (a long draw session) with a FIFO cap, plus redo — which
    /// the bare `ImageDocument.undoingLast()` could not. The view binds its
    /// Undo/Redo buttons to `canUndo` / `canRedo`.
    @Published public private(set) var undoStack: EditUndoStack

    // MARK: Live tonal slider state (identity defaults match the EditOp docs).

    /// `CIColorControls` brightness — additive, identity 0.
    @Published public var brightness: Double = 0
    /// `CIColorControls` contrast — multiplicative, identity 1.
    @Published public var contrast: Double = 1
    /// `CIColorControls` saturation — identity 1, 0 = greyscale.
    @Published public var saturation: Double = 1
    /// `CIExposureAdjust` EV — identity 0, scales in linear light.
    @Published public var exposureEV: Double = 0
    /// `CIHighlightShadowAdjust` shadow lift — identity 0.
    @Published public var shadow: Double = 0
    /// `CIHighlightShadowAdjust` highlight recovery — identity 1.
    @Published public var highlight: Double = 1
    /// `CISharpenLuminance` amount — identity 0.
    @Published public var sharpness: Double = 0

    // MARK: Raster paint tools (TSK-285) — color picker, brush, flood fill.

    /// The active raster paint tool. `.none` is the default (non-paint) mode where
    /// clicks select/inspect rather than mark the surface. Selecting a paint tool
    /// flips the editor into a destructive-paint session over a baked pixel buffer.
    public enum RasterTool: Sendable, Equatable, CaseIterable {
        /// No paint tool — sliders / geometry only (the default editor mode).
        case none
        /// Eyedropper: a click reads the pixel color into `paintColor` (no mutation).
        case colorPicker
        /// Brush: a click/drag stamps `paintColor` discs of radius `brushRadius`.
        case brush
        /// Paint bucket: a click flood-fills the contiguous region under it.
        case floodFill
    }

    /// The currently-selected paint tool.
    @Published public var tool: RasterTool = .none
    /// The active paint / fill color (the eyedropper writes here; brush & bucket
    /// read from here). Straight RGBA8.
    @Published public var paintColor: RGBAColor = .black
    /// Brush radius in pixels (0 = single pixel). Clamped non-negative on use.
    @Published public var brushRadius: Int = 4
    /// Flood-fill per-channel tolerance (0…255). 0 requires an exact color match.
    @Published public var fillTolerance: UInt8 = 0

    /// The destructive paint buffer for the current session, or `nil` when no
    /// paint has happened yet. Lazily baked from the rendered preview on the first
    /// paint op (or color pick), so an editor that never paints pays nothing.
    /// Once non-nil, it shadows the tonal/geometry render — `rendered` and export
    /// reflect the painted pixels (paint is destructive and cannot ride `ops`).
    @Published public private(set) var paintCanvas: RasterCanvas?

    // MARK: Derived outputs (republished on `render()`).

    /// The rendered preview of `document`, or `nil` if the last render failed.
    @Published public private(set) var rendered: CGImage?
    /// Per-channel histogram of `rendered` (read-only analysis, not an op).
    @Published public private(set) var histogram: Histogram?
    /// Human-readable description of the last render failure, else `nil`.
    @Published public private(set) var lastError: String?

    public init(_ document: ImageDocument) {
        self.base = document
        self.undoStack = EditUndoStack(baseline: document.ops)
        render()
    }

    /// `true` when there is a committed edit to undo (delegates to the stack).
    public var canUndo: Bool { undoStack.canUndo }
    /// `true` when there is a previously-undone edit to redo.
    public var canRedo: Bool { undoStack.canRedo }

    /// The full document to render / export: committed geometry history plus
    /// each non-identity tonal slider folded into a single op, applied in a
    /// fixed, deterministic order (colour → exposure → shadow/highlight →
    /// sharpen). Identity sliders contribute nothing — so a pristine editor
    /// renders byte-for-byte like the untouched source.
    public var document: ImageDocument {
        var doc = base
        if brightness != 0 || contrast != 1 || saturation != 1 {
            doc = doc.appending(.colorControls(
                brightness: brightness, contrast: contrast, saturation: saturation))
        }
        if exposureEV != 0 {
            doc = doc.appending(.exposure(ev: exposureEV))
        }
        if shadow != 0 || highlight != 1 {
            doc = doc.appending(.shadowHighlight(shadow: shadow, highlight: highlight))
        }
        if sharpness != 0 {
            doc = doc.appending(.sharpen(sharpness: sharpness))
        }
        return doc
    }

    /// `true` once any geometry op is committed, any tonal slider leaves identity,
    /// OR a destructive paint session has marked the surface — i.e. the rendered
    /// preview differs from the source.
    public var isEdited: Bool { !document.isPristine || paintCanvas != nil }

    /// Re-render the preview + histogram from the current `document`. Call after
    /// any slider change (the view debounces) or geometry commit. Failures are
    /// captured in `lastError` rather than thrown, so the editor can surface
    /// them without the binding layer having to handle errors.
    public func render() {
        // Once a paint session is active the painted buffer IS the document — paint
        // is destructive and cannot be re-derived from `source + ops`, so it
        // shadows the tonal/geometry render. The buffer was itself baked from a
        // prior tonal/geometry render, so committed edits are not lost.
        if let canvas = paintCanvas, let image = canvas.cgImage() {
            rendered = image
            histogram = try? Renderer.histogram(image)
            lastError = nil
            return
        }
        do {
            let image = try Renderer.render(document)
            rendered = image
            // Histogram is secondary read-only analysis — a failure there must
            // not blank the preview, so it's best-effort.
            histogram = try? Renderer.histogram(image)
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Commit a GEOMETRY or DRAW op (crop / resize / orient / shape / text) to
    /// the lossless history via the undo stack, then re-render. Tonal ops must
    /// NOT be committed this way — they ride the live slider state. A debug
    /// assertion guards that contract. Pushing onto the stack truncates any redo
    /// branch and enforces the cap (TSK-749).
    public func commitGeometry(_ op: EditOp) {
        assert(op.isCommittable, "commitGeometry expects a geometry/draw op; tonal ops ride the slider state")
        let next = base.appending(op).ops
        undoStack.push(next)
        base = base.appending(op)
        render()
    }

    /// Commit a draw op (filled/stroked rect, ellipse, line, or text) — a thin,
    /// intention-revealing alias over `commitGeometry` for the draw-tool UI
    /// (TSK-749). Draw ops are committed history (undoable), not slider state.
    public func commitDraw(_ op: EditOp) { commitGeometry(op) }

    /// Undo the most recently committed geometry/draw op via the stack (no-op
    /// when there is nothing to undo). Does not touch the tonal sliders.
    public func undoGeometry() { undo() }

    /// Undo the most recent committed op, syncing `base.ops` to the stack's new
    /// current state, then re-render.
    public func undo() {
        let state = undoStack.undo()
        base = ImageDocument(source: base.source, ops: state)
        render()
    }

    /// Redo the most recently undone committed op (no-op when there is no redo
    /// branch), then re-render.
    public func redo() {
        let state = undoStack.redo()
        base = ImageDocument(source: base.source, ops: state)
        render()
    }

    /// Reset every tonal slider to identity (leaves the geometry history
    /// intact), then re-render.
    public func resetTonal() {
        brightness = 0; contrast = 1; saturation = 1
        exposureEV = 0; shadow = 0; highlight = 1; sharpness = 0
        render()
    }

    /// Revert ALL edits: drop the committed history (and its undo/redo stack)
    /// and reset the tonal sliders, returning the preview to the pristine
    /// source. Clears redo as well — a deliberate "start over".
    public func revertAll() {
        base = base.reverted()
        undoStack.reset(to: [])
        paintCanvas = nil          // discard the destructive paint session too
        resetTonal()   // re-renders
    }

    // MARK: - Raster paint (TSK-285)

    /// Bake the current tonal/geometry render into a destructive `RasterCanvas`,
    /// creating the paint session on first use. Idempotent once a session exists
    /// (returns the existing buffer so a stroke never re-bakes mid-drag). Returns
    /// `false` if the current document can't be rendered/decoded into a buffer.
    @discardableResult
    public func beginPaintSessionIfNeeded() -> Bool {
        if paintCanvas != nil { return true }
        guard let image = (try? Renderer.render(document)),
              let canvas = RasterCanvas.from(image) else { return false }
        paintCanvas = canvas
        return true
    }

    /// Eyedropper: read the color at canvas pixel `(x, y)` into `paintColor`.
    /// Bakes a paint session if needed (so the read is against the same buffer the
    /// brush/bucket will mutate). A pure read — the canvas is unchanged. Returns
    /// the picked color, or `nil` if the point is outside the canvas.
    @discardableResult
    public func pickColor(atX x: Int, y: Int) -> RGBAColor? {
        guard beginPaintSessionIfNeeded(), let picked = paintCanvas?.pickColor(x: x, y: y)
        else { return nil }
        paintColor = picked
        return picked
    }

    /// Brush: stamp a single circular dab of `paintColor` (radius `brushRadius`)
    /// centred on canvas pixel `(x, y)`, then re-render. Returns the pixel count
    /// written (0 if off-canvas or the session couldn't be baked).
    @discardableResult
    public func brushDab(atX x: Int, y: Int) -> Int {
        guard beginPaintSessionIfNeeded(), var canvas = paintCanvas else { return 0 }
        let n = canvas.brushDab(cx: x, cy: y, radius: brushRadius, color: paintColor)
        paintCanvas = canvas
        render()
        return n
    }

    /// Brush drag: sweep a `paintColor` stroke (radius `brushRadius`) between two
    /// canvas pixels so a drag leaves a continuous mark, then re-render. Returns
    /// the distinct pixel count written.
    @discardableResult
    public func brushStroke(fromX x0: Int, y0: Int, toX x1: Int, y1: Int) -> Int {
        guard beginPaintSessionIfNeeded(), var canvas = paintCanvas else { return 0 }
        let n = canvas.brushStroke(
            from: (x0, y0), to: (x1, y1), radius: brushRadius, color: paintColor)
        paintCanvas = canvas
        render()
        return n
    }

    /// Paint bucket: flood-fill the contiguous region under canvas pixel `(x, y)`
    /// with `paintColor` (using `fillTolerance`), then re-render. Returns the
    /// pixel count changed.
    @discardableResult
    public func floodFill(atX x: Int, y: Int) -> Int {
        guard beginPaintSessionIfNeeded(), var canvas = paintCanvas else { return 0 }
        let n = canvas.floodFill(x: x, y: y, with: paintColor, tolerance: fillTolerance)
        paintCanvas = canvas
        render()
        return n
    }

    /// Apply the paint tool currently selected (`tool`) at canvas pixel `(x, y)`.
    /// The single entry point the view's click handler calls — it dispatches to
    /// the eyedropper / brush / bucket, and is a no-op for `.none`. Returns the
    /// pixels affected (or `1`/`0` for the eyedropper's read).
    @discardableResult
    public func applyTool(atX x: Int, y: Int) -> Int {
        switch tool {
        case .none:        return 0
        case .colorPicker: return pickColor(atX: x, y: y) == nil ? 0 : 1
        case .brush:       return brushDab(atX: x, y: y)
        case .floodFill:   return floodFill(atX: x, y: y)
        }
    }

    /// Discard the destructive paint session, returning the preview to the
    /// tonal/geometry render. Geometry/tonal edits are untouched.
    public func discardPaint() {
        guard paintCanvas != nil else { return }
        paintCanvas = nil
        render()
    }

    /// `true` when a destructive paint session has marked the surface.
    public var hasPaint: Bool { paintCanvas != nil }

    // MARK: - Export

    /// Encode the current edited `document` (geometry history + live tonal
    /// state) to image bytes in the given format. `quality` is clamped to 0…1
    /// and ignored for the lossless PNG format. This is the editor's "Export"
    /// flow — it re-derives from `source + ops`, so it always exports the WYSIWYG
    /// preview, never the untouched source.
    ///
    /// When a destructive paint session is active, the painted buffer IS the
    /// WYSIWYG preview (it can't ride the lossless op-list), so export encodes
    /// the painted `CGImage` directly instead of re-deriving from `source + ops`.
    public func exportData(format: ExportSpec.Format, quality: Double = 0.9) throws -> Data {
        let spec = ExportSpec(format: format, quality: quality)
        if let canvas = paintCanvas, let image = canvas.cgImage() {
            return try Exporter.encode(image, spec)
        }
        return try Exporter.export(document, spec)
    }

    /// Encode the current edited `document` and write it atomically to `url`.
    public func export(format: ExportSpec.Format, quality: Double = 0.9, to url: URL) throws {
        try exportData(format: format, quality: quality).write(to: url, options: .atomic)
    }
}

extension EditOp {
    /// `true` for the geometry-class ops that ride the lossless history
    /// (crop / resize / orient); `false` for the tonal ops the editor view-model
    /// derives from live slider state, and the draw ops (those are committable
    /// via `isCommittable` but are not "geometry" — they don't change dims).
    var isGeometry: Bool {
        switch self {
        case .crop, .resize, .orient:
            return true
        case .colorControls, .exposure, .shadowHighlight, .sharpen,
             .fillRect, .strokeRect, .fillEllipse, .strokeEllipse,
             .strokeLine, .drawText:
            return false
        }
    }

    /// `true` for ops the view-model commits to the lossless undo history —
    /// geometry (crop/resize/orient) plus the draw ops (shapes/text). Tonal ops
    /// are excluded: they ride the live slider state and fold into one op each at
    /// render time, so committing them would spam the history (TSK-749).
    var isCommittable: Bool {
        switch self {
        case .crop, .resize, .orient,
             .fillRect, .strokeRect, .fillEllipse, .strokeEllipse,
             .strokeLine, .drawText:
            return true
        case .colorControls, .exposure, .shadowHighlight, .sharpen:
            return false
        }
    }
}
