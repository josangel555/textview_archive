import SwiftUI
import ViewerKit
import ViewerCore

/// Window-root overlay that renders the active walkthrough's visual
/// effects: a line-anchored highlight stripe over the source view, and
/// a floating popover for the active step's `showPopover` action.
///
/// Why a single window-root overlay rather than scattering per-target
/// views: the popover anchors can land on the sidebar, the git tab,
/// the editor — surfaces that don't share a common parent. A
/// `ZStack` overlay at the window root sees them all through the
/// shared coordinate space and avoids threading "popover request"
/// state through every leaf view.
///
/// Line-anchored highlight: we mirror the math from
/// `SourceGutterView`, which converts (lineNumber → docY) using
/// `SourceScrollState.lineHeight + topInset` then subtracts
/// `state.offsetY` to land in viewport coordinates. The overlay sits
/// over the same NSTextView so the result aligns naturally.
@MainActor
public struct WalkthroughOverlay: View {

    @ObservedObject var model: DocumentModel
    @ObservedObject var bridge: WalkthroughBridge

    public init(model: DocumentModel) {
        self.model = model
        self.bridge = model.walkthroughBridge
    }

    public var body: some View {
        ZStack {
            // Highlight overlay — positioned at the same vertical
            // offset the gutter uses for the requested line range.
            if let h = bridge.highlight,
               h.url == model.currentURL {
                highlightStripe(for: h)
            }
            // Popover — anchored according to its anchor enum. Free-
            // floating popovers center near the top of the content
            // area; anchored ones offset toward their target. The
            // anchor math is intentionally approximate in v1; precise
            // positioning needs each target to expose a frame via
            // `PreferenceKey` (follow-up).
            if let p = bridge.popover {
                popover(for: p)
            }
        }
        .allowsHitTesting(bridge.popover != nil)
    }

    // MARK: - Highlight

    /// Translucent stripe spanning the requested line range, drawn at
    /// the source view's leading edge. Sits above NSTextView via
    /// SwiftUI's overlay layer.
    @ViewBuilder
    private func highlightStripe(
        for h: WalkthroughBridge.HighlightRange
    ) -> some View {
        let state = model.sourceScrollState
        let lh = state.lineHeight
        if lh > 0 {
            let inset = state.topInset
            let topDocY = inset + CGFloat(h.startLine - 1) * lh
            let botDocY = inset + CGFloat(h.endLine) * lh
            let y = topDocY - state.offsetY
            let height = max(lh, botDocY - topDocY)
            // Clip to the viewport so an off-screen range doesn't
            // bleed into the chrome above/below the source view.
            let visibleTop = max(0, y)
            let visibleBot = min(state.viewportHeight, y + height)
            if visibleBot > visibleTop {
                Rectangle()
                    .fill(color(for: h.style).opacity(0.18))
                    .overlay(
                        Rectangle()
                            .stroke(color(for: h.style).opacity(0.6),
                                    lineWidth: 1.5)
                    )
                    .frame(height: visibleBot - visibleTop)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .position(
                        x: 0,    // x is recentered by .position; the
                                 // frame(maxWidth) above stretches.
                        y: (visibleTop + visibleBot) / 2
                    )
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("mdv.walkthrough.highlight")
            }
        }
    }

    private func color(for style: HighlightStyle) -> Color {
        switch style {
        case .focus: return Color.accentColor
        case .warn:  return Color(nsColor: .systemOrange)
        case .info:  return Color(nsColor: .systemBlue)
        case .agent: return Color(nsColor: .systemPurple)
        }
    }

    // MARK: - Popover

    @ViewBuilder
    private func popover(for p: WalkthroughBridge.PopoverRequest) -> some View {
        let alignment: Alignment = {
            switch p.anchor {
            case .editor:                       return .top
            case .sidebar:                      return .leading
            case .gitTab:                       return .leading
            case .line:                         return .top
            case .window:                       return .center
            }
        }()
        VStack(alignment: .leading, spacing: 6) {
            Text(p.body)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Dismiss") {
                    model.walkthroughBridge.clearPopover()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
        }
        .padding(12)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Palette.controlBackground)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
        )
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .accessibilityIdentifier("mdv.walkthrough.popover")
    }
}
