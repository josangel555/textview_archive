import AppKit
import Combine
import CoreGraphics
import Foundation
import ImageIO
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
        /// Pencil: a hard 1px brush (ignores the brush-size slider). TSK-1056.
        case pencil
        /// Eraser: a brush that paints transparency (erases to clear). TSK-1057.
        case eraser
        /// Airbrush: drag to spray a random scatter of paintColor. TSK-1082.
        case airbrush
        /// Paint bucket: a click flood-fills the contiguous region under it.
        case floodFill
        /// Rectangle: click-drag to draw a vector rectangle outline. TSK-1059.
        case drawRect
        /// Ellipse: click-drag to draw a vector ellipse outline. TSK-1060.
        case drawEllipse
        /// Rounded rectangle: click-drag, closed shape. TSK-1061.
        case drawRoundedRect
        /// Line: click-drag to draw a vector line (direction-preserving). TSK-1058.
        case drawLine
        /// Arrow: a line with a head at the end point. TSK-1058.
        case drawArrow
        /// Rectangular marquee: click-drag to select a region. TSK-1063.
        case selectRect
        /// Free-form lasso selection: drag a freehand region. TSK-1064.
        case selectLasso

        /// Tools that paint continuously along a drag (vs acting on a single click).
        var isContinuous: Bool {
            self == .brush || self == .eraser || self == .pencil || self == .airbrush
        }

        /// A selection tool (rectangular marquee or free-form lasso).
        var isSelection: Bool { self == .selectRect || self == .selectLasso }

        /// Tools that draw a vector shape by dragging out a bounding box.
        var isShape: Bool { shapeKind != nil }

        /// The vector-shape kind this tool draws, or nil for the non-shape tools.
        var shapeKind: VectorShape.Kind? {
            switch self {
            case .drawRect: return .rect
            case .drawEllipse: return .ellipse
            case .drawRoundedRect: return .roundedRect
            case .drawLine: return .line
            case .drawArrow: return .arrow
            default: return nil
            }
        }

        /// Open shapes (line / arrow) keep drag direction; closed shapes (rect /
        /// ellipse) are stored as a standardized box.
        var isOpenShape: Bool { self == .drawLine || self == .drawArrow }

        /// The color this tool paints with, given the user's selected `base`.
        /// The eraser paints transparency; every other tool uses `base`.
        func resolvedColor(base: RGBAColor) -> RGBAColor {
            self == .eraser ? .clear : base
        }

        /// The brush radius this tool paints with. The pencil is a hard 1px tool
        /// (radius 0 = a single pixel) regardless of the slider; others use `base`.
        func resolvedRadius(base: Int) -> Int {
            self == .pencil ? 0 : base
        }
    }

    /// The currently-selected paint tool.
    @Published public var tool: RasterTool = .none
    /// The active paint / fill color (the eyedropper writes here; brush & bucket
    /// read from here). Straight RGBA8.
    @Published public var paintColor: RGBAColor = .black
    /// TSK-1069 — the secondary / background color (Clear fills with it; a future
    /// two-color shape "both" mode uses fg=stroke, bg=fill). White by default.
    @Published public var bgColor: RGBAColor = .white
    /// Brush radius in pixels (0 = single pixel). Clamped non-negative on use.
    @Published public var brushRadius: Int = 4
    /// Flood-fill per-channel tolerance (0…255). 0 requires an exact color match.
    @Published public var fillTolerance: UInt8 = 0
    /// TSK-1059/1060 — when a shape tool draws, fill the shape (in addition to its
    /// outline) with the paint color. Off = outline only.
    @Published public var shapeFilled: Bool = false
    /// TSK-1062 — brush/eraser stamp shape: a square stamp when true, the default
    /// round disc otherwise. (No effect at radius 0 — that's always a single pixel.)
    @Published public var squareBrush: Bool = false
    /// TSK-1082 — airbrush spray coverage per dab (0…1). Repeated dabs build up.
    @Published public var airbrushDensity: Double = 0.25
    /// TSK-1063 — the active rectangular marquee selection (canvas pixels), or nil.
    @Published public private(set) var selection: RasterSelection?

    /// The destructive paint buffer for the current session, or `nil` when no
    /// paint has happened yet. Lazily baked from the rendered preview on the first
    /// paint op (or color pick), so an editor that never paints pays nothing.
    /// Once non-nil, it shadows the tonal/geometry render — `rendered` and export
    /// reflect the painted pixels (paint is destructive and cannot ride `ops`).
    @Published public private(set) var paintCanvas: RasterCanvas?
    // MARK: Vector annotations (TSK-287)

    /// Non-destructive vector annotation overlay (rect/line/arrow/ellipse),
    /// drawn OVER the rendered raster — never baked into the pixels (so it
    /// doesn't ride the lossless op-list, the way tonal/geometry edits do). The
    /// model is the host-tested `ViewerCore.VectorOverlay`; the editor view
    /// strokes it above the preview via `VectorOverlayView`. Held as STATE here
    /// (not in `base.ops`) because annotations are an editing-session concern,
    /// addressed by stable id, and orthogonal to the raster pipeline.
    @Published public private(set) var overlay = VectorOverlay()

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

    /// TSK-1081 — the document's original file URL, if it was opened from a file
    /// (nil for an unsaved New Image). In-place Save writes back here.
    public var sourceURL: URL? {
        if case let .url(u) = base.source { return u }
        return nil
    }

    /// `true` once any geometry op is committed, any tonal slider leaves identity,
    /// OR a destructive paint session has marked the surface — i.e. the rendered
    /// preview differs from the source.
    public var isEdited: Bool { !document.isPristine || paintCanvas != nil }

    /// Cancel-and-reschedule handle for the debounced slider render (TSK-1050).
    private var renderTask: Task<Void, Never>?

    /// Debounce window for `scheduleRender`. A slider drag fires many value
    /// changes per second; coalescing to one render ~after the user pauses keeps
    /// the editor responsive instead of running a full CoreImage pipeline per
    /// delta (the audit found the "view debounces" claim was never implemented).
    static let renderDebounce: Duration = .milliseconds(120)

    #if DEBUG
    /// Test gauge (TSK-1050): how many times `render()` actually ran. A burst of
    /// `scheduleRender()` calls must collapse to ONE bump after the debounce
    /// window; `scheduleRender()` must NOT bump it synchronously.
    public private(set) var renderCount = 0
    /// Test gauge (TSK-1051): how many times the source was actually decoded. The
    /// decode-once cache must keep this at 1 across many renders.
    public private(set) var decodeCount = 0
    #endif

    /// TSK-1051 — the normalized base image, decoded from the source ONCE and
    /// reused across renders (the source is immutable; ops replay on top). Decoding
    /// per render was the dominant cost for large images.
    private var decodedBase: CGImage?

    /// The cached decoded base, decoding (and caching) on first use.
    private func baseImage() throws -> CGImage {
        if let cached = decodedBase { return cached }
        let decoded = try Renderer.decodeBase(document)
        decodedBase = decoded
        #if DEBUG
        decodeCount += 1
        #endif
        return decoded
    }

    /// Coalesce rapid adjustment changes (slider drags) into a SINGLE render
    /// after a short pause (TSK-1050). Replaces the per-delta synchronous
    /// `render()` the sliders used to call, which ran the whole CoreImage
    /// pipeline on every drag tick and made the editor feel clunky. A render
    /// already in the debounce window is cancelled and rescheduled.
    public func scheduleRender() {
        renderTask?.cancel()
        renderTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.renderDebounce)
            if Task.isCancelled { return }
            self?.render()
        }
    }

    /// Re-render the preview + histogram from the current `document`. Sliders go
    /// through `scheduleRender()` (debounced); call this directly only for a
    /// discrete commit (geometry op, reset) that should render immediately.
    /// Failures are captured in `lastError` rather than thrown, so the editor
    /// can surface them without the binding layer having to handle errors.
    public func render() {
        #if DEBUG
        renderCount += 1
        #endif
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
            let image = try Renderer.render(document, base: baseImage())
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
        let n = canvas.brushDab(
            cx: x, cy: y, radius: tool.resolvedRadius(base: brushRadius),
            color: tool.resolvedColor(base: paintColor), square: squareBrush)
        paintCanvas = canvas
        render()
        return n
    }

    /// TSK-1082 — airbrush: spray a random scatter of `paintColor` (radius from the
    /// brush slider, `airbrushDensity` coverage) at `(x, y)`, then re-render.
    @discardableResult
    public func airbrushDab(atX x: Int, y: Int) -> Int {
        guard beginPaintSessionIfNeeded(), var canvas = paintCanvas else { return 0 }
        var rng = SystemRandomNumberGenerator()
        let n = canvas.spray(cx: x, cy: y, radius: Swift.max(2, brushRadius),
                             density: airbrushDensity, color: paintColor, using: &rng)
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
            from: (x0, y0), to: (x1, y1), radius: tool.resolvedRadius(base: brushRadius),
            color: tool.resolvedColor(base: paintColor), square: squareBrush)
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
        case .pencil:      return brushDab(atX: x, y: y)   // resolvedRadius → 0 (1px)
        case .eraser:      return brushDab(atX: x, y: y)   // resolvedColor → .clear
        case .airbrush:    return airbrushDab(atX: x, y: y)
        case .floodFill:   return floodFill(atX: x, y: y)
        // Shape tools are drag-committed via drawShape, not a click.
        // Drag-committed (shapes via drawShape, marquee via setSelection) — not a click.
        case .drawRect, .drawEllipse, .drawRoundedRect, .drawLine, .drawArrow,
             .selectRect, .selectLasso: return 0
        }
    }

    /// Discard the destructive paint session, returning the preview to the
    /// tonal/geometry render. Geometry/tonal edits are untouched.
    public func discardPaint() {
        guard paintCanvas != nil else { return }
        paintCanvas = nil
        render()
    }

    /// TSK-1077/1069 — clear the whole canvas to the BACKGROUND color (Image ▸ Clear).
    /// No-op if the canvas can't be baked.
    @discardableResult
    public func clearImage() -> Bool {
        guard beginPaintSessionIfNeeded(), var canvas = paintCanvas else { return false }
        canvas.fillRect(x: 0, y: 0, width: canvas.width, height: canvas.height, to: bgColor)
        paintCanvas = canvas
        render()
        return true
    }

    /// TSK-1069 — swap the foreground (paint) and background colors.
    public func swapColors() {
        let fg = paintColor
        paintColor = bgColor
        bgColor = fg
    }

    /// `true` when a destructive paint session has marked the surface.
    public var hasPaint: Bool { paintCanvas != nil }

    // MARK: - Vector annotations (TSK-287)

    /// Add a shape on top of the overlay (front-most). Returns its id so the
    /// caller can select the freshly-placed shape. No re-render needed — the
    /// overlay draws above the raster preview, not through `Renderer`.
    @discardableResult
    public func addShape(_ shape: VectorShape) -> UUID {
        overlay.add(shape)
        return shape.id
    }

    /// TSK-1059 — commit a drag-drawn vector shape of `kind` with a NORMALIZED
    /// (`0...1`) bounding box, styled with the current `paintColor` and a line
    /// width from the brush slider. Returns the new shape's id.
    @discardableResult
    public func drawShape(_ kind: VectorShape.Kind, normalizedFrame: CGRect) -> UUID {
        let stroke = OverlayColor(
            r: Double(paintColor.r) / 255, g: Double(paintColor.g) / 255,
            b: Double(paintColor.b) / 255, a: Double(paintColor.a) / 255)
        let style = ShapeStyle(stroke: stroke, lineWidth: max(2, Double(brushRadius)),
                               fill: shapeFilled ? stroke : nil)
        return addShape(VectorShape(kind: kind, frame: normalizedFrame, style: style))
    }

    /// Remove the shape with `id` (no-op for an unknown id).
    @discardableResult
    public func removeShape(id: UUID) -> Bool {
        overlay.remove(id: id)
    }

    /// Translate the shape with `id` by a normalized delta (no-op for unknown).
    @discardableResult
    public func moveShape(id: UUID, byX dx: CGFloat, y dy: CGFloat) -> Bool {
        overlay.move(id: id, byX: dx, y: dy)
    }

    /// Raise the shape with `id` one step in the z-order (no-op for unknown).
    @discardableResult
    public func bringShapeForward(id: UUID) -> Bool {
        overlay.bringForward(id: id)
    }

    /// Lower the shape with `id` one step in the z-order (no-op for unknown).
    @discardableResult
    public func sendShapeBackward(id: UUID) -> Bool {
        overlay.sendBackward(id: id)
    }

    /// Clear every vector annotation.
    public func clearShapes() {
        overlay.removeAll()
    }

    // MARK: - Selection (TSK-1063 / 1068)

    /// Set (or clear) the rectangular marquee selection.
    public func setSelection(_ sel: RasterSelection?) { selection = sel }

    /// Clear the active selection.
    public func clearSelection() { selection = nil }

    /// TSK-1068 — crop the image to the current rectangular selection. No-op
    /// (false) when there's no rect selection. Rides the lossless op-list
    /// (`EditOp.crop`, undoable); the selection is cleared after (it no longer
    /// maps once the image is cropped).
    @discardableResult
    public func cropToSelection() -> Bool {
        guard case let .rect(x, y, w, h) = selection, w >= 1, h >= 1 else { return false }
        commitGeometry(.crop(CGRect(x: x, y: y, width: w, height: h)))
        selection = nil
        return true
    }

    /// TSK-1066/1064 — clear the selected region to transparency (delete). Works
    /// for ANY selection (rect OR lasso polygon) via the mask-aware fill. No-op
    /// without a selection. Bakes a destructive paint session, like the eraser.
    @discardableResult
    public func deleteSelection() -> Bool {
        guard let sel = selection, sel.bounds != nil,
              beginPaintSessionIfNeeded(), var canvas = paintCanvas else { return false }
        canvas.fill(.clear, in: sel)
        paintCanvas = canvas
        render()
        return true
    }

    /// TSK-1066 — select the entire image.
    public func selectAll() {
        guard let img = rendered else { return }
        selection = .rect(x: 0, y: 0, width: img.width, height: img.height)
    }

    /// TSK-1066 — invert the selection: select everything OUTSIDE the current
    /// selection (its complement within the image). No-op without a selection.
    @discardableResult
    public func invertSelection() -> Bool {
        guard let sel = selection, let img = rendered else { return false }
        // Inverting an existing complement just unwraps back to the base.
        if case let .everythingExcept(base, _, _) = sel {
            selection = base
        } else {
            selection = .everythingExcept(sel, imageWidth: img.width, imageHeight: img.height)
        }
        return true
    }

    /// TSK-1066/1064 — the current selection as a standalone image: the rendered
    /// pixels in the selection's bounding box, with pixels OUTSIDE a lasso polygon
    /// cleared to transparency. Nil without a selection. Works for rect + polygon.
    public func selectionImage() -> CGImage? {
        guard let sel = selection, let b = sel.bounds, let img = rendered,
              let cropped = img.cropping(
                to: CGRect(x: b.x, y: b.y, width: b.width, height: b.height)) else { return nil }
        if case .rect = sel { return cropped }   // a rect's bbox IS the selection
        // Polygon: mask out pixels outside the lasso.
        guard var patch = RasterCanvas.from(cropped) else { return nil }
        for py in 0..<patch.height {
            for px in 0..<patch.width where !sel.contains(x: b.x + px, y: b.y + py) {
                patch.setPixel(x: px, y: py, to: .clear)
            }
        }
        return patch.cgImage()
    }

    /// TSK-1066 — copy the selected region to the pasteboard as an image.
    @discardableResult
    public func copySelection(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let cg = selectionImage() else { return false }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }

    /// TSK-1066 — cut: copy the selection to the pasteboard, then clear it.
    @discardableResult
    public func cutSelection(to pasteboard: NSPasteboard = .general) -> Bool {
        guard copySelection(to: pasteboard) else { return false }
        return deleteSelection()
    }

    /// TSK-1066 — true when the pasteboard holds an image (gates the Paste action).
    public func canPaste(from pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    /// TSK-1066 — paste a clipboard image, compositing it (source-over) onto the
    /// canvas with its top-left at the current selection's origin (or 0,0). No-op
    /// when the pasteboard has no image.
    @discardableResult
    public func pasteImage(from pasteboard: NSPasteboard = .general) -> Bool {
        guard let image = NSImage(pasteboard: pasteboard),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let src = RasterCanvas.from(cg),
              beginPaintSessionIfNeeded(), var canvas = paintCanvas else { return false }
        let ox: Int, oy: Int
        if case let .rect(x, y, _, _) = selection { ox = x; oy = y } else { ox = 0; oy = 0 }
        let n = canvas.blit(src, atX: ox, atY: oy)
        paintCanvas = canvas
        render()
        return n > 0
    }

    /// TSK-1067 — copy the selection (or the whole image if none) to an image FILE
    /// at `url`, encoded as `format`. Failures are captured in `lastError`.
    @discardableResult
    public func copyToFile(to url: URL, format: ExportSpec.Format = .png) -> Bool {
        guard let cg = selectionImage() ?? rendered else { return false }
        do {
            try Exporter.encode(cg, ExportSpec(format: format)).write(to: url, options: .atomic)
            lastError = nil
            return true
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    /// TSK-1067 — paste an image FILE at `url` onto the canvas (at the selection
    /// origin, or 0,0), source-over. Returns true if pixels were written.
    @discardableResult
    public func pasteImageFromFile(from url: URL) -> Bool {
        guard let imgSrc = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil),
              let src = RasterCanvas.from(cg),
              beginPaintSessionIfNeeded(), var canvas = paintCanvas else { return false }
        let ox: Int, oy: Int
        if case let .rect(x, y, _, _) = selection { ox = x; oy = y } else { ox = 0; oy = 0 }
        let n = canvas.blit(src, atX: ox, atY: oy)
        paintCanvas = canvas
        render()
        return n > 0
    }

    /// TSK-1065 — move the selected region by `(dx, dy)` canvas pixels: lift the
    /// selection's pixels, clear the original area to transparency, and composite
    /// them at the new offset. The selection follows. No-op without a rect
    /// selection or for a zero move.
    @discardableResult
    public func moveSelection(byX dx: Int, y dy: Int) -> Bool {
        guard case let .rect(x, y, w, h) = selection, dx != 0 || dy != 0 else { return false }
        guard let cg = selectionImage(), let patch = RasterCanvas.from(cg),
              beginPaintSessionIfNeeded(), var canvas = paintCanvas else { return false }
        canvas.fillRect(x: x, y: y, width: w, height: h, to: .clear)
        canvas.blit(patch, atX: x + dx, atY: y + dy)
        paintCanvas = canvas
        selection = .rect(x: x + dx, y: y + dy, width: w, height: h)
        render()
        return true
    }

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

    /// Save-a-Copy entry point for the view. Wraps `export` so any failure
    /// (encoder failure, disk full, dir not writable) is CAPTURED in
    /// `lastError` instead of being silently discarded by a `try?` — the
    /// view drove `try? vm.export(...)` after the save panel, so a failed
    /// write produced ZERO feedback and the user believed the copy landed
    /// (silent data loss). Returns `true` on success so the view can decide
    /// whether to additionally surface an alert; on failure `lastError` is
    /// set and the method returns `false`.
    @discardableResult
    public func saveCopy(format: ExportSpec.Format, quality: Double = 0.9, to url: URL) -> Bool {
        do {
            try export(format: format, quality: quality, to: url)
            lastError = nil
            return true
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    /// TSK-1053 — non-blocking Save-a-Copy: the encode + write run OFF the main
    /// actor (on a detached task) so a large image doesn't freeze the UI during
    /// save. All inputs are `Sendable` (document/canvas/spec/url), so the work
    /// crosses cleanly; `lastError`/the result are set back on the main actor.
    @discardableResult
    public func saveCopyAsync(
        format: ExportSpec.Format, quality: Double = 0.9, to url: URL
    ) async -> Bool {
        let spec = ExportSpec(format: format, quality: quality)
        let canvas = paintCanvas      // Sendable snapshot (paint shadows source+ops)
        let doc = document            // Sendable snapshot
        do {
            try await Task.detached(priority: .userInitiated) {
                let data: Data
                if let canvas, let image = canvas.cgImage() {
                    data = try Exporter.encode(image, spec)
                } else {
                    data = try Exporter.export(doc, spec)
                }
                try data.write(to: url, options: .atomic)
            }.value
            lastError = nil
            return true
        } catch {
            lastError = String(describing: error)
            return false
        }
    }
}

extension EditOp {
    /// `true` for the geometry-class ops that ride the lossless history
    /// (crop / resize / orient); `false` for the tonal ops the editor view-model
    /// derives from live slider state, and the draw ops (those are committable
    /// via `isCommittable` but are not "geometry" — they don't change dims).
    var isGeometry: Bool {
        switch self {
        case .crop, .resize, .canvasSize, .orient:
            return true
        case .colorControls, .exposure, .shadowHighlight, .sharpen, .invertColors,
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
        case .crop, .resize, .canvasSize, .orient, .invertColors,
             .fillRect, .strokeRect, .fillEllipse, .strokeEllipse,
             .strokeLine, .drawText:
            return true
        case .colorControls, .exposure, .shadowHighlight, .sharpen:
            return false
        }
    }
}
