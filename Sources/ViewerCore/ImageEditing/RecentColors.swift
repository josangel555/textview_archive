/// TSK-1118 — a small most-recently-used list of paint colors for the image
/// editor's "recent swatches" strip: bounded, de-duplicated, newest-first. Pure
/// + host-testable; the swatch UI consumes `colors`.
public struct RecentColors {
    public let limit: Int
    public private(set) var colors: [RGBAColor] = []

    public init(limit: Int = 12) {
        self.limit = Swift.max(1, limit)
    }

    /// Record a chosen color: move it to the front (de-duplicating), then trim to
    /// `limit`. Recording the current front color is a cheap no-op (it stays put).
    public mutating func record(_ color: RGBAColor) {
        colors.removeAll { $0 == color }
        colors.insert(color, at: 0)
        if colors.count > limit {
            colors.removeLast(colors.count - limit)
        }
    }
}
