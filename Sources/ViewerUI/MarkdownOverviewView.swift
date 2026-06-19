import AppKit
import SwiftUI
import ViewerCore

/// Scaled overview / minimap of the active markdown document, drawn as a thin
/// vertical strip in the top-right of the source view (TSK-305). It is a
/// satellite map of the document's structure: one band per heading section,
/// each band's height proportional to that section's line span, its fill alpha
/// driven by the section's text density, and heading bands tinted/marked by
/// level. A "you are here" marker tracks the current viewport. Click anywhere
/// on the strip to scroll the source to that proportional line.
///
/// Why a plain SwiftUI `Canvas` in the parent stack (not a custom NSScroller):
/// the native macOS scrollbar is owned by `NSScrollView`; injecting a custom
/// track re-triggers the `NSScrollView.tile()` reentrancy that historically
/// blanked sibling SwiftUI views (see LESSONS.md / `FindMatchMinimapView`'s
/// rationale). The overview stays entirely out of the scroll view's layout
/// pass.
struct MarkdownOverviewView: View {
    /// Precomputed segments for the current document (built off the model's
    /// display text upstream so we don't re-parse on every re-body).
    let segments: [MarkdownOverviewSegment]
    /// 1-based line currently at the top of the viewport, for the marker. Nil
    /// pre-first-paint / zero-line docs.
    let topVisibleLine: Int?
    /// Total document line count (for the marker's height estimate). Optional;
    /// when nil the marker is a thin line at `topVisibleLine`.
    let visibleLineCount: Int?
    /// Theme — bands derive their base color from `gutterBackground`; heading
    /// ticks use the control accent to match the find minimap.
    let theme: SyntaxTheme
    /// Click callback. Argument is the 1-based document line to scroll to.
    /// Caller wires this to `DocumentModel.scrollSource(toLine:)`.
    let onClickLine: (Int) -> Void

    /// Narrow rail — wider than the 10pt find minimap because the overview
    /// carries section bands (it reads as a "map", not a tick strip), but
    /// still slim enough to sit unobtrusively at the top-right.
    static let stripWidth: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                draw(in: context, size: size)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                let bands = MarkdownOverview.bands(
                    for: segments, canvasHeight: geo.size.height)
                if let line = MarkdownOverview.line(atY: location.y, bands: bands) {
                    onClickLine(line)
                }
            }
            .accessibilityIdentifier("mdv.markdownOverview")
            .accessibilityLabel(accessibilityLabel)
        }
        .frame(width: Self.stripWidth)
    }

    private func draw(in context: GraphicsContext, size: CGSize) {
        // Background rail — matches the gutter so it reads as chrome.
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(Color(nsColor: theme.gutterBackground).opacity(0.6)))

        let bands = MarkdownOverview.bands(for: segments, canvasHeight: size.height)
        guard !bands.isEmpty else { return }

        let textColor = Color(nsColor: theme.gutterText)
        let accent = Color(nsColor: NSColor.controlAccentColor)

        for band in bands {
            let h = band.height
            guard h > 0 else { continue }
            // Density-driven body fill: denser sections draw a fuller bar. We
            // inset the fill width by the heading depth so deeper sections read
            // as nested (an H3 bar is narrower than an H1 bar).
            let depth = band.segment.heading?.level ?? 0
            let inset = CGFloat(min(depth, 4)) * 2
            let bodyRect = CGRect(
                x: 2 + inset,
                y: band.y0,
                width: max(1, size.width - 4 - inset),
                height: max(0.5, h - 0.5))
            let alpha = 0.18 + 0.55 * band.segment.density
            context.fill(Path(bodyRect), with: .color(textColor.opacity(alpha)))

            // Heading marker: a 2pt accent tick at the top of each heading
            // band so section starts are scannable.
            if band.segment.heading != nil {
                let tickRect = CGRect(
                    x: 0, y: band.y0,
                    width: size.width, height: 2)
                context.fill(Path(tickRect), with: .color(accent.opacity(0.8)))
            }
        }

        drawViewportMarker(in: context, size: size, bands: bands)
    }

    /// Draw a translucent "you are here" rectangle over the lines currently
    /// visible in the viewport (top → top + visibleLineCount), so the overview
    /// doubles as a scroll position indicator like a code minimap.
    private func drawViewportMarker(
        in context: GraphicsContext,
        size: CGSize,
        bands: [MarkdownOverviewBand]
    ) {
        guard let top = topVisibleLine,
              let y0 = MarkdownOverview.y(forLine: top, bands: bands) else { return }
        let bottomLine = top + max(0, (visibleLineCount ?? 1) - 1)
        let y1 = MarkdownOverview.y(forLine: bottomLine, bands: bands) ?? (y0 + 6)
        let rect = CGRect(
            x: 0, y: y0,
            width: size.width,
            height: max(4, y1 - y0))
        let accent = Color(nsColor: NSColor.controlAccentColor)
        context.fill(Path(rect), with: .color(accent.opacity(0.14)))
        context.stroke(
            Path(rect),
            with: .color(accent.opacity(0.45)),
            lineWidth: 1)
    }

    private var accessibilityLabel: String {
        let headingCount = segments.filter { $0.heading != nil }.count
        if headingCount == 0 {
            return "Document overview"
        }
        return "Document overview: \(headingCount) sections"
    }
}
