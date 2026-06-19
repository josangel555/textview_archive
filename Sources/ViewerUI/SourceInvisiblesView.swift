import AppKit
import SwiftUI
import ViewerCore

/// Readable "show invisibles" overlay for the read-only `TextDisplayView`
/// source view (TSK-364).
///
/// Draws IntelliJ-style markers — middle-dot `·` for a space, arrow `→` for a
/// tab, pilcrow `¶` for a line ending — in a subtle-but-legible secondary tone
/// (`SourceInvisibles.markerColor`), replacing the washed-out OS faint-grey
/// that `NSLayoutManager.showsInvisibleCharacters` paints with no recolor API.
///
/// ## Why a separate Canvas instead of recoloring the layout manager
/// The only AppKit hook to restyle those built-in markers is subclassing
/// `NSLayoutManager` — the documented compositor-bug trigger (LESSONS.md). So
/// this view does the exact compositor-safe thing `SourceGutterView` does for
/// line numbers: a clipped SwiftUI `Canvas` whose row positions track the
/// textView's scroll via `SourceScrollState`. It never subclasses
/// `NSLayoutManager`, never attaches an `NSRulerView`, and computes positions
/// from a published scroll state (outside any `NSScrollView.tile()` call), so
/// it carries none of the compositor risk.
///
/// ## V1 limitations (mirror `SourceGutterView`)
///   - Assumes a fixed line height and fixed character pitch (monospace). The
///     source view fonts are all fixed-pitch (the gutter math relies on the
///     same), so column→x is `column * advance`.
///   - Word-wrap is drawn but markers on wrapped continuation rows are not yet
///     repositioned (same caveat the gutter carries; tracked with the
///     view-mode normalization pass). Markers past the first visual row of a
///     wrapped line are simply clipped by the viewport.
struct SourceInvisiblesView: View {
    let state: SourceScrollState
    /// The displayed source text. Split into lines lazily and only the visible
    /// slice is walked for markers.
    let text: String
    let fontSize: CGFloat
    let fontName: String?
    let theme: SyntaxTheme

    /// Left inset of the textView's text container. `TextDisplayView` sets
    /// `textContainerInset = NSSize(width: 10, height: 10)`; we mirror the
    /// horizontal inset so column 0 lands on the first glyph.
    private let textInsetX: CGFloat = 10

    var body: some View {
        Canvas { context, _ in
            guard state.lineHeight > 0 else { return }
            let lh = state.lineHeight
            let inset = state.topInset
            let font = FontPreference.resolvedFont(name: fontName, size: fontSize)
            // Fixed pitch: one cell's advance is constant. `maximumAdvancement`
            // is the monospace cell width for a fixed-pitch font.
            let advance = font.maximumAdvancement.width
            guard advance > 0 else { return }
            let color = SourceInvisibles.markerColor(for: theme)

            // Visible logical-line range (1-based), clamped — identical formula
            // to SourceGutterView so rows align with the gutter and text.
            let firstLine = max(1, Int((state.offsetY - inset) / lh) + 1)
            let lastLine = min(
                state.lineCount,
                Int((state.offsetY + state.viewportHeight - inset) / lh) + 2
            )
            guard firstLine <= lastLine else { return }

            // Slice out only the visible lines. `split` over the whole document
            // would be O(N); we walk newlines and grab the visible window.
            let lines = Self.visibleLines(
                in: text, from: firstLine, through: lastLine
            )

            let resolvedFont = Font.custom(font.fontName, size: fontSize)
            for (offset, line) in lines.enumerated() {
                let lineNo = firstLine + offset
                let docY = inset + CGFloat(lineNo - 1) * lh
                let y = docY - state.offsetY
                for marker in SourceInvisibles.markers(forLine: line) {
                    let x = textInsetX + CGFloat(marker.column) * advance + advance / 2
                    context.draw(
                        Text(marker.glyph)
                            .font(resolvedFont)
                            .foregroundStyle(Color(nsColor: color)),
                        at: CGPoint(x: x, y: y + lh / 2)
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Return the lines `from...through` (1-based, inclusive) of `text`,
    /// each WITHOUT its trailing newline. Walks the string once up to
    /// `through`; lines past EOF are omitted.
    static func visibleLines(
        in text: String, from: Int, through: Int
    ) -> [Substring] {
        guard from >= 1, through >= from, !text.isEmpty else { return [] }
        var result: [Substring] = []
        var lineNo = 1
        var lineStart = text.startIndex
        var idx = text.startIndex
        while idx < text.endIndex {
            if text[idx] == "\n" {
                if lineNo >= from && lineNo <= through {
                    result.append(text[lineStart..<idx])
                }
                lineNo += 1
                if lineNo > through { return result }
                lineStart = text.index(after: idx)
            }
            idx = text.index(after: idx)
        }
        // Trailing partial line (no terminating newline).
        if lineNo >= from && lineNo <= through {
            result.append(text[lineStart..<text.endIndex])
        }
        return result
    }
}
