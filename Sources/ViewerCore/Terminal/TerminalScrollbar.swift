import Foundation

/// Pure geometry for the terminal's scrollback scrollbar — no AppKit, so
/// the thumb sizing/positioning and the drag inverse are headless-testable.
/// The view (`TerminalNSView`) turns these fractions into pixels and draws
/// a thumb on the right edge.
///
/// Coordinate convention matches the flipped terminal view: fraction 0 =
/// TOP of the track, 1 = BOTTOM. Scroll `offset` is "lines up from the live
/// bottom" (0 = following live output = thumb at the bottom).
public enum TerminalScrollbar {

    /// The thumb as fractions of the track, or `nil` when there's nothing
    /// to scroll (no scrollback). `height` = thumb height / track height
    /// (floored so it stays grabbable); `position` = top of the available
    /// travel the thumb sits at (0 = top, 1 = bottom).
    public static func thumb(rows: Int, scrollback: Int, offset: Int)
        -> (position: Double, height: Double)?
    {
        guard scrollback > 0, rows > 0 else { return nil }
        let total = Double(rows + scrollback)
        let height = min(1.0, max(0.06, Double(rows) / total))
        let o = Double(min(max(0, offset), scrollback))
        // offset 0 (bottom/live) → position 1 (thumb bottom); offset == max
        // (oldest) → position 0 (thumb top).
        let position = 1.0 - o / Double(scrollback)
        return (position, height)
    }

    /// Map a pointer position (`yFraction`: 0 = top of track, 1 = bottom) to
    /// a scroll offset — the inverse of `thumb` for click/drag in the gutter.
    public static func offset(forYFraction yFraction: Double, rows: Int, scrollback: Int) -> Int {
        guard scrollback > 0 else { return 0 }
        let f = min(max(0, yFraction), 1)
        // top (f=0) → max offset (oldest); bottom (f=1) → 0 (live).
        return Int((1.0 - f) * Double(scrollback))
    }
}
