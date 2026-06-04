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
        guard source.width > 0, source.height > 0, box.width > 0, box.height > 0 else {
            return (max(1, Int(box.width)), max(1, Int(box.height)))
        }
        let scale = min(box.width / source.width, box.height / source.height)
        let w = max(1, Int((source.width * scale).rounded()))
        let h = max(1, Int((source.height * scale).rounded()))
        return (w, h)
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

        /// The Uniform Type Identifier ImageIO keys the destination on.
        public var utType: UTType {
            switch self {
            case .png:  return .png
            case .jpeg: return .jpeg
            case .heic: return .heic
            }
        }

        /// Whether `quality` is meaningful for this format. PNG is lossless;
        /// the quality knob is ignored for it.
        public var isLossy: Bool {
            switch self {
            case .png:         return false
            case .jpeg, .heic: return true
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
