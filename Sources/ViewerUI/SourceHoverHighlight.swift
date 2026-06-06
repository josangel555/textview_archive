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
    /// Viewport→document: `docY = pointerY + offsetY`; the gutter draws line `n`
    /// at `topInset + (n-1)*lineHeight - offsetY`, so this is its exact inverse.
    static func lineAtPointer(_ pointerY: CGFloat, in s: SourceScrollState) -> Int? {
        guard s.lineHeight > 0, s.lineCount > 0 else { return nil }
        let rel = (pointerY + s.offsetY) - s.topInset
        guard rel >= 0 else { return nil }
        let line = Int(rel / s.lineHeight) + 1
        guard line >= 1, line <= s.lineCount else { return nil }
        return line
    }

    /// Viewport-y (top edge) where 1-based `line` is drawn — the same formula
    /// `SourceGutterView` uses: `topInset + (line-1)*lineHeight - offsetY`.
    static func lineViewportY(_ line: Int, in s: SourceScrollState) -> CGFloat {
        s.topInset + CGFloat(line - 1) * s.lineHeight - s.offsetY
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
            if y + state.lineHeight > 0, y < state.viewportHeight {
                Rectangle()
                    .fill(tint)
                    .frame(height: state.lineHeight)
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
