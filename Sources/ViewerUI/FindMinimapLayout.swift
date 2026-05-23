import CoreGraphics

/// Pure layout math for the find-bar match minimap. Given a sorted
/// list of 1-based match lines, the document's total line count, and
/// the canvas height in points, compute the y-position (and current
/// flag) for each tick mark.
///
/// Separated from the rendering view so the math is unit-testable
/// without spinning up SwiftUI / a Canvas. The view layer is a thin
/// wrapper that just iterates the returned ticks.
public enum FindMinimapLayout {

    public struct Tick: Equatable, Sendable {
        /// Vertical position in canvas-local points, top-anchored. The
        /// tick should be drawn as a thin horizontal bar starting at
        /// `y` (or centered on it, depending on tick height).
        public let y: CGFloat
        /// 1-based line number this tick represents. Useful for
        /// click→jump and tooltip wiring.
        public let line: Int
        /// True for the active match (the one the find bar will jump
        /// to on "next"). Rendering should brighten this tick.
        public let isCurrent: Bool

        public init(y: CGFloat, line: Int, isCurrent: Bool) {
            self.y = y
            self.line = line
            self.isCurrent = isCurrent
        }
    }

    /// Compute tick positions for the minimap.
    ///
    /// - Parameters:
    ///   - matchLines: 1-based line numbers, in any order. May contain
    ///     duplicates (multiple matches per line) — duplicates are
    ///     kept; the renderer can either draw over itself (visually
    ///     fine, ticks are tiny) or dedupe upstream.
    ///   - totalLines: total line count of the document. When ≤ 1 we
    ///     return empty (no scrollbar to map onto).
    ///   - canvasHeight: pixel height of the minimap area. When ≤ 0
    ///     we return empty (nothing to draw).
    ///   - currentMatchIndex: index into `matchLines` of the active
    ///     match, or nil if none. Out-of-range values are ignored.
    public static func ticks(
        matchLines: [Int],
        totalLines: Int,
        canvasHeight: CGFloat,
        currentMatchIndex: Int? = nil
    ) -> [Tick] {
        guard totalLines > 0, canvasHeight > 0, !matchLines.isEmpty else {
            return []
        }
        // Use (totalLines) as the denominator so a match on the last
        // line lands at canvasHeight. Off-by-one risk: a 1-line doc
        // with a match on line 1 maps to y=0 (top), which matches
        // the visual expectation that the tick anchors at the top.
        let denom = CGFloat(max(1, totalLines))
        return matchLines.enumerated().map { idx, line in
            let clamped = max(1, min(line, totalLines))
            // Map line N (1-based) to a y in [0, canvasHeight). Using
            // (N - 1) / total puts line 1 at y=0; the last line lands
            // just shy of canvasHeight. We clamp explicitly so floating
            // rounding can't poke past the lower edge.
            let raw = CGFloat(clamped - 1) / denom * canvasHeight
            let y = max(0, min(canvasHeight, raw))
            return Tick(
                y: y,
                line: clamped,
                isCurrent: idx == currentMatchIndex
            )
        }
    }

    /// Inverse of `ticks` for click→line: given a click y-coordinate
    /// (in canvas-local points) and the same (totalLines, canvasHeight)
    /// pair, find the nearest match line. Returns nil when there are
    /// no candidates within `tolerance` points.
    ///
    /// Implemented in terms of the `ticks` output rather than
    /// re-deriving the mapping — keeps the rounding behavior identical
    /// to what the user sees on screen.
    public static func nearestLine(
        toY clickY: CGFloat,
        matchLines: [Int],
        totalLines: Int,
        canvasHeight: CGFloat,
        tolerance: CGFloat = 6
    ) -> Int? {
        let all = ticks(
            matchLines: matchLines,
            totalLines: totalLines,
            canvasHeight: canvasHeight
        )
        guard !all.isEmpty else { return nil }
        var best: (line: Int, dy: CGFloat)?
        for t in all {
            let dy = abs(t.y - clickY)
            if best == nil || dy < best!.dy {
                best = (t.line, dy)
            }
        }
        guard let pick = best, pick.dy <= tolerance else { return nil }
        return pick.line
    }
}
