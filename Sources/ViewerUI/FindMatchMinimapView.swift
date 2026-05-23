import AppKit
import SwiftUI
import ViewerCore

/// Thin vertical strip rendered alongside the source view's vertical
/// scrollbar. Draws a 2-px tick for every find-bar match, mapped to
/// the document's total line count. Click a tick to jump to that
/// match's line.
///
/// Why this lives **alongside** the native scrollbar rather than
/// replacing it: macOS's scrollbar is owned by NSScrollView; trying to
/// inject a custom track / knob fights both NSScroller compositing
/// AND would re-trigger the `NSScrollView.tile()` reentrancy that
/// historically blanked sibling SwiftUI views (see LESSONS.md). The
/// minimap is a plain SwiftUI Canvas in the parent HStack — no
/// involvement in the scroll view's layout pass.
struct FindMatchMinimapView: View {
    /// 1-based line numbers where matches exist. Read from
    /// `DocumentModel.sourceFindMatchLines`, which the controller
    /// publishes whenever the find query / match set changes.
    let matchLines: [Int]
    /// Total line count of the open document. Read from
    /// `SourceScrollState.lineCount` so it stays in sync with the
    /// gutter's denominator.
    let totalLines: Int
    /// Index into `matchLines` of the active match (the one find-bar
    /// "next" would land on). Nil when no current match.
    let currentMatchIndex: Int?
    /// Theme — accent color is sourced from `theme.accent` to match
    /// other find-bar tinting.
    let theme: SyntaxTheme
    /// Click callback. The argument is the 1-based document line of
    /// the tick that was hit. Caller wires this to
    /// `DocumentModel.requestSourceScrollTo(line:)`.
    let onClickLine: (Int) -> Void

    /// Width is intentionally narrow — 10pt strips reads as a "rail"
    /// next to the scrollbar without stealing horizontal real estate.
    /// The native scroller is ~15pt in `overlay` mode and ~16pt in
    /// `legacy`; 10pt sits comfortably to its left.
    static let stripWidth: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                draw(in: context, size: size)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                if let line = FindMinimapLayout.nearestLine(
                    toY: location.y,
                    matchLines: matchLines,
                    totalLines: totalLines,
                    canvasHeight: geo.size.height,
                    tolerance: max(8, geo.size.height / 50)
                ) {
                    onClickLine(line)
                }
            }
            .accessibilityIdentifier("mdv.findMinimap")
            .accessibilityLabel(accessibilityLabel)
        }
        .frame(width: Self.stripWidth)
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        // Subtle background — matches the gutter's color so the strip
        // reads as part of the chrome, not a foreign element.
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(Color(nsColor: theme.gutterBackground).opacity(0.6))
        )
        let ticks = FindMinimapLayout.ticks(
            matchLines: matchLines,
            totalLines: max(1, totalLines),
            canvasHeight: size.height,
            currentMatchIndex: currentMatchIndex
        )
        let tickHeight: CGFloat = 2
        let accent = Color(nsColor: NSColor.controlAccentColor)
        for tick in ticks {
            let rect = CGRect(
                x: 1,
                y: tick.y,
                width: size.width - 2,
                height: tickHeight
            )
            let color: Color
            if tick.isCurrent {
                // Brighten the current match: full opacity + extend
                // across the strip width so it pops against neighbors.
                color = accent
                let highlightRect = CGRect(
                    x: 0,
                    y: max(0, tick.y - 1),
                    width: size.width,
                    height: tickHeight + 2
                )
                context.fill(Path(highlightRect), with: .color(color))
            } else {
                color = accent.opacity(0.55)
                context.fill(Path(rect), with: .color(color))
            }
        }
    }

    private var accessibilityLabel: String {
        if matchLines.isEmpty {
            return "Find minimap: no matches"
        }
        if let idx = currentMatchIndex {
            return "Find minimap: \(matchLines.count) matches, "
                + "current at line \(matchLines[idx])"
        }
        return "Find minimap: \(matchLines.count) matches"
    }
}
