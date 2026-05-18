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
    /// Fold-state for the open file. When non-nil, the gutter draws a
    /// chevron in a leading 12pt column for any line that starts a
    /// fold region (▾ when expanded, ▸ when collapsed). Clicks on the
    /// chevron route through `onFoldChevronClick`.
    var foldState: FoldState? = nil
    /// Called when the user clicks a chevron. The argument is the
    /// 1-based original-buffer line number that starts the fold.
    var onFoldChevronClick: ((Int) -> Void)? = nil

    /// Width of the fold-chevron column when `foldState` is present.
    /// 0 when fold support isn't wired (keeps existing layouts intact).
    private var chevronColumnWidth: CGFloat {
        foldState == nil ? 0 : 14
    }

    /// Width in points. 6px padding + N digits worth of monospace
    /// glyphs, plus an optional chevron column. Updated whenever
    /// `state.lineCount` or `foldState` presence changes.
    var width: CGFloat {
        let digits = max(2, String(state.lineCount).count)
        let glyphAdvance = NSFont.monospacedSystemFont(
            ofSize: max(10, fontSize - 3), weight: .regular
        ).advancement(forGlyph: NSGlyph(0))   // approximation
        let estChar = max(7, glyphAdvance.width)
        return CGFloat(digits) * estChar + 14 + chevronColumnWidth
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            canvasBody
            chevronOverlay
        }
        .frame(width: width)
        .accessibilityIdentifier("mdv.sourceGutter")
        .accessibilityLabel(gutterAccessibilityLabel)
    }

    /// Click-target overlay for fold chevrons. Sits above the Canvas so
    /// the hit-test is per-line. Empty (transparent) when no folds.
    @ViewBuilder
    private var chevronOverlay: some View {
        if let fs = foldState, state.lineHeight > 0,
           let click = onFoldChevronClick {
            let lh = state.lineHeight
            let inset = state.topInset
            let firstLine = max(1, Int((state.offsetY - inset) / lh) + 1)
            let lastLine = min(
                state.lineCount,
                Int((state.offsetY + state.viewportHeight - inset) / lh) + 2
            )
            if firstLine <= lastLine {
                ZStack(alignment: .topLeading) {
                    ForEach(firstLine...lastLine, id: \.self) { n in
                        let starts = fs.regionsStarting(at: n)
                        if !starts.isEmpty {
                            let y = inset + CGFloat(n - 1) * lh - state.offsetY
                            Button(action: { click(n) }) {
                                Rectangle().fill(Color.clear)
                                    .frame(width: chevronColumnWidth,
                                           height: lh)
                            }
                            .buttonStyle(.plain)
                            .position(x: chevronColumnWidth / 2,
                                      y: y + lh / 2)
                            .accessibilityLabel(
                                fs.collapsed.contains(starts.first!)
                                    ? "Expand fold"
                                    : "Collapse fold"
                            )
                        }
                    }
                }
            }
        }
    }

    private var canvasBody: some View {
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
                with: .color(Palette.separator),
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
            // Monospace digit advance is constant per (font); the only
            // varying input is digit-count per line number. Precompute
            // glyph-size-per-digit-count once per Canvas draw so the
            // per-line `NSString.size(withAttributes:)` syscall is
            // replaced with array lookup (was firing 50× per scroll
            // tick × per selection change on long files).
            let labelSizes = Self.labelSizes(
                upTo: lastLine, font: font, textColor: textColor
            )
            for n in firstLine...lastLine {
                // y for line N (relative to documentView origin):
                //   inset + (N-1)*lh
                // Subtract the scroll offset to get viewport y.
                let docY = inset + CGFloat(n - 1) * lh
                let y = docY - state.offsetY

                // Reserve the leading `chevronColumnWidth` points for
                // the fold chevron when folds are wired; diff stripe
                // and bookmark dot shift right so nothing overlaps.
                let leftInset = chevronColumnWidth

                // Git diff stripe — 2pt wide bar at the start of the
                // (post-chevron) left edge. Green = added, blue =
                // modified, red = deleted (drawn as a thin tick at
                // the line's top since the removed line isn't in the
                // working tree).
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
                        stripeRect = CGRect(x: leftInset, y: y, width: 2, height: 2)
                    } else {
                        stripeRect = CGRect(x: leftInset, y: y + 1, width: 2, height: max(2, lh - 2))
                    }
                    context.fill(Path(stripeRect), with: .color(color.opacity(0.85)))
                }

                // Bookmark indicator — small filled circle to the left
                // of the line number, between the diff stripe and the
                // number. Yellow to match the bookmark star elsewhere.
                if bookmarkedLines.contains(n) {
                    let dotSize: CGFloat = max(4, lh * 0.35)
                    let dotRect = CGRect(
                        x: leftInset + 5,
                        y: y + (lh - dotSize) / 2,
                        width: dotSize, height: dotSize
                    )
                    context.fill(Path(ellipseIn: dotRect), with: .color(.yellow))
                }

                // O(1) lookup — `labelSizes` is indexed by digit count
                // (1-based; size [0] is unused). Falls back to NSString
                // measurement only on truly enormous line counts past
                // the cache's precomputed range.
                let digitCount = Self.digitCount(n)
                let labelSize: CGSize
                if digitCount < labelSizes.count {
                    labelSize = labelSizes[digitCount]
                } else {
                    let label = "\(n)" as NSString
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: textColor,
                    ]
                    labelSize = label.size(withAttributes: attrs)
                }
                let x = size.width - labelSize.width - 6
                context.draw(
                    Text(AttributedString("\(n)"))
                        .font(.system(size: max(10, fontSize - 3),
                                      design: .monospaced))
                        .foregroundStyle(Color(nsColor: theme.gutterText)),
                    at: CGPoint(x: x + labelSize.width / 2,
                                y: y + lh / 2)
                )

                // Fold chevron column (leftmost slot, before line
                // numbers but after the diff stripe). Drawn here in
                // the same Canvas pass so it scrolls in lock-step;
                // the click target is handled by `chevronOverlay`.
                if let fs = foldState, !fs.regions.isEmpty {
                    let starts = fs.regionsStarting(at: n)
                    if let first = starts.first {
                        let collapsed = fs.collapsed.contains(first)
                        let glyph = collapsed ? "\u{25B8}" : "\u{25BE}"
                        let chevronColor = NSColor.secondaryLabelColor
                        let attrs: [NSAttributedString.Key: Any] = [
                            .font: font,
                            .foregroundColor: chevronColor,
                        ]
                        let gSize = (glyph as NSString).size(withAttributes: attrs)
                        let gx = (chevronColumnWidth - gSize.width) / 2
                        context.draw(
                            Text(glyph)
                                .font(.system(size: max(10, fontSize - 3),
                                              design: .monospaced))
                                .foregroundStyle(
                                    Color(nsColor: chevronColor)
                                ),
                            at: CGPoint(x: gx + gSize.width / 2,
                                        y: y + lh / 2)
                        )
                    }
                }
            }
        }
    }

    /// Build a digit-count → label size lookup. Index 0 is unused;
    /// indexes 1..maxDigits cover line numbers 1, 10, 100, etc.
    /// Re-measured per Canvas draw rather than cached statically
    /// because font, fontSize, and color can change with theme/zoom.
    private static func labelSizes(
        upTo lastLine: Int,
        font: NSFont,
        textColor: NSColor
    ) -> [CGSize] {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
        ]
        let maxDigits = digitCount(lastLine)
        var sizes: [CGSize] = [.zero]
        sizes.reserveCapacity(maxDigits + 1)
        var sample = ""
        for _ in 0..<maxDigits {
            sample.append("8")  // worst-case glyph width for monospace
            sizes.append((sample as NSString).size(withAttributes: attrs))
        }
        return sizes
    }

    @inline(__always)
    private static func digitCount(_ n: Int) -> Int {
        if n < 10        { return 1 }
        if n < 100       { return 2 }
        if n < 1_000     { return 3 }
        if n < 10_000    { return 4 }
        if n < 100_000   { return 5 }
        if n < 1_000_000 { return 6 }
        return String(n).count
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
