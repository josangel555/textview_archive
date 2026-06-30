import Foundation

/// TSK-1303 — a serializable snapshot of an image-editor's in-progress edit state, so edits survive
/// a session switch (today the `ImageEditorViewModel` holds them purely in-memory and they're lost
/// when the tab/VM is recreated). Captures the three editable concerns:
///   - `ops`: the lossless committed op-list (the base `ImageDocument.ops` — geometry/tone/draw ops),
///   - the tonal slider values (the pending, not-yet-committed tone adjustments),
///   - `overlay`: the vector annotations (shapes + retained text, TSK-1310/1321).
///
/// Pure `Codable` value — it carries NO image pixels (the source image is referenced by the tab's
/// URL and re-decoded on restore), so it is cheap to embed in a session snapshot per image tab.
/// The session-lifecycle WIRING (capture on switch-away, restore on switch-back) is the
/// data-safety-sensitive tail; this is the round-trippable model it serializes.
public struct ImageEditState: Codable, Equatable, Sendable {
    public var ops: [EditOp]
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    public var exposureEV: Double
    public var shadow: Double
    public var highlight: Double
    public var sharpness: Double
    public var overlay: VectorOverlay

    public init(ops: [EditOp] = [],
                brightness: Double = 0, contrast: Double = 1, saturation: Double = 1,
                exposureEV: Double = 0, shadow: Double = 0, highlight: Double = 1,
                sharpness: Double = 0, overlay: VectorOverlay = VectorOverlay()) {
        self.ops = ops
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.exposureEV = exposureEV
        self.shadow = shadow
        self.highlight = highlight
        self.sharpness = sharpness
        self.overlay = overlay
    }
}
