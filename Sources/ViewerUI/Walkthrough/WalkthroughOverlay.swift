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

    /// Frames published by anchor surfaces (sidebar, gitTab) via the
    /// `.walkthroughAnchor(_:)` modifier. Empty until those surfaces
    /// register on first layout. Read by `containerAlignedPopover` to
    /// position against the real rect.
    @State private var anchorFrames: [String: CGRect] = [:]

    /// Drives the transient flash pulse. Bumped to 1 on a `flashNonce`
    /// change (with animation), back to 0 when the pulse settles. Kept
    /// as view-local @State so the animation lives entirely in SwiftUI
    /// and never round-trips through the model.
    @State private var flashPulse: Double = 0
    /// Tracks the last flash nonce we animated so an unrelated overlay
    /// re-render (scroll, popover change) doesn't re-trigger the pulse.
    @State private var lastFlashNonce: Int = 0

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
            // Flash — transient pulse over a line range. Drawn above the
            // persistent highlight so a flash can pulse on top of an
            // existing stripe. Opacity is driven by `flashPulse`, which
            // animates on each `flashNonce` change.
            if let f = bridge.flash,
               f.url == model.currentURL,
               flashPulse > 0 {
                flashStripe(for: f)
            }
            // Popover — anchored according to its anchor enum. Line
            // anchors use the gutter math; sidebar/gitTab use frames
            // published via `WalkthroughAnchorKey`; window anchors
            // center within the overlay bounds.
            if let p = bridge.popover {
                popover(for: p)
            }
        }
        .coordinateSpace(name: "walkthroughOverlay")
        .onPreferenceChange(WalkthroughAnchorKey.self) { frames in
            anchorFrames = frames
        }
        .onChange(of: bridge.flashNonce) { _, nonce in
            triggerFlash(nonce: nonce)
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

    // MARK: - Flash

    /// Transient pulse over a line range. Same gutter line-math as the
    /// persistent stripe; the difference is the fill opacity is keyed on
    /// `flashPulse` (1 → 0 over the flash duration) so it fades out on
    /// its own instead of persisting until the next step.
    @ViewBuilder
    private func flashStripe(
        for f: WalkthroughBridge.FlashRange
    ) -> some View {
        let state = model.sourceScrollState
        let lh = state.lineHeight
        if lh > 0 {
            let inset = state.topInset
            let topDocY = inset + CGFloat(f.startLine - 1) * lh
            let botDocY = inset + CGFloat(f.endLine) * lh
            let y = topDocY - state.offsetY
            let height = max(lh, botDocY - topDocY)
            let visibleTop = max(0, y)
            let visibleBot = min(state.viewportHeight, y + height)
            if visibleBot > visibleTop {
                Rectangle()
                    .fill(color(for: f.style).opacity(0.55 * flashPulse))
                    .frame(height: visibleBot - visibleTop)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .position(x: 0, y: (visibleTop + visibleBot) / 2)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("mdv.walkthrough.flash")
            }
        }
    }

    /// Run the pulse: snap to full opacity, then animate down to zero
    /// over the flash duration, and clear the bridge value once settled.
    /// Guards on the nonce so a re-render that isn't a new flash request
    /// (scroll tick, popover toggle) doesn't restart the animation.
    private func triggerFlash(nonce: Int) {
        guard nonce != lastFlashNonce else { return }
        lastFlashNonce = nonce
        guard let f = bridge.flash else {
            // A clearFlash() bump (e.g. step transition) — settle.
            flashPulse = 0
            return
        }
        let durationSec = max(0.1, Double(f.durationMs) / 1000.0)
        // Snap on instantly so the pulse is visible at peak, then fade.
        flashPulse = 1
        withAnimation(.easeOut(duration: durationSec)) {
            flashPulse = 0
        }
        // Auto-clear the bridge value after the fade so a stale flash
        // doesn't linger as model state. The opacity is already 0 by
        // then; clearing also drops the stripe from the ZStack.
        let nonceAtStart = nonce
        Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(durationSec * 1_000_000_000)
            )
            // Only clear if no newer flash superseded this one.
            if lastFlashNonce == nonceAtStart {
                model.walkthroughBridge.clearFlash()
            }
        }
    }

    // MARK: - Popover

    @ViewBuilder
    private func popover(for p: WalkthroughBridge.PopoverRequest) -> some View {
        // Line anchors are now precisely positioned next to the
        // target line — re-use the gutter's offset math
        // (state.lineHeight × line - offsetY). Other anchor variants
        // still use container-Alignment until the target surfaces
        // expose their frames via PreferenceKey (follow-up).
        if case .line(_, let line) = p.anchor {
            lineAnchoredPopover(for: p, line: line)
        } else {
            containerAlignedPopover(for: p)
        }
    }

    @ViewBuilder
    private func lineAnchoredPopover(
        for p: WalkthroughBridge.PopoverRequest,
        line: Int
    ) -> some View {
        let state = model.sourceScrollState
        let lh = state.lineHeight
        if lh > 0 {
            let inset = state.topInset
            let docY = inset + CGFloat(line - 1) * lh
            let viewportY = docY - state.offsetY
            // Position the popover top edge just below the line so it
            // doesn't cover the line itself. Clip to viewport: if the
            // line is off-screen, hide the popover (the highlight
            // overlay handles the off-screen indicator separately).
            let clamped = max(8, min(viewportY + lh + 4,
                                     state.viewportHeight - 80))
            if viewportY + lh >= 0 && viewportY <= state.viewportHeight {
                popoverCard(for: p)
                    .position(
                        x: 200,   // left-of-center; .position recenters
                        y: clamped + 40   // approx half popover height
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private func containerAlignedPopover(
        for p: WalkthroughBridge.PopoverRequest
    ) -> some View {
        // Look up the surface frame published via WalkthroughAnchorKey.
        // If present, anchor the popover next to the rect (trailing edge
        // of the surface, vertically centered). If absent (surface
        // hasn't registered yet, or anchor is .window/.editor which
        // don't register a frame), fall back to the v1
        // alignment-in-container layout so behavior stays identical
        // before the registration round-trip lands.
        let surfaceID = Self.surfaceKey(for: p.anchor)
        if let surfaceID, let rect = anchorFrames[surfaceID],
           let pos = Self.popoverPosition(forSurfaceRect: rect) {
            popoverCard(for: p)
                .position(x: pos.x, y: pos.y)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topLeading)
        } else {
            let alignment: Alignment = {
                switch p.anchor {
                case .editor:  return .top
                case .sidebar: return .leading
                case .gitTab:  return .leading
                case .line:    return .top    // unreachable here
                case .window:  return .center
                }
            }()
            popoverCard(for: p)
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        }
    }

    /// Pure positioning helper — extracted so the math is unit-testable
    /// without standing up a SwiftUI view tree. Returns nil for
    /// degenerate (zero-size) rects, which the caller treats as "not
    /// laid out yet, use fallback alignment".
    ///
    /// Geometry: anchor surfaces (sidebar/gitTab) live to the left of
    /// the content area, so popovers anchor to the right of the rect.
    /// Horizontal offset is `rect.maxX + gap + popoverHalfWidth` so
    /// SwiftUI's `.position()` (which centers) lands the card cleanly.
    /// Vertical offset tracks `rect.midY`.
    nonisolated static func popoverPosition(
        forSurfaceRect rect: CGRect,
        gap: CGFloat = 12,
        popoverHalfWidth: CGFloat = 180
    ) -> CGPoint? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        return CGPoint(
            x: rect.maxX + gap + popoverHalfWidth,
            y: rect.midY
        )
    }

    /// Map a popover anchor enum to the published surface id, if any.
    /// `.window` / `.editor` / `.line` return nil — they're positioned
    /// by other paths.
    nonisolated static func surfaceKey(for anchor: PopoverAnchor) -> String? {
        switch anchor {
        case .sidebar: return WalkthroughAnchorSurface.sidebar.id
        case .gitTab:  return WalkthroughAnchorSurface.gitTab.id
        case .editor:  return WalkthroughAnchorSurface.editor.id
        case .line, .window: return nil
        }
    }

    /// The popover card itself — body text + Dismiss. Layout-agnostic;
    /// positioning is the caller's job (see `lineAnchoredPopover` vs
    /// `containerAlignedPopover`).
    @ViewBuilder
    private func popoverCard(for p: WalkthroughBridge.PopoverRequest) -> some View {
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
        .accessibilityIdentifier("mdv.walkthrough.popover")
    }
}
