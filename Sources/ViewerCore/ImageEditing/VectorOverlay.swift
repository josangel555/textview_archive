import CoreGraphics
import Foundation

/// A non-destructive **vector annotation overlay** for the image editor
/// (TSK-287): shapes-as-data laid OVER the rendered raster, never baked into the
/// pixels. This is deliberately a separate layer from `EditOp` — `EditOp` is a
/// lossless *pixel* transform (crop/resize/orient/tone) replayed by the
/// `Renderer`, whereas a `VectorShape` is a resolution-independent mark
/// (rectangle, line, arrow, ellipse) that the SwiftUI overlay strokes/fills
/// above the preview. Keeping them apart means annotations can be moved,
/// reordered, and deleted freely without ever touching the source raster.
///
/// ## Coordinate space
/// All geometry is expressed in **normalized image space** — `0...1` along each
/// axis with origin at the top-left, matching `CGImage`'s row-major raster
/// convention (same as `EditOp.crop`). Normalized coordinates make the overlay
/// independent of the on-screen preview size and of any `resize` op: a shape
/// pinned to the centre of the image stays centred whether the preview is 200pt
/// or 2000pt wide. The view layer multiplies by the displayed frame to draw.
///
/// Pure value types: `Sendable` + `Codable` + `Equatable` so the overlay can
/// cross actor boundaries, persist into a workspace snapshot alongside the
/// `ImageDocument`, and be diffed for change detection without any rendering.

// MARK: - Color

/// A serializable straight-alpha RGBA color in `0...1` components, sRGB. Defined
/// here (rather than leaning on `CGColor`, which is neither `Codable` nor
/// `Equatable` in a stable way) so the overlay round-trips losslessly through
/// JSON. The view layer converts to `SwiftUI.Color` / `CGColor` at draw time.
public struct OverlayColor: Sendable, Codable, Equatable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    /// Components are clamped to `0...1` on construction so a malformed caller
    /// value (or a corrupt persisted blob) degrades to an in-gamut color rather
    /// than producing an undefined `CGColor` at draw time.
    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = Self.clamp(r)
        self.g = Self.clamp(g)
        self.b = Self.clamp(b)
        self.a = Self.clamp(a)
    }

    private static func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(max(v, 0), 1)
    }

    // Clamp again on decode: a hand-edited / corrupt snapshot must not smuggle
    // out-of-range components past the validating initializer.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            r: try c.decode(Double.self, forKey: .r),
            g: try c.decode(Double.self, forKey: .g),
            b: try c.decode(Double.self, forKey: .b),
            a: try c.decode(Double.self, forKey: .a))
    }

    public static let black = OverlayColor(r: 0, g: 0, b: 0)
    public static let white = OverlayColor(r: 1, g: 1, b: 1)
    public static let red = OverlayColor(r: 1, g: 0, b: 0)
    public static let clear = OverlayColor(r: 0, g: 0, b: 0, a: 0)
}

// MARK: - Style

/// Stroke + fill styling shared by every shape kind. Identity is a 2pt opaque
/// black stroke with no fill — the conventional "draw an outline" default.
public struct ShapeStyle: Sendable, Codable, Equatable {
    /// Stroke color. `stroke.a == 0` ⇒ unstroked (e.g. a pure-fill rectangle).
    public var stroke: OverlayColor
    /// Stroke width in **points** (screen-space, not normalized): a hairline
    /// outline should look the same thickness regardless of image dimensions.
    /// Clamped to `>= 0`; `0` ⇒ no stroke is drawn.
    public var lineWidth: Double
    /// Fill color for closed shapes (rect / ellipse). `fill == nil` ⇒ outline
    /// only; ignored by open shapes (line / arrow), which are never filled.
    public var fill: OverlayColor?

    public init(stroke: OverlayColor = .black, lineWidth: Double = 2, fill: OverlayColor? = nil) {
        self.stroke = stroke
        self.lineWidth = Self.sanitize(lineWidth)
        self.fill = fill
    }

    private static func sanitize(_ v: Double) -> Double {
        guard v.isFinite, v > 0 else { return 0 }
        return v
    }
}

// MARK: - Shape

/// One vector mark. `kind` selects the geometry; `frame` is the normalized
/// bounding box (origin top-left, `0...1`) that the renderer maps into the
/// displayed image rect. For the open shapes (`line`, `arrow`) the mark runs
/// from the frame's top-left corner (`start`) to its bottom-right corner
/// (`end`) — encoding endpoints as a bounding box keeps move/scale uniform
/// across all kinds and keeps the persisted shape a single rect either way.
public struct VectorShape: Sendable, Codable, Equatable, Identifiable {
    /// The four supported primitives. `arrow` is a `line` with a head drawn at
    /// `end`; both are open (never filled).
    public enum Kind: String, Sendable, Codable, Equatable, CaseIterable {
        case rect
        case ellipse
        case line
        case arrow
    }

    /// Stable identity, preserved across move/reorder/serialize so the view's
    /// selection and `ForEach` stay attached to the same shape. Decoded from the
    /// persisted blob (not regenerated) so a round-trip is identity-preserving.
    public let id: UUID
    public var kind: Kind
    /// Normalized bounding box (`0...1`, top-left origin). For line/arrow it
    /// carries the two endpoints as opposite corners (see type doc).
    public var frame: CGRect
    public var style: ShapeStyle

    public init(id: UUID = UUID(), kind: Kind, frame: CGRect, style: ShapeStyle = ShapeStyle()) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.style = style
    }

    /// Endpoint accessors for the open shapes — `start` is the frame ORIGIN, `end`
    /// is origin+size. A SIGNED frame (negative width/height, as a drag-drawn line
    /// stores) therefore PRESERVES its direction (TSK-1058); for a standardized
    /// frame (closed shapes, the centered-line button) these still equal the
    /// top-left / bottom-right corners, so existing shapes are unchanged.
    public var start: CGPoint { frame.origin }
    public var end: CGPoint {
        // `frame.size` is the RAW (signed) size; `frame.width/height` would return
        // absolute values and drop the line's direction.
        CGPoint(x: frame.origin.x + frame.size.width, y: frame.origin.y + frame.size.height)
    }

    /// Translate the shape by a normalized delta, clamped so the frame's ORIGIN
    /// stays within `0...1` (the shape can extend past the right/bottom edge,
    /// matching how a drag in the editor behaves — you can't drag the handle off
    /// the canvas, but a large shape may overhang). Returns a moved copy;
    /// identity, kind, and style are unchanged.
    public func moved(byX dx: CGFloat, y dy: CGFloat) -> VectorShape {
        var copy = self
        let nx = Self.clampUnit(frame.origin.x + dx)
        let ny = Self.clampUnit(frame.origin.y + dy)
        copy.frame = CGRect(x: nx, y: ny, width: frame.size.width, height: frame.size.height)
        return copy
    }

    /// Build an open-shape (line / arrow) frame from two normalized endpoints.
    /// Stored as a `standardized` rect so width/height stay non-negative; the
    /// `start`/`end` accessors then report the corners consistently.
    public static func openFrame(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y).standardized
    }

    private static func clampUnit(_ v: CGFloat) -> CGFloat {
        guard v.isFinite else { return 0 }
        return min(max(v, 0), 1)
    }
}

// MARK: - Overlay (ordered list = z-order = hierarchy)

/// An **ordered** list of vector shapes layered over an image. Order IS the
/// z-order / hierarchy: index `0` is the BACK-most layer, the last element is
/// FRONT-most (drawn last, on top), which is also the natural draw order for a
/// SwiftUI `ForEach`/`ZStack`. Add/move/remove/reorder/serialize all operate by
/// stable `VectorShape.id`, never by raw index, so callers holding an id stay
/// correct across reorders.
///
/// Mutators return `Bool` where "did it find the target?" is useful (move /
/// remove / restyle), so a stale id is a no-op the caller can detect rather than
/// a trap. `append`/insert always succeed.
public struct VectorOverlay: Sendable, Codable, Equatable {
    /// Back-to-front. `shapes[0]` is drawn first (bottom), `shapes.last` last (top).
    public private(set) var shapes: [VectorShape]

    public init(shapes: [VectorShape] = []) {
        self.shapes = shapes
    }

    public var isEmpty: Bool { shapes.isEmpty }
    public var count: Int { shapes.count }

    // MARK: Add / remove

    /// Append a shape on TOP of the stack (front-most). Returns its `id` for the
    /// caller to track (e.g. to immediately select the new shape).
    @discardableResult
    public mutating func add(_ shape: VectorShape) -> UUID {
        shapes.append(shape)
        return shape.id
    }

    /// Remove the shape with `id`. Returns `true` iff one was found + removed.
    @discardableResult
    public mutating func remove(id: UUID) -> Bool {
        guard let idx = shapes.firstIndex(where: { $0.id == id }) else { return false }
        shapes.remove(at: idx)
        return true
    }

    /// Drop every shape (clears the overlay back to empty).
    public mutating func removeAll() {
        shapes.removeAll()
    }

    // MARK: Read

    public func shape(id: UUID) -> VectorShape? {
        shapes.first { $0.id == id }
    }

    /// Current z-index (0 = back) of `id`, or `nil` if absent.
    public func index(of id: UUID) -> Int? {
        shapes.firstIndex { $0.id == id }
    }

    // MARK: Move (position) / restyle

    /// Translate the shape with `id` by a normalized delta. No-op (returns
    /// `false`) for an unknown id.
    @discardableResult
    public mutating func move(id: UUID, byX dx: CGFloat, y dy: CGFloat) -> Bool {
        guard let idx = shapes.firstIndex(where: { $0.id == id }) else { return false }
        shapes[idx] = shapes[idx].moved(byX: dx, y: dy)
        return true
    }

    /// Set an absolute normalized frame for the shape with `id` (e.g. a resize
    /// handle commit). No-op for an unknown id.
    @discardableResult
    public mutating func setFrame(id: UUID, _ frame: CGRect) -> Bool {
        guard let idx = shapes.firstIndex(where: { $0.id == id }) else { return false }
        shapes[idx].frame = frame
        return true
    }

    /// Replace the style of the shape with `id`. No-op for an unknown id.
    @discardableResult
    public mutating func setStyle(id: UUID, _ style: ShapeStyle) -> Bool {
        guard let idx = shapes.firstIndex(where: { $0.id == id }) else { return false }
        shapes[idx].style = style
        return true
    }

    // MARK: Z-order / hierarchy

    /// Move the shape with `id` ONE step toward the front (higher z). No-op if
    /// it's already front-most or absent.
    @discardableResult
    public mutating func bringForward(id: UUID) -> Bool {
        guard let idx = shapes.firstIndex(where: { $0.id == id }), idx < shapes.count - 1
        else { return false }
        shapes.swapAt(idx, idx + 1)
        return true
    }

    /// Move the shape with `id` ONE step toward the back (lower z). No-op if it's
    /// already back-most or absent.
    @discardableResult
    public mutating func sendBackward(id: UUID) -> Bool {
        guard let idx = shapes.firstIndex(where: { $0.id == id }), idx > 0
        else { return false }
        shapes.swapAt(idx, idx - 1)
        return true
    }

    /// Move the shape with `id` to the very FRONT (top of the stack). No-op if
    /// already front-most or absent.
    @discardableResult
    public mutating func bringToFront(id: UUID) -> Bool {
        guard let idx = shapes.firstIndex(where: { $0.id == id }), idx < shapes.count - 1
        else { return false }
        let shape = shapes.remove(at: idx)
        shapes.append(shape)
        return true
    }

    /// Move the shape with `id` to the very BACK (bottom of the stack). No-op if
    /// already back-most or absent.
    @discardableResult
    public mutating func sendToBack(id: UUID) -> Bool {
        guard let idx = shapes.firstIndex(where: { $0.id == id }), idx > 0
        else { return false }
        let shape = shapes.remove(at: idx)
        shapes.insert(shape, at: 0)
        return true
    }

    // MARK: Serialize

    /// JSON-encode the overlay. Deterministic key order (`sortedKeys`) so two
    /// equal overlays produce byte-identical output — handy for snapshot diffing
    /// and change detection.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decode an overlay previously produced by `jsonData()`.
    public static func decoded(from data: Data) throws -> VectorOverlay {
        try JSONDecoder().decode(VectorOverlay.self, from: data)
    }
}
