import SwiftUI
import AppKit
import ViewerCore

/// Pure geometry for the source-view line HOVER highlight (TSK-263).
///
/// Mirrors the `SourceGutterView` coordinate math (the gutter positions its
/// per-line glyphs the same way), so the hover backdrop lines up exactly with
/// the rendered text rows. Split out as pure functions so the pointer→line
/// mapping is unit-tested headlessly (no window) — `SourceHoverGeometryTests`.
enum SourceHoverGeometry {
    /// 1-based source line under a pointer at viewport-y `pointerY`, or `nil`
    /// when the geometry isn't usable yet (zero line height / empty doc) or the
    /// pointer sits above the first line or past the last line.
    ///
    /// Viewport→document: `docY = pointerY + offsetY`; line `n`'s TOP is at
    /// `topInset + (visual rows above n)*lineHeight - offsetY`. Without wrap data
    /// "visual rows above n" == `n-1` (the exact inverse of the no-wrap gutter
    /// formula). With wrap data (TSK-896) it's the running sum of each prior
    /// line's row span, so a wrapped line above the pointer no longer shifts the
    /// result by `(rows-1)` lines.
    static func lineAtPointer(_ pointerY: CGFloat, in s: SourceScrollState) -> Int? {
        guard s.lineHeight > 0, s.lineCount > 0 else { return nil }
        let rel = (pointerY + s.offsetY) - s.topInset
        guard rel >= 0 else { return nil }
        // Visual-row index under the pointer (0-based).
        let row = Int(rel / s.lineHeight)
        let line = logicalLine(forVisualRow: row, in: s)
        guard line >= 1, line <= s.lineCount else { return nil }
        return line
    }

    /// Viewport-y (top edge) where 1-based `line` is drawn. Without wrap data,
    /// the same formula `SourceGutterView` uses:
    /// `topInset + (line-1)*lineHeight - offsetY`. With wrap data, `(line-1)` is
    /// replaced by the count of visual rows occupied by all lines above `line`.
    static func lineViewportY(_ line: Int, in s: SourceScrollState) -> CGFloat {
        let rowsAbove = visualRowsAbove(line: line, in: s)
        return s.topInset + CGFloat(rowsAbove) * s.lineHeight - s.offsetY
    }

    /// 1-based logical line that visual `row` (0-based) falls within.
    ///
    /// No wrap data ⇒ `row + 1` (1:1 row↔line). With wrap data, walk the
    /// per-line row spans accumulating rows until `row` is consumed, so the
    /// extra rows a wrapped line adds are attributed to that line — not to the
    /// lines below it. Past the last modeled line we extend with single rows
    /// (defensive: a stale/short `wrappedRowCounts` shouldn't crash or mismap
    /// the trailing lines catastrophically — they just fall back to 1:1).
    static func logicalLine(forVisualRow row: Int, in s: SourceScrollState) -> Int {
        guard let counts = s.wrappedRowCounts, !counts.isEmpty else {
            return row + 1
        }
        var remaining = row
        var line = 1
        let modeled = counts.count
        while line <= s.lineCount {
            let span = line <= modeled ? max(1, counts[line - 1]) : 1
            if remaining < span { return line }
            remaining -= span
            line += 1
        }
        return s.lineCount + 1   // past the last line → caller clamps to nil
    }

    /// Total visual rows occupied by every logical line ABOVE 1-based `line`.
    /// No wrap data ⇒ `line - 1`. With wrap data, the sum of each prior line's
    /// row span.
    static func visualRowsAbove(line: Int, in s: SourceScrollState) -> Int {
        guard line > 1 else { return 0 }
        guard let counts = s.wrappedRowCounts, !counts.isEmpty else {
            return line - 1
        }
        let modeled = counts.count
        var rows = 0
        var n = 1
        while n < line {
            rows += n <= modeled ? max(1, counts[n - 1]) : 1
            n += 1
        }
        return rows
    }

    /// Visual-row span of 1-based `line` (≥1). No wrap data ⇒ 1.
    static func visualRowSpan(ofLine line: Int, in s: SourceScrollState) -> Int {
        guard let counts = s.wrappedRowCounts, line >= 1, line <= counts.count
        else { return 1 }
        return max(1, counts[line - 1])
    }
}

/// SwiftUI overlay that paints a subtle backdrop on the source line under the
/// pointer (TSK-263) — distinct from, and lighter than, the caret/selection
/// current-line backdrop (`applyCurrentLineHighlight`).
///
/// Drawn as a sibling of the `NSTextView` in a `ZStack` and gated
/// `allowsHitTesting(false)` so it never intercepts text selection; the
/// `.onContinuousHover` that feeds `hoveredLine` lives on the ZStack container
/// (hover tracking does not consume clicks). Suppressed on the caret line so it
/// doesn't double up with the current-line highlight, and only drawn while the
/// row is actually within the viewport.
struct SourceHoverHighlight: View {
    let state: SourceScrollState
    let caretLine: Int
    let hoveredLine: Int?
    let theme: SyntaxTheme

    var body: some View {
        if let line = hoveredLine,
           line != caretLine,
           state.lineHeight > 0,
           line >= 1, line <= state.lineCount {
            let y = SourceHoverGeometry.lineViewportY(line, in: state)
            // A wrapped logical line spans multiple visual rows; tint all of
            // them so the highlight covers the whole row under the pointer
            // (TSK-896), not just its first visual row.
            let rows = SourceHoverGeometry.visualRowSpan(ofLine: line, in: state)
            let height = state.lineHeight * CGFloat(rows)
            if y + height > 0, y < state.viewportHeight {
                Rectangle()
                    .fill(tint)
                    .frame(height: height)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(y: y)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Theme-aware, deliberately fainter than the current-line backdrop
    /// (12%/8%, see `applyCurrentLineHighlight`) so hover reads as a weaker cue
    /// than the caret line. Mirrors that code's dark/light brightness split.
    private var tint: Color {
        let isDark = theme.background.brightnessComponent < 0.5
        return Color(nsColor: isDark ? .white : .black)
            .opacity(isDark ? 0.06 : 0.045)
    }
}
