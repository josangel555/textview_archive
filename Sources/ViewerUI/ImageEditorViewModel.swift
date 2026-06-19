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

    /// `true` once any geometry op is committed or any tonal slider leaves
    /// identity — i.e. the rendered preview differs from the source.
    public var isEdited: Bool { !document.isPristine }

    /// Re-render the preview + histogram from the current `document`. Call after
    /// any slider change (the view debounces) or geometry commit. Failures are
    /// captured in `lastError` rather than thrown, so the editor can surface
    /// them without the binding layer having to handle errors.
    public func render() {
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
        resetTonal()   // re-renders
    }

    // MARK: - Export

    /// Encode the current edited `document` (geometry history + live tonal
    /// state) to image bytes in the given format. `quality` is clamped to 0…1
    /// and ignored for the lossless PNG format. This is the editor's "Export"
    /// flow — it re-derives from `source + ops`, so it always exports the WYSIWYG
    /// preview, never the untouched source.
    public func exportData(format: ExportSpec.Format, quality: Double = 0.9) throws -> Data {
        try Exporter.export(document, ExportSpec(format: format, quality: quality))
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
