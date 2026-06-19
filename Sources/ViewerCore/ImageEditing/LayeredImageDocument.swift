import CoreGraphics
import Foundation

/// How a layer's pixels combine with the layers BELOW it in the stack (TSK-286).
///
/// Kept as a small closed enum with a stable `String` raw value so the own
/// document format (`LayeredImageDocument` JSON) round-trips by NAME, not by an
/// ordinal that would silently re-map if cases were ever reordered. The set is
/// the common Porter-Duff/separable subset a layer-based image editor exposes;
/// each case names the compositing math the eventual renderer applies. The model
/// here is pure value/metadata — it does NOT itself blend pixels (that is the
/// render-gated remainder); it only records the intent so the stack composites
/// deterministically and serializes losslessly.
public enum LayerBlendMode: String, Sendable, Codable, Equatable, CaseIterable {
    /// `normal` source-over: the layer paints straight over what's below it,
    /// modulated only by its `opacity`. The default for a freshly-added layer.
    case normal
    case multiply
    case screen
    case overlay
    case darken
    case lighten
    case difference

    /// The matching CoreGraphics blend mode for the render path. Exposed here
    /// (rather than re-deriving in the view layer) so the single source of truth
    /// for "what does this case mean to the compositor" lives with the model.
    public var cgBlendMode: CGBlendMode {
        switch self {
        case .normal:     return .normal
        case .multiply:   return .multiply
        case .screen:     return .screen
        case .overlay:    return .overlay
        case .darken:     return .darken
        case .lighten:    return .lighten
        case .difference: return .difference
        }
    }
}

/// One layer of a `LayeredImageDocument` (TSK-286): a named, individually
/// toggleable + opacity-modulated wrapper around a lossless `ImageDocument`.
///
/// Each layer carries its OWN `ImageDocument` (source + replayable edit
/// history) so a layer's content stays losslessly re-derivable from
/// `source + ops` exactly like the single-layer editor — the layer model adds
/// only the *presentation* dimension (name / opacity / visibility / blend mode)
/// and the *stacking* dimension (the layer's position in its document's array).
///
/// `Sendable` + `Codable` + `Equatable` by design: a layer can cross actor
/// boundaries, serialize into the own JSON format, and be diffed for change
/// detection without decoding pixels (equality is over the metadata + the
/// wrapped document's source reference and op list, never decoded rasters).
public struct ImageLayer: Sendable, Codable, Equatable, Identifiable {
    /// Stable identity for SwiftUI list diffing AND for addressing a layer
    /// across a reorder (an index would be invalidated by a move). Serialized so
    /// a reload preserves the same identity a UI may be holding onto.
    public let id: UUID
    /// User-facing layer name. Free-form; not required to be unique (two layers
    /// named "Layer 1" are legal — `id` is the identity, not the name).
    public var name: String
    /// Per-layer opacity, clamped to `0...1` (0 = fully transparent contribution,
    /// 1 = fully opaque). Set via the property observer / initializer so an
    /// out-of-range caller value degrades gracefully instead of producing an
    /// invalid composite weight. A layer at opacity 0 contributes nothing even
    /// when `isVisible` is true.
    public var opacity: Double {
        didSet { opacity = Self.clampOpacity(opacity) }
    }
    /// Visibility toggle (the "eye" in a layers panel). A hidden layer is fully
    /// excluded from the composite regardless of its `opacity`, and — unlike
    /// setting opacity to 0 — preserves the layer's opacity so toggling it back
    /// on restores the prior weight.
    public var isVisible: Bool
    /// How this layer composites with the layers below it.
    public var blendMode: LayerBlendMode
    /// The lossless content of this layer.
    public var document: ImageDocument

    public init(
        id: UUID = UUID(),
        name: String,
        document: ImageDocument,
        opacity: Double = 1,
        isVisible: Bool = true,
        blendMode: LayerBlendMode = .normal
    ) {
        self.id = id
        self.name = name
        self.document = document
        self.opacity = Self.clampOpacity(opacity)
        self.isVisible = isVisible
        self.blendMode = blendMode
    }

    /// `true` when this layer actually contributes ink to the composite — it is
    /// visible AND its opacity is above zero. A layer that fails this test can be
    /// skipped entirely by the compositor (and is excluded from
    /// `LayeredImageDocument.compositingLayers`).
    public var contributesToComposite: Bool {
        isVisible && opacity > 0
    }

    /// Clamp an opacity into the valid `0...1` weight range. Centralized so every
    /// mutation path (init, `didSet`) shares one definition and no caller can
    /// reintroduce an out-of-range weight. A non-finite input collapses to the
    /// nearest valid bound rather than propagating a NaN weight.
    static func clampOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return value < 0 ? 0 : 1 }
        return min(max(value, 0), 1)
    }
}

/// A value-typed, serializable MULTI-LAYER image-edit document (TSK-286): an
/// ordered stack of `ImageLayer`s over a fixed canvas, plus the editor's "own
/// document format" (a versioned JSON encoding via `Codable`).
///
/// ## Stacking convention
/// `layers[0]` is the BOTTOM of the stack (painted first), `layers[last]` is the
/// TOP (painted last, so it appears in front). This matches a painter's
/// front-to-back reading and the natural array order a renderer iterates to
/// composite — "composite order" is simply iterating `layers` low index → high.
///
/// ## Own format
/// `encoded()` / `init(decoding:)` round-trip the whole document — canvas size,
/// every layer's metadata, and each layer's lossless `ImageDocument` — through
/// JSON. A `magic` discriminator + `formatVersion` are embedded so a loader can
/// reject a foreign file and a future migration can detect an old schema. The
/// encoding is deterministic (sorted keys) so two equal documents serialize to
/// byte-identical data — handy for change detection and snapshot tests.
///
/// `Sendable` + `Codable` + `Equatable`: crosses actor boundaries, persists to a
/// workspace snapshot, and diffs without decoding pixels.
public struct LayeredImageDocument: Sendable, Codable, Equatable {
    /// File-format discriminator written into the JSON. A loader rejects any blob
    /// whose `magic` differs so a wrong file type fails fast with a clear error
    /// rather than half-decoding into a garbage document.
    public static let magic = "textview.layeredimage"
    /// Current on-disk schema version. Bump when the JSON shape changes
    /// incompatibly; `init(decoding:)` refuses a version it can't read.
    public static let currentFormatVersion = 1

    /// Persisted format discriminator (must equal `magic`).
    public let magic: String
    /// Persisted schema version (must be `<= currentFormatVersion`).
    public let formatVersion: Int
    /// The fixed canvas every layer composites onto, in pixels. Layers may be
    /// any size; the canvas defines the output extent.
    public var canvasSize: CGSize
    /// The layer stack, bottom (`[0]`) to top (`[last]`).
    public var layers: [ImageLayer]

    /// Designated initializer for a freshly-built (in-memory) document. The
    /// `magic`/`formatVersion` are stamped to the current constants — they only
    /// differ from current when DECODING an older/foreign file.
    public init(canvasSize: CGSize, layers: [ImageLayer] = []) {
        self.magic = Self.magic
        self.formatVersion = Self.currentFormatVersion
        self.canvasSize = canvasSize
        self.layers = layers
    }

    /// Internal full initializer used by `init(from:)` so a decoded document
    /// retains the `magic`/`formatVersion` it was stored with (after validation).
    private init(magic: String, formatVersion: Int, canvasSize: CGSize, layers: [ImageLayer]) {
        self.magic = magic
        self.formatVersion = formatVersion
        self.canvasSize = canvasSize
        self.layers = layers
    }

    // MARK: - Composite query

    /// The layers that actually contribute to the rendered composite — visible,
    /// non-zero opacity — in **composite (painting) order**, bottom to top. The
    /// compositor iterates exactly this list; a fully hidden or zero-opacity
    /// layer is dropped so it costs nothing to skip.
    public var compositingLayers: [ImageLayer] {
        layers.filter { $0.contributesToComposite }
    }

    /// `true` when nothing would be drawn — no layers, or none that contribute.
    public var isEmpty: Bool {
        compositingLayers.isEmpty
    }

    /// Find a layer's index by `id`, or `nil` if it isn't in the stack. The
    /// addressing primitive the mutation helpers build on so callers never have
    /// to hold a fragile array index across a reorder.
    public func index(of id: UUID) -> Int? {
        layers.firstIndex { $0.id == id }
    }

    // MARK: - Stack mutation (value-semantic: each returns a new document)

    /// Add `layer` to the TOP of the stack (painted last / appears in front).
    public func addingLayer(_ layer: ImageLayer) -> LayeredImageDocument {
        var copy = self
        copy.layers.append(layer)
        return copy
    }

    /// Insert `layer` at an explicit stack index (clamped to a valid insertion
    /// point), where 0 = bottom. Out-of-range indices clamp to the nearest end
    /// rather than trapping.
    public func insertingLayer(_ layer: ImageLayer, at index: Int) -> LayeredImageDocument {
        var copy = self
        let clamped = min(max(index, 0), copy.layers.count)
        copy.layers.insert(layer, at: clamped)
        return copy
    }

    /// Remove the layer with `id` (no-op when absent).
    public func removingLayer(_ id: UUID) -> LayeredImageDocument {
        guard let i = index(of: id) else { return self }
        var copy = self
        copy.layers.remove(at: i)
        return copy
    }

    /// Move the layer with `id` UP one position in the stack (toward the top /
    /// front). No-op when the layer is absent or already on top.
    public func movingLayerUp(_ id: UUID) -> LayeredImageDocument {
        guard let i = index(of: id), i < layers.count - 1 else { return self }
        var copy = self
        copy.layers.swapAt(i, i + 1)
        return copy
    }

    /// Move the layer with `id` DOWN one position in the stack (toward the bottom
    /// / back). No-op when the layer is absent or already at the bottom.
    public func movingLayerDown(_ id: UUID) -> LayeredImageDocument {
        guard let i = index(of: id), i > 0 else { return self }
        var copy = self
        copy.layers.swapAt(i, i - 1)
        return copy
    }

    /// Move the layer with `id` to an explicit stack index (clamped), preserving
    /// the relative order of the rest. 0 = bottom. No-op when the layer is
    /// absent. Useful for a drag-reorder where the drop target is a direct index.
    public func movingLayer(_ id: UUID, to index: Int) -> LayeredImageDocument {
        guard let from = self.index(of: id) else { return self }
        var copy = self
        let layer = copy.layers.remove(at: from)
        let clamped = min(max(index, 0), copy.layers.count)
        copy.layers.insert(layer, at: clamped)
        return copy
    }

    /// Replace the layer carrying `replacement.id` with `replacement` (no-op when
    /// no layer has that id). The mutation primitive for "toggle visibility / set
    /// opacity / rename / change blend" without the caller juggling indices.
    public func replacingLayer(_ replacement: ImageLayer) -> LayeredImageDocument {
        guard let i = index(of: replacement.id) else { return self }
        var copy = self
        copy.layers[i] = replacement
        return copy
    }

    /// Toggle the visibility of the layer with `id` (no-op when absent).
    public func togglingVisibility(_ id: UUID) -> LayeredImageDocument {
        guard let i = index(of: id) else { return self }
        var copy = self
        copy.layers[i].isVisible.toggle()
        return copy
    }

    /// Set the opacity of the layer with `id` (clamped to `0...1`; no-op when
    /// absent). Routes through `ImageLayer.opacity`'s `didSet`, so the clamp is
    /// always applied.
    public func settingOpacity(_ opacity: Double, of id: UUID) -> LayeredImageDocument {
        guard let i = index(of: id) else { return self }
        var copy = self
        copy.layers[i].opacity = opacity
        return copy
    }

    // MARK: - Own document format (versioned JSON round-trip)

    /// Encode the whole document to the own JSON format. Deterministic
    /// (sorted keys) so equal documents produce byte-identical output. Throws if
    /// the document somehow isn't encodable (unreachable for the value types
    /// here, but surfaced rather than force-tried).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    /// Decode a document from the own JSON format, validating the `magic`
    /// discriminator and `formatVersion` before trusting the payload. Throws
    /// `LayeredImageError` with a precise reason a foreign / future blob fails,
    /// so a loader can distinguish "wrong file type" from "newer than I can read"
    /// from "corrupt JSON".
    public init(decoding data: Data) throws {
        let decoder = JSONDecoder()
        do {
            self = try decoder.decode(LayeredImageDocument.self, from: data)
        } catch let e as LayeredImageError {
            // Validation errors from `init(from:)` propagate unchanged.
            throw e
        } catch {
            throw LayeredImageError.malformedJSON
        }
    }

    // MARK: Codable with validation

    private enum CodingKeys: String, CodingKey {
        case magic, formatVersion, canvasSize, layers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let magic = try c.decode(String.self, forKey: .magic)
        guard magic == Self.magic else {
            throw LayeredImageError.wrongFormat(found: magic)
        }
        let version = try c.decode(Int.self, forKey: .formatVersion)
        guard version >= 1, version <= Self.currentFormatVersion else {
            throw LayeredImageError.unsupportedVersion(version)
        }
        let canvas = try c.decode(CGSize.self, forKey: .canvasSize)
        let layers = try c.decode([ImageLayer].self, forKey: .layers)
        self.init(magic: magic, formatVersion: version, canvasSize: canvas, layers: layers)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(magic, forKey: .magic)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(canvasSize, forKey: .canvasSize)
        try c.encode(layers, forKey: .layers)
    }
}

/// Errors thrown by the layered-image own format. Distinct, `Equatable` cases so
/// the loader (and the validation suite) can assert on WHY a blob was rejected.
public enum LayeredImageError: Error, Equatable {
    /// The blob isn't a layered-image document — its `magic` discriminator
    /// doesn't match (carries what was found, for diagnostics).
    case wrongFormat(found: String)
    /// The blob's `formatVersion` is newer than this build can read (or < 1).
    case unsupportedVersion(Int)
    /// The bytes weren't valid JSON / didn't match the document schema.
    case malformedJSON
}
