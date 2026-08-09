import SwiftUI
import ViewerKit

// MARK: - UX-H (#230) — custom floating tooltip + hover/press responsiveness
//
// The native macOS `.help(...)` tooltip is slow (~1.5–2s system delay),
// tiny, and unstyled. UX-H replaces it with a custom FLOATING overlay
// that:
//   * appears on hover after a short delay (`TooltipTiming.appearDelay` ≈ 0.6s),
//   * is bigger + cleanly styled (title + optional description, rounded,
//     theme-aware via `Palette` / `.thinMaterial`),
//   * is anchored to the hovered element and clamped inside the window,
//   * dismisses on hover-exit.
//
// OBSERVATION DISCIPLINE (load-bearing — LESSONS.md over-observation
// trap): the only thing that republishes on hover is the small,
// dedicated `TooltipPresenter` ObservableObject — observed ONLY by the
// single overlay mounted at the window root. Per-element hover tracking
// stays LOCAL (`@State` in `FloatingHelpModifier`). DocumentModel is
// NEVER touched on hover. This mirrors the `HelpSink` rationale: a
// hover enter/leave fires on the render thread on every pointer move,
// so routing it through the god-object would republish the whole UI.

// MARK: - Timing / geometry constants

/// Centralized, host-testable timing + geometry for the floating
/// tooltip. Pulled out of the view layer so the "fast appear, slow-ish
/// move, instant dismiss" policy is asserted without a live window.
public enum TooltipTiming {
    /// Delay from hover-enter to the bubble appearing. Below the macOS system
    /// default (~1.5s) so the tooltip still feels responsive, but deliberately
    /// not TOO eager: the owner found 0.3s fired too soon — a pointer merely
    /// passing OVER a control on its way elsewhere flashed a bubble. 0.6s lets a
    /// transient pass-through hover go by without a flash while still beating the
    /// system default (TSK-1209).
    public static let appearDelay: TimeInterval = 0.6

    /// When the pointer slides directly from one helped element to
    /// another while a bubble is already showing, re-target with this
    /// (much shorter) delay instead of the full `appearDelay` — matches
    /// the OS behaviour of tooltips "chaining" across a toolbar without
    /// re-incurring the full warm-up.
    public static let rechainDelay: TimeInterval = 0.05

    /// Whether a fresh hover should use the short re-chain delay: true
    /// when a bubble is ALREADY visible (pointer is gliding across
    /// controls), false on a cold first hover.
    public static func delay(bubbleAlreadyVisible: Bool) -> TimeInterval {
        bubbleAlreadyVisible ? rechainDelay : appearDelay
    }
}

/// Pure geometry helper: place a tooltip bubble of `bubbleSize` relative
/// to the hovered `anchor` rect, clamped inside `container`. Split out so
/// the clamping math is unit-testable with no SwiftUI/AppKit.
///
/// Policy: prefer BELOW the anchor (offset by `gap`); flip ABOVE when it
/// would overflow the bottom edge; then clamp horizontally so the bubble
/// never spills past either side of the container. Returns the bubble's
/// top-left origin in `container`'s coordinate space.
public enum TooltipPlacement {
    public static let gap: CGFloat = 6

    public static func origin(
        anchor: CGRect,
        bubbleSize: CGSize,
        container: CGSize,
        gap: CGFloat = gap
    ) -> CGPoint {
        // Horizontal: center the bubble on the anchor, then clamp.
        var x = anchor.midX - bubbleSize.width / 2
        let maxX = max(0, container.width - bubbleSize.width)
        x = min(max(0, x), maxX)

        // Vertical: below the anchor by default; flip above if the
        // bubble would overflow the bottom edge AND there's room above.
        let below = anchor.maxY + gap
        let above = anchor.minY - gap - bubbleSize.height
        var y: CGFloat
        if below + bubbleSize.height <= container.height {
            y = below
        } else if above >= 0 {
            y = above
        } else {
            // Neither fully fits — pick whichever overflows less and
            // clamp into the container.
            y = below
        }
        let maxY = max(0, container.height - bubbleSize.height)
        y = min(max(0, y), maxY)
        return CGPoint(x: x, y: y)
    }
}

// MARK: - Presenter model

/// A request to show the floating tooltip: the help content plus the
/// anchor rect (in the window coordinate space) it points at.
public struct TooltipRequest: Equatable, Sendable {
    public let info: HelpInfo
    public let anchor: CGRect
    /// Monotonic token so the overlay can drive its fade keyed on
    /// "which request" without comparing rects on every frame.
    public let token: UInt64

    public init(info: HelpInfo, anchor: CGRect, token: UInt64) {
        self.info = info
        self.anchor = anchor
        self.token = token
    }
}

/// Tiny dedicated observable holding the currently-shown tooltip (or
/// `nil`). Deliberately SEPARATE from `DocumentModel` — only the single
/// overlay observes it, so a hover republishes exactly one view, never
/// the content tree. Process-wide `shared` instance seeds the
/// environment default so `.helpInfo` producers and the overlay line up
/// with zero root wiring (same pattern as `HelpSink`).
@MainActor
public final class TooltipPresenter: ObservableObject {
    /// The active request, or `nil` when nothing is shown. Dedupes on
    /// equal value so a redundant push is a no-op (no `objectWillChange`).
    @Published public private(set) var active: TooltipRequest?

    private var tokenCounter: UInt64 = 0

    public nonisolated init() {}

    nonisolated(unsafe) public static let shared = TooltipPresenter()

    /// Show (or re-target) the tooltip for `info` anchored at `anchor`.
    /// Returns the request token. No-op-publishes when the resulting
    /// request equals the current one (same content + anchor).
    @discardableResult
    public func show(_ info: HelpInfo, anchor: CGRect) -> UInt64 {
        tokenCounter &+= 1
        let req = TooltipRequest(info: info, anchor: anchor, token: tokenCounter)
        // Compare on content + anchor only (ignore token) so a re-show of
        // the identical bubble doesn't republish / restart the fade.
        if let cur = active, cur.info == info, cur.anchor == anchor {
            return cur.token
        }
        active = req
        return tokenCounter
    }

    /// Dismiss the tooltip IF the currently-shown request matches
    /// `token`. The token guard prevents a stale hover-exit (the pointer
    /// already moved on to another control that re-armed the bubble) from
    /// yanking the new bubble down. Passing `nil` force-clears.
    public func dismiss(token: UInt64? = nil) {
        guard active != nil else { return }
        if let token, let cur = active, cur.token != token { return }
        active = nil
    }
}

private struct TooltipPresenterKey: EnvironmentKey {
    static let defaultValue: TooltipPresenter = TooltipPresenter.shared
}

public extension EnvironmentValues {
    var tooltipPresenter: TooltipPresenter {
        get { self[TooltipPresenterKey.self] }
        set { self[TooltipPresenterKey.self] = newValue }
    }
}

// MARK: - Named coordinate space for anchor resolution

/// The string key for the window-root coordinate space the `.helpInfo`
/// modifier reports its anchor frame in and the overlay positions
/// against. Both sides must agree, so the name lives in one place.
enum TooltipCoordinateSpace {
    static let name = "mdv.tooltipRoot"
}

/// Window-root coordinate space the `.helpInfo` modifier reports its
/// anchor frame in and the overlay positions against.
public extension CoordinateSpace {
    static var tooltipRoot: CoordinateSpace { .named(TooltipCoordinateSpace.name) }
}

// MARK: - The bubble

/// The styled floating tooltip bubble: a bold title over an optional
/// secondary description, on a rounded `.thinMaterial` card with a hairline
/// border + soft shadow. Theme-aware (material + `Palette` colors resolve
/// per appearance). Scales with `uiScale` (driven by `model.uiSize`).
struct TooltipBubble: View {
    let info: HelpInfo
    /// Zoom factor (== `DocumentModel.zoom`); the bubble's fonts/padding
    /// scale by it so the tooltip grows with the rest of the chrome.
    let uiScale: CGFloat

    /// Max width keeps long descriptions readable (wrap rather than a
    /// mile-wide single line). Scales with zoom.
    private var maxWidth: CGFloat { 320 * uiScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 2 * uiScale) {
            Text(info.title)
                .font(.system(size: 12 * uiScale, weight: .semibold))
                .foregroundStyle(Palette.labelColor)
            if !info.description.isEmpty {
                Text(info.description)
                    .font(.system(size: 11 * uiScale))
                    .foregroundStyle(Palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 9 * uiScale)
        .padding(.vertical, 6 * uiScale)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7 * uiScale, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7 * uiScale, style: .continuous)
                .strokeBorder(Palette.separator, lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 5 * uiScale, y: 2 * uiScale)
        // The bubble is pure decoration over the real (already-accessible)
        // control; VoiceOver reads the control's own label/hint, so hide
        // the duplicate from the a11y tree.
        .accessibilityHidden(true)
        .allowsHitTesting(false)
        .accessibilityIdentifier("mdv.tooltip.bubble")
    }
}

// MARK: - The overlay (mounted once at the window root)

/// The single floating-tooltip overlay. Mounted at the `ContentView`
/// ZStack root inside the `.tooltipRoot` coordinate space. Observes only
/// the small `TooltipPresenter`, so a hover re-bodies just this view.
///
/// It measures the bubble's intrinsic size, runs `TooltipPlacement` to
/// clamp it inside the window, and fades it in/out. Compositor-safe:
/// pure SwiftUI, `allowsHitTesting(false)` so it never steals events from
/// the WKWebView / NSScrollView panes beneath.
struct FloatingTooltipOverlay: View {
    @ObservedObject var presenter: TooltipPresenter
    /// Zoom factor for the bubble (from `DocumentModel.uiSize`/`zoom`).
    let uiScale: CGFloat

    /// Reduce Motion (A11Y-06): suppress the fade when the user has asked
    /// for reduced motion — the bubble then snaps in/out.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Measured intrinsic size of the current bubble. Until it's measured
    /// the bubble is rendered off-screen-transparent so placement uses a
    /// real size, never a (0,0) guess that would flash top-left.
    @State private var bubbleSize: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            if let req = presenter.active {
                // Anchors are reported in the `.tooltipRoot` NAMED space; the
                // overlay's local origin does NOT necessarily coincide with it
                // (the titlebar band's `ignoresSafeArea` shifted the two apart
                // by the titlebar height — bubbles drew ON TOP of the hovered
                // control, hiding what the user was about to click; owner
                // 2026-08-09). Convert through the named space explicitly so
                // any container offset cancels out.
                let overlayFrame = proxy.frame(in: .tooltipRoot)
                let origin = TooltipPlacement.origin(
                    anchor: req.anchor,
                    bubbleSize: bubbleSize,
                    container: overlayFrame.size
                )
                TooltipBubble(info: req.info, uiScale: uiScale)
                    .background(bubbleSizeReader)
                    .opacity(bubbleSize == .zero ? 0 : 1)
                    .position(
                        x: origin.x - overlayFrame.minX + bubbleSize.width / 2,
                        y: origin.y - overlayFrame.minY + bubbleSize.height / 2
                    )
                    // Re-measure when the content changes (token bumps on
                    // every distinct request).
                    .id(req.token)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .animation(
            MotionGate.animation(.easeOut(duration: 0.12), reduceMotion: reduceMotion),
            value: presenter.active?.token
        )
    }

    /// Reports the bubble's laid-out size back into `bubbleSize` via a
    /// preference, so placement uses the real measured dimensions.
    private var bubbleSizeReader: some View {
        GeometryReader { g in
            Color.clear
                .preference(key: TooltipBubbleSizeKey.self, value: g.size)
        }
        .onPreferenceChange(TooltipBubbleSizeKey.self) { size in
            bubbleSize = size
        }
    }
}

private struct TooltipBubbleSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

// MARK: - The unified `.helpInfo` modifier (routed through the overlay)

/// The ONE reusable tooltip modifier the whole app uses. On hover it:
///   1. captures the element's frame in the `.tooltipRoot` space,
///   2. arms a `TooltipTiming` timer (fast — `appearDelay`),
///   3. on fire, pushes `(info, anchor)` into the `TooltipPresenter`.
/// On hover-exit it cancels the pending timer and dismisses (token-
/// guarded so it won't yank a bubble the pointer already re-armed
/// elsewhere).
///
/// Hover state is LOCAL `@State`. The native `.help(info.title)` is kept
/// as a belt-and-suspenders fallback for contexts where the floating
/// overlay isn't mounted (e.g. a detached `Menu` content popover, or a
/// `ContentView`-less host/preview), and the `HelpSink` status-bar feed +
/// a11y label/hint are preserved. So `.helpInfo` is strictly additive
/// over the prior behaviour — it just ALSO floats.
private struct FloatingHelpModifier: ViewModifier {
    let info: HelpInfo
    @Environment(\.tooltipPresenter) private var presenter: TooltipPresenter
    @Environment(\.helpSink) private var sink: HelpSink

    @State private var anchor: CGRect = .zero
    @State private var hovering = false
    /// The pending appear task; cancelled on hover-exit / re-hover.
    @State private var armTask: Task<Void, Never>?
    /// The token of the request we last showed, so hover-exit only
    /// dismisses OUR bubble.
    @State private var shownToken: UInt64?

    func body(content: Content) -> some View {
        content
            // Capture the anchor frame in the window-root space. Tracked
            // as plain `@State` — this does NOT republish DocumentModel.
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { anchor = g.frame(in: .tooltipRoot) }
                        .onChange(of: g.frame(in: .tooltipRoot)) { _, f in
                            anchor = f
                        }
                }
            )
            // Native tooltip kept as a fallback (see header). The custom
            // overlay supersedes it visually when mounted.
            .help(info.title)
            .onHover { isHovering in
                hovering = isHovering
                // Status-bar description feed (unchanged from old behaviour).
                sink.set(isHovering ? info : nil)
                if isHovering {
                    arm()
                } else {
                    cancelAndDismiss()
                }
            }
            .onDisappear { cancelAndDismiss() }
            .accessibilityLabel(Text(info.title))
            .accessibilityHint(Text(info.description))
    }

    private func arm() {
        armTask?.cancel()
        let delay = TooltipTiming.delay(
            bubbleAlreadyVisible: presenter.active != nil
        )
        armTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, hovering else { return }
            shownToken = presenter.show(info, anchor: anchor)
        }
    }

    private func cancelAndDismiss() {
        armTask?.cancel()
        armTask = nil
        presenter.dismiss(token: shownToken)
        shownToken = nil
    }
}

public extension View {
    /// Attach a uniform `HelpInfo` to an interactive element. Shows the
    /// custom FLOATING tooltip (fast, styled, theme-aware) on hover via
    /// the window-root `TooltipPresenter`, keeps the native `.help` +
    /// status-bar feed + a11y label/hint as fallbacks. This is the single
    /// tooltip entry point the whole app should use.
    func helpInfo(_ info: HelpInfo) -> some View {
        modifier(FloatingHelpModifier(info: info))
    }

    /// Convenience overload taking the two strings inline.
    func helpInfo(title: String, description: String) -> some View {
        helpInfo(HelpInfo(title: title, description: description))
    }

    /// Title-only convenience: a tooltip whose description is empty (the
    /// bubble then renders just the bold title). For the many controls
    /// whose old `.help("…")` was a single short phrase — migrate them to
    /// `.helpInfo(title:)` to get the floating bubble without inventing a
    /// description.
    func helpInfo(title: String) -> some View {
        helpInfo(HelpInfo(title: title, description: ""))
    }
}
