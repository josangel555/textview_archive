import Combine
import CoreGraphics
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

    /// Source + committed GEOMETRY ops (crop / resize / orient). Tonal ops are
    /// NOT stored here — they are derived from the live slider state below so a
    /// drag never spams the lossless history.
    @Published public private(set) var base: ImageDocument

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
        render()
    }

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

    /// Commit a GEOMETRY op (crop / resize / orient) to the lossless history,
    /// then re-render. Tonal ops must NOT be committed this way — they ride the
    /// live slider state. A debug assertion guards that contract.
    public func commitGeometry(_ op: EditOp) {
        assert(op.isGeometry, "commitGeometry expects a geometry op; tonal ops ride the slider state")
        base = base.appending(op)
        render()
    }

    /// Undo the most recently committed geometry op (no-op when the history is
    /// empty). Does not touch the tonal sliders.
    public func undoGeometry() {
        base = base.undoingLast()
        render()
    }

    /// Reset every tonal slider to identity (leaves the geometry history
    /// intact), then re-render.
    public func resetTonal() {
        brightness = 0; contrast = 1; saturation = 1
        exposureEV = 0; shadow = 0; highlight = 1; sharpness = 0
        render()
    }

    /// Revert ALL edits: drop the geometry history and reset the tonal sliders,
    /// returning the preview to the pristine source.
    public func revertAll() {
        base = base.reverted()
        resetTonal()   // re-renders
    }
}

extension EditOp {
    /// `true` for the geometry-class ops that ride the lossless history
    /// (crop / resize / orient); `false` for the tonal ops the editor view-model
    /// derives from live slider state.
    var isGeometry: Bool {
        switch self {
        case .crop, .resize, .orient:
            return true
        case .colorControls, .exposure, .shadowHighlight, .sharpen:
            return false
        }
    }
}
