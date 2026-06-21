import Foundation

/// TSK-1073 — pure resize math for the image-editor Resize/Stretch dialog: percent
/// scaling and explicit width/height with optional aspect lock. Host-tested; the
/// dialog UI + the actual `EditOp.resize` render are the render-gated remainder.
public enum ImageResizeMath {

    /// Scale `current` by `percent` (100 = unchanged). Result clamped to ≥ 1px.
    public static func scaled(
        _ current: (width: Int, height: Int), percent: Double
    ) -> (width: Int, height: Int) {
        let f = Swift.max(0.01, percent / 100)
        return (Swift.max(1, Int((Double(current.width) * f).rounded())),
                Swift.max(1, Int((Double(current.height) * f).rounded())))
    }

    /// Target dims for an explicit `width`/`height`. With `maintainAspect`, the
    /// height is derived from the width using `current`'s aspect ratio (the passed
    /// `height` is ignored). Result clamped to ≥ 1px.
    public static func sized(
        current: (width: Int, height: Int),
        width: Int, height: Int, maintainAspect: Bool
    ) -> (width: Int, height: Int) {
        let w = Swift.max(1, width)
        if maintainAspect, current.width > 0 {
            let h = Swift.max(1, Int(
                (Double(w) * Double(current.height) / Double(current.width)).rounded()))
            return (w, h)
        }
        return (w, Swift.max(1, height))
    }
}
