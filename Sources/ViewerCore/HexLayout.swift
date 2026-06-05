import Foundation

/// Pure-logic layout math for the HEX viewer. Width selector
/// (Feature 2) drives row / column counts, and the click-highlight
/// (Feature 3) maps an offset back to a (row, col) for visual
/// targeting. Keeping it in ViewerCore so it's host-testable.
public enum HexLayout {

    /// Allowed bytes-per-row presets. The HEX view exposes these
    /// in a segmented picker; persisted via PreferencesStore.
    public static let allowedWidths: [Int] = [16, 32, 64]

    /// Default for new tabs.
    public static let defaultWidth: Int = 16

    /// Clamps an arbitrary integer to the nearest allowed width at-or-above
    /// the input (rounds up to the next of 16/32/64), saturating at 64.
    /// Defensive — UI should never hand us junk, but persisted prefs from a
    /// future build might.
    public static func clampWidth(_ raw: Int) -> Int {
        if raw <= 16 { return 16 }
        if raw <= 32 { return 32 }
        return 64
    }

    /// Row count for a byte buffer at the given width. Both empty file
    /// and zero/negative width yield zero rows.
    public static func rowCount(byteCount: Int, width: Int) -> Int {
        guard width > 0, byteCount > 0 else { return 0 }
        return (byteCount + width - 1) / width
    }

    /// Row containing the given byte offset (zero-based).
    public static func row(forOffset offset: Int, width: Int) -> Int {
        guard width > 0, offset >= 0 else { return 0 }
        return offset / width
    }

    /// Column within its row for the given byte offset (zero-based).
    public static func column(forOffset offset: Int, width: Int) -> Int {
        guard width > 0, offset >= 0 else { return 0 }
        return offset % width
    }

    /// Per-row character count in the rendered dump. Layout:
    ///   `OOOOOOOO␣␣HH␣HH␣...␣HH␣␣AAAA…\n`
    ///   = 8 offset chars + 2 spaces + (width*3 - 1) hex/sep chars
    ///     + 2 spaces + width ascii chars + 1 newline.
    public static func renderedRowLength(width: Int) -> Int {
        precondition(width > 0)
        return 8 + 2 + (width * 3 - 1) + 2 + width + 1
    }

    /// Character offset of the first hex digit of column `col` within a
    /// rendered row (relative to row start).
    public static func hexCharOffset(inRowColumn col: Int) -> Int {
        // After offset (8) + 2 spaces, columns are 3 chars each
        // (`HH␣`), so col 0 starts at 10, col 1 at 13, etc.
        return 10 + col * 3
    }

    /// Character offset of the ASCII glyph for column `col` within a
    /// rendered row.
    public static func asciiCharOffset(inRowColumn col: Int, width: Int) -> Int {
        // After hex column (10 + width*3 - 1) + 2 spaces.
        return 10 + (width * 3 - 1) + 2 + col
    }
}
