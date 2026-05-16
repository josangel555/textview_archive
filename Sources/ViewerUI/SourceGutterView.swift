import AppKit
import SwiftUI
import ViewerCore

/// Line-number gutter rendered alongside the `TextDisplayView` source
/// area. Synced to the NSTextView's clipView via the `SourceScrollState`
/// the controller publishes on each scroll/resize event.
///
/// Why a separate SwiftUI view instead of `NSRulerView`: the ruler
/// path triggers `NSScrollView.tile()` reentrancy that blanks
/// surrounding SwiftUI views (see LESSONS.md). The gutter here is
/// just a clipped Canvas whose offset tracks scroll — no `tile()`
/// interaction, no compositor stress.
///
/// V1 limitations:
///   - Assumes fixed line height (font-derived). Word-wrap mode is
///     supported visually but line numbers will be slightly misaligned
///     on wrapped lines. That's tracked separately when the
///     view-mode normalization pass lands.
struct SourceGutterView: View {
    let state: SourceScrollState
    let fontSize: CGFloat
    let theme: SyntaxTheme
    /// Per-line diff status for the open file. Empty when not in a
    /// repo or the file is clean.
    var diffMarks: [Int: DiffMark] = [:]
    /// 1-based line numbers bookmarked for the open file.
    var bookmarkedLines: Set<Int> = []

    /// Width in points. 6px padding + N digits worth of monospace
    /// glyphs. Updated whenever `state.lineCount` changes.
    var width: CGFloat {
        let digits = max(2, String(state.lineCount).count)
        let glyphAdvance = NSFont.monospacedSystemFont(
            ofSize: max(10, fontSize - 3), weight: .regular
        ).advancement(forGlyph: NSGlyph(0))   // approximation
        let estChar = max(7, glyphAdvance.width)
        return CGFloat(digits) * estChar + 14
    }

    var body: some View {
        Canvas { context, size in
            // Background.
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color(nsColor: theme.gutterBackground))
            )
            // Right-edge separator.
            context.stroke(
                Path { p in
                    p.move(to: CGPoint(x: size.width - 0.5, y: 0))
                    p.addLine(to: CGPoint(x: size.width - 0.5, y: size.height))
                },
                with: .color(Color(nsColor: .separatorColor)),
                lineWidth: 0.5
            )
            // Line numbers. Only render rows that overlap the visible
            // viewport — that's typically ~50 of N regardless of file
            // size.
            guard state.lineHeight > 0 else { return }
            let lh = state.lineHeight
            // Inset: textView's textContainerInset.height pushes the
            // first glyph row down. We mirror that so row 1 aligns.
            let inset = state.topInset
            // First visible line (1-based). Clamp so we never go
            // negative on an over-scrolled rubber-band.
            let firstLine = max(1, Int((state.offsetY - inset) / lh) + 1)
            let lastLine = min(
                state.lineCount,
                Int((state.offsetY + state.viewportHeight - inset) / lh) + 2
            )
            guard firstLine <= lastLine else { return }
            let font = NSFont.monospacedSystemFont(
                ofSize: max(10, fontSize - 3), weight: .regular
            )
            let textColor = NSColor(theme.gutterText)
            for n in firstLine...lastLine {
                // y for line N (relative to documentView origin):
                //   inset + (N-1)*lh
                // Subtract the scroll offset to get viewport y.
                let docY = inset + CGFloat(n - 1) * lh
                let y = docY - state.offsetY

                // Git diff stripe — 2pt wide bar on the left edge of
                // the gutter. Green = added, blue = modified, red =
                // deleted (drawn as a thin tick at the line's top
                // since the removed line isn't in the working tree).
                if let mark = diffMarks[n] {
                    let color: Color
                    switch mark {
                    case .added:    color = .green
                    case .modified: color = .blue
                    case .deleted:  color = .red
                    }
                    let stripeRect: CGRect
                    if mark == .deleted {
                        // Thin tick at the top of the line where the
                        // deletion happened above.
                        stripeRect = CGRect(x: 0, y: y, width: 2, height: 2)
                    } else {
                        stripeRect = CGRect(x: 0, y: y + 1, width: 2, height: max(2, lh - 2))
                    }
                    context.fill(Path(stripeRect), with: .color(color.opacity(0.85)))
                }

                // Bookmark indicator — small filled circle to the left
                // of the line number, between the diff stripe and the
                // number. Yellow to match the bookmark star elsewhere.
                if bookmarkedLines.contains(n) {
                    let dotSize: CGFloat = max(4, lh * 0.35)
                    let dotRect = CGRect(
                        x: 5,
                        y: y + (lh - dotSize) / 2,
                        width: dotSize, height: dotSize
                    )
                    context.fill(Path(ellipseIn: dotRect), with: .color(.yellow))
                }

                let label = "\(n)" as NSString
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: textColor,
                ]
                let labelSize = label.size(withAttributes: attrs)
                let x = size.width - labelSize.width - 6
                context.draw(
                    Text(AttributedString("\(n)"))
                        .font(.system(size: max(10, fontSize - 3),
                                      design: .monospaced))
                        .foregroundStyle(Color(nsColor: theme.gutterText)),
                    at: CGPoint(x: x + labelSize.width / 2,
                                y: y + lh / 2)
                )
            }
        }
        .frame(width: width)
        .accessibilityIdentifier("mdv.sourceGutter")
        .accessibilityLabel(gutterAccessibilityLabel)
    }

    /// VoiceOver-readable summary of what the gutter is showing.
    /// Canvas drawing doesn't surface per-element a11y, so we roll
    /// it up. The line number column is decorative (caret/Ln from
    /// the status bar is the canonical signal).
    private var gutterAccessibilityLabel: String {
        var parts: [String] = ["Line numbers"]
        if !diffMarks.isEmpty {
            let added    = diffMarks.values.filter { $0 == .added    }.count
            let modified = diffMarks.values.filter { $0 == .modified }.count
            let deleted  = diffMarks.values.filter { $0 == .deleted  }.count
            parts.append("git changes: \(added) added, \(modified) modified, \(deleted) deleted")
        }
        if !bookmarkedLines.isEmpty {
            parts.append("\(bookmarkedLines.count) bookmarked lines")
        }
        return parts.joined(separator: "; ")
    }
}

private extension NSColor {
    /// Bridge SwiftUI Color → NSColor when SwiftUI's Color init takes
    /// only NSColor. The gutter sources NSColor from `SyntaxTheme`
    /// directly, so this is essentially a passthrough.
    convenience init(_ ns: NSColor) {
        self.init(cgColor: ns.cgColor)!
    }
}
