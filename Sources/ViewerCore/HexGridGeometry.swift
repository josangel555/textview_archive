import Foundation

/// Arithmetic document geometry for the HEX dump grid (TSK-267 step 4).
///
/// The 1MB-HEX stall was measured (VM xctrace, 2026-06-10) as TextKit 2
/// force-laying-out the ENTIRE document — `NSTextView.textContainerOrigin`
/// → `ensureLayoutForRange:` over all ~65k rows — because a vertically
/// resizable text view with an infinite container can only answer "how
/// tall am I" by laying everything out. But the dump is a UNIFORM
/// monospaced grid: every line has identical height and every row
/// identical character count, so the document size is pure arithmetic.
/// The view sets its frame from these formulas and turns self-sizing
/// off; TK2 then lays out viewport-only, as designed.
///
/// The formulas are pinned against the real TK2 engine by
/// `HexGridGeometryTK2Tests` (host headless): predicted size must equal
/// `NSTextLayoutManager.usageBoundsForTextContainer` exactly for real
/// `HexDumpBuilder` output. If an OS update changes text metrics
/// semantics, that test goes red before the user sees a clipped grid.
public enum HexGridGeometry {
    /// Newlines in the dump: every row ends "\n"; the truncation header
    /// is "Showing first N of M bytes\n\n" (2 newlines).
    public static func newlineCount(rowCount: Int, hasHeader: Bool) -> Int {
        rowCount + (hasHeader ? 2 : 0)
    }

    /// Laid-out line count. A trailing "\n" yields one final EMPTY
    /// paragraph fragment that contributes a full line height (verified
    /// against TK2 by the invariant test).
    public static func lineCount(newlineCount: Int) -> Int {
        newlineCount + 1
    }

    /// Total text height (no insets): lines × the engine-measured line
    /// height for the dump's font.
    public static func textHeight(lineCount: Int, lineHeight: Double) -> Double {
        Double(lineCount) * lineHeight
    }

    /// Total text width (no insets): the widest line × the monospace
    /// char advance. `perRowChars` is `HexLayout.renderedRowLength`
    /// (INCLUDING the "\n"); the visible columns are one fewer. The
    /// header line is always narrower than a data row.
    public static func textWidth(perRowChars: Int, charAdvance: Double) -> Double {
        Double(max(0, perRowChars - 1)) * charAdvance
    }
}
