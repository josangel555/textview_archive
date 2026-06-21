import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Errors thrown across the image-editing engine boundary. Distinct cases so
/// callers (and the validation suite) can assert on the *reason* a render or
/// export failed, not just that it did. Mirrors `FileLoadError`'s flat,
/// `Equatable` shape so tests can `XCTAssertEqual` against an expected case.
public enum ImageEditError: Error, Equatable {
    /// The source bytes (or file) could not be decoded into a `CGImage` by
    /// ImageIO — corrupt data, an unsupported container, or an empty buffer.
    case sourceDecodeFailed
    /// The source `URL` did not resolve to a readable regular file.
    case sourceNotReadable
    /// A `CGContext` / `CGColorSpace` could not be constructed for the
    /// normalize-or-resize redraw. Should be unreachable for sane dimensions;
    /// surfaced rather than force-unwrapped so an OOM-on-huge-canvas degrades
    /// to a throw instead of a crash.
    case contextCreationFailed
    /// A geometric op produced an empty / degenerate result — e.g. a crop
    /// rect that, intersected with the image bounds, has zero area, or a
    /// resize to a non-positive dimension. Carries no payload: the offending
    /// op is recoverable from the document's `ops` by the caller.
    case degenerateGeometry
    /// `CGImageDestination` could not be created for, or failed to finalize,
    /// the requested export format. Usually an unsupported UTI for write.
    case encodeFailed
}

/// EXIF orientation tag (TIFF/EXIF "Orientation", values 1...8). The engine
/// bakes orientation into pixels at render time (rotating/flipping the raster)
/// so downstream consumers never have to honor a metadata flag. `Int` raw
/// value matches the on-disk EXIF tag so a future "read orientation from the
/// source file" path can map straight through `init(rawValue:)`.
///
/// The eight cases are the full EXIF set; names follow the canonical
/// "operation to apply to display correctly" reading (e.g. `.right90` means
/// the stored raster is rotated such that the scene's top is on the right and
/// must be rotated 90° to display upright).
public enum EXIFOrientation: Int, Sendable, Codable, Equatable, CaseIterable {
    case up = 1            // 0th row = top,    0th col = left  (no-op)
    case upMirrored = 2    // 0th row = top,    0th col = right (h-flip)
    case down = 3          // 0th row = bottom, 0th col = right (180°)
    case downMirrored = 4  // 0th row = bottom, 0th col = left  (v-flip)
    case leftMirrored = 5  // 0th row = left,   0th col = top   (transpose)
    case right90 = 6       // 0th row = right,  0th col = top   (90° CW)
    case rightMirrored = 7 // 0th row = right,  0th col = bottom(transverse)
    case left90 = 8        // 0th row = left,   0th col = bottom(90° CCW)

    /// True when applying this orientation swaps the width and height axes
    /// (the four 90°/270° cases). Lets the renderer size the destination
    /// canvas correctly before drawing.
    public var swapsAxes: Bool {
        switch self {
        case .leftMirrored, .right90, .rightMirrored, .left90: return true
        default: return false
        }
    }
}

/// A single, lossless, replayable edit. The whole edit history of an
/// `ImageDocument` is just an ordered array of these — there is no separate
/// "baked" raster kept around, so undo is literally dropping the last element
/// and the original source is never mutated.
///
/// IMPORTANT: every case here is geometry/sample-preserving in intent (it
/// describes *what* region/size/orientation, not *how well* it's encoded).
/// Lossy concerns (JPEG quality, chroma subsampling) live exclusively on
/// `ExportSpec` so that re-deriving the working image from `source + ops` is
/// always pixel-deterministic and never accumulates generational loss.
public enum EditOp: Sendable, Codable, Equatable {
    /// Crop to `rect`, expressed in **source pixel space** (origin top-left,
    /// integral pixels). The renderer intersects it with the current image
    /// bounds and integralizes it, so an out-of-bounds or fractional rect is
    /// clamped rather than rejected.
    case crop(CGRect)
    /// Resize to an exact `width` x `height` in pixels. Aspect-fit / fill is
    /// a *caller* policy: callers compute the target box via
    /// `EditOp.aspectFit(...)` and append the resulting exact dimensions, so
    /// the op itself stays unambiguous and replay is deterministic.
    case resize(width: Int, height: Int)
    /// Bake the given EXIF orientation into the raster.
    case orient(EXIFOrientation)
    /// Tonal adjustment via Core Image's `CIColorControls` (TSK-344). Identity
    /// is `(brightness: 0, contrast: 1, saturation: 1)`: `brightness` is
    /// additive (useful range ~−1…1), `contrast` multiplicative (range ~0…4,
    /// 1 = unchanged), `saturation` 0 = grayscale … 1 = unchanged … ~2 = vivid.
    /// Pure per-pixel color transform — geometry (dimensions) is unchanged, so
    /// it composes freely before/after crop/resize/orient.
    case colorControls(brightness: Double, contrast: Double, saturation: Double)
    /// Exposure adjustment in **photographic stops (EV)** via Core Image's
    /// `CIExposureAdjust` (TSK-344). Identity is `ev: 0`. Unlike
    /// `colorControls`'s additive `brightness`, this scales in *linear* light —
    /// `+1` EV ≈ doubling the light, `−1` ≈ halving — which is how a camera/photo
    /// editor models exposure. Per-pixel, geometry-preserving; composes freely
    /// with the other ops.
    case exposure(ev: Double)
    /// Shadow/highlight tone adjustment via Core Image's `CIHighlightShadowAdjust`
    /// (TSK-344). Identity is `(shadow: 0, highlight: 1)`. `shadow` 0…1 LIFTS the
    /// dark tones (brightens shadows) as it rises; `highlight` 1…0 PULLS DOWN the
    /// bright tones (recovers blown highlights) as it falls. A local-tone operator
    /// (not a flat per-pixel curve), geometry-preserving.
    case shadowHighlight(shadow: Double, highlight: Double)
    /// Luminance sharpening via Core Image's `CISharpenLuminance` (TSK-344).
    /// Identity is `sharpness: 0` (no sharpening); higher values increase local
    /// edge contrast (an unsharp-mask-style overshoot at edges). A no-op on flat
    /// regions — only edges are affected. Geometry-preserving.
    case sharpen(sharpness: Double)
    /// Invert the image's colors (photo-negative). Geometry-preserving. TSK-1075.
    case invertColors
    /// Paint a filled rectangle in **source pixel space** (top-left origin)
    /// onto the raster (TSK-749). The rect is integralized at render time; an
    /// out-of-bounds rect is clipped to the canvas. Geometry (dimensions) is
    /// preserved — drawing never resizes the canvas.
    case fillRect(CGRect, DrawColor)
    /// Stroke a rectangle's outline in source pixel space (TSK-749). `lineWidth`
    /// is in pixels; the stroke straddles the rect edge (CoreGraphics default).
    case strokeRect(CGRect, DrawColor, lineWidth: Double)
    /// Paint a filled ellipse inscribed in `rect` (source pixel space; TSK-749).
    case fillEllipse(CGRect, DrawColor)
    /// Stroke an ellipse inscribed in `rect` (source pixel space; TSK-749).
    case strokeEllipse(CGRect, DrawColor, lineWidth: Double)
    /// Stroke a line segment from `from` to `to` in source pixel space
    /// (top-left origin; TSK-749). `lineWidth` is in pixels; the cap is round so
    /// short segments still paint.
    case strokeLine(from: CGPoint, to: CGPoint, DrawColor, lineWidth: Double)
    /// Rasterize `text` anchored at `origin` (top-left of the first glyph's em
    /// box, source pixel space; TSK-749). `fontSize` is in pixels; the system
    /// font is used so the op is self-contained (no bundled font dependency).
    case drawText(String, origin: CGPoint, DrawColor, fontSize: Double)
}

/// A straight (non-premultiplied) RGBA color for the draw ops, each channel in
/// `0...1`. A tiny value type rather than `CGColor` so `EditOp` stays
/// `Codable`/`Equatable`/`Sendable` (CGColor is none of those) and the lossless
/// op-list serializes cleanly into a workspace snapshot. Channels are clamped to
/// `0...1` at construction so an out-of-range caller value can't produce an
/// undefined `CGColor`.
public struct DrawColor: Sendable, Codable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
        self.red = clamp(red)
        self.green = clamp(green)
        self.blue = clamp(blue)
        self.alpha = clamp(alpha)
    }

    /// The `CGColor` the renderer fills/strokes with, in the working sRGB space.
    /// Falls back to device RGB if the named sRGB space is somehow unavailable.
    public var cgColor: CGColor {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let comps: [CGFloat] = [CGFloat(red), CGFloat(green), CGFloat(blue), CGFloat(alpha)]
        return CGColor(colorSpace: space, components: comps)
            ?? CGColor(red: CGFloat(red), green: CGFloat(green),
                       blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    public static let black = DrawColor(red: 0, green: 0, blue: 0)
    public static let white = DrawColor(red: 1, green: 1, blue: 1)
    public static let red = DrawColor(red: 1, green: 0, blue: 0)
}

extension EditOp {
    /// Aspect-fit rounding helper (the rule the validation suite pins):
    /// scale `source` to fit inside `box` preserving aspect ratio, using the
    /// smaller of the two axis scales, then round each axis to the nearest
    /// integer with a floor of 1 (a sub-pixel result must not collapse to 0).
    ///
    /// Example from the spec: 1000x500 fit into 400x400 ⇒ scale 0.4 ⇒
    /// 400x200. Returned as exact dimensions to feed `.resize(width:height:)`.
    public static func aspectFit(source: CGSize, into box: CGSize) -> (width: Int, height: Int) {
        // Sanitize first: a NaN/Inf CGFloat fed to `Int()` is a hard runtime
        // trap (LLVM fptosi overflow), not a recoverable error — and every
        // `> 0` comparison against NaN is silently false, so a degenerate box
        // would otherwise fall straight into the else branch and crash on the
        // very `Int()` advertised as the graceful fallback. Reject any
        // non-finite or non-positive input up front with the (1,1) sentinel.
        guard source.width.isFinite, source.height.isFinite,
              box.width.isFinite, box.height.isFinite,
              source.width > 0, source.height > 0, box.width > 0, box.height > 0
        else {
            return (1, 1)
        }
        let scale = min(box.width / source.width, box.height / source.height)
        // `scale` is finite here (finite, positive operands), but guard the
        // products before `Int()` to be defensive against overflow to ±Inf.
        let w = Self.clampToInt(source.width * scale)
        let h = Self.clampToInt(source.height * scale)
        return (w, h)
    }

    /// Round a CGFloat to the nearest pixel and convert to `Int` with a floor
    /// of 1, never trapping: a non-finite or out-of-`Int`-range value collapses
    /// to the `1` floor instead of a `fptosi` runtime trap. The sole `Int()`
    /// chokepoint for the fit math so no caller can reintroduce a NaN/Inf trap.
    private static func clampToInt(_ value: CGFloat) -> Int {
        let rounded = value.rounded()
        // Strict `<` against `2^63`: `CGFloat(Int.max)` rounds up to exactly
        // `2^63`, which is one past the largest `Int`, so admitting it would let
        // `Int(_)` trap. `2^63` is itself exactly representable as a CGFloat.
        guard rounded.isFinite, rounded >= 1, rounded < 0x1p63 else {
            return 1
        }
        return Int(rounded)
    }
}

/// The reference to the original image bytes. Either a file `URL` we read
/// lazily at render time, or an in-memory `Data` blob. Kept as an enum (rather
/// than always materializing `Data`) so a document that references a 40 MB
/// file on disk stays cheap to hold, copy, and snapshot until something
/// actually renders it.
///
/// `Equatable`/`Codable` compare/serialize by the reference itself: two
/// `.data` sources are equal iff their bytes are equal (an O(N) compare, but
/// only when both sides are `.data` — the common `.url` case is O(path)).
public enum ImageSource: Sendable, Codable, Equatable {
    case url(URL)
    case data(Data)
}

/// A value-typed, serializable image-edit document: an immutable reference to
/// the source image plus an ordered, replayable list of edits. This is the
/// engine's single source of truth — the rendered raster is always a pure
/// function of `(source, ops)` via `Renderer.render(_:)`.
///
/// History *is* `ops`: `appending(_:)` pushes an edit, `undoingLast()` pops
/// one, `reverted()` clears them all back to the pristine source. Because no
/// lossy state is ever stored in `ops`, revert is guaranteed lossless.
///
/// `Sendable` + `Codable` + `Equatable` by design: the document can cross
/// actor boundaries, be persisted to a workspace snapshot, and be compared for
/// change detection without touching the (potentially large) pixel buffers —
/// equality is over the source reference and the op list, not decoded pixels.
public struct ImageDocument: Sendable, Codable, Equatable {
    /// The pristine source. Never mutated by an edit.
    public let source: ImageSource
    /// Ordered edit history, applied front-to-back at render time.
    public var ops: [EditOp]

    public init(source: ImageSource, ops: [EditOp] = []) {
        self.source = source
        self.ops = ops
    }

    /// Convenience for the common "open a file" entry point.
    public init(contentsOf url: URL, ops: [EditOp] = []) {
        self.init(source: .url(url), ops: ops)
    }

    /// Convenience for the in-memory entry point (e.g. paste, generated data).
    public init(data: Data, ops: [EditOp] = []) {
        self.init(source: .data(data), ops: ops)
    }

    // MARK: - History (lossless; the ops array *is* the history)

    /// Returns a copy with `op` appended to the history.
    public func appending(_ op: EditOp) -> ImageDocument {
        var copy = self
        copy.ops.append(op)
        return copy
    }

    /// Returns a copy with the most recent op removed (no-op if already empty).
    public func undoingLast() -> ImageDocument {
        guard !ops.isEmpty else { return self }
        var copy = self
        copy.ops.removeLast()
        return copy
    }

    /// Returns a copy with the entire history cleared — back to the pristine
    /// source. Lossless by construction: nothing lossy is ever stored in `ops`.
    public func reverted() -> ImageDocument {
        ImageDocument(source: source)
    }

    /// True when the document carries no edits (pristine source).
    public var isPristine: Bool { ops.isEmpty }
}

/// How to encode a rendered `CGImage` to bytes. Export-only — deliberately NOT
/// an `EditOp` — so the lossy/quality dimension never contaminates the
/// lossless edit history (see `EditOp` doc comment).
public struct ExportSpec: Sendable, Equatable {
    /// Output container formats the engine can encode. Each maps to a concrete
    /// UTI consumed by `CGImageDestination`. Kept as a small closed enum (not
    /// a free-form UTI) so the encode path can't be handed a write-unsupported
    /// type at runtime.
    public enum Format: Sendable, Equatable, CaseIterable {
        case png
        case jpeg
        case heic
        case bmp    // TSK-1078
        case gif    // TSK-1079
        case tiff   // TSK-1080

        /// The Uniform Type Identifier ImageIO keys the destination on.
        public var utType: UTType {
            switch self {
            case .png:  return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            case .bmp:  return .bmp
            case .gif:  return .gif
            case .tiff: return .tiff
            }
        }

        /// Whether `quality` is meaningful for this format. PNG/BMP/GIF/TIFF are
        /// lossless; the quality knob is ignored for them.
        public var isLossy: Bool {
            switch self {
            case .png, .bmp, .gif, .tiff: return false
            case .jpeg, .heic:            return true
            }
        }
    }

    public let format: Format
    /// Compression quality for lossy formats, clamped to `0...1` (1 = best).
    /// Ignored for `.png`. Clamped (not asserted) so an out-of-range caller
    /// value degrades gracefully.
    public let quality: Double
    /// When true, instruct ImageIO not to carry source metadata (EXIF/GPS/etc.)
    /// into the output. A privacy default for any "export for sharing" path.
    public let stripMetadata: Bool

    public init(format: Format, quality: Double = 0.9, stripMetadata: Bool = false) {
        self.format = format
        self.quality = min(max(quality, 0), 1)
        self.stripMetadata = stripMetadata
    }
}
