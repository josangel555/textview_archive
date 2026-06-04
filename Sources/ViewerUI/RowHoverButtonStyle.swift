import AppKit
import SwiftUI

// MARK: - Shared row hover/press affordance (UIRESP-02 / UIRESP-09)
//
// A single `ButtonStyle` for the many "plain list rows" scattered
// across the app (command palette, cross-search, bookmarks, git
// status, recent-changes, LSP problems). Before this, each of those
// used `.buttonStyle(.plain)` and so was visually inert — no hover
// feedback, no pointing-hand cursor — which made it ambiguous whether
// a row was clickable.
//
// This style adds, additively and uniformly:
//   * a subtle hover background fill (skipped when the row is already
//     showing its own selection background, to avoid double-tinting),
//   * a pressed-state fill + slight opacity drop for click feedback,
//   * an `NSCursor.pointingHand` push on hover / pop on exit, matching
//     the resize-cursor push/pop pattern used by the column resizers.
//
// Visual-only: there is nothing host-testable here beyond "it builds".
// The cursor + hover behaviour requires a live NSApplication + window
// and is exercised by the VM-only UI bundles + the manual checklist.
//
// The cursor push/pop discipline matters: `NSCursor.push()` mutates a
// process-global cursor stack, so every `push()` on hover-in must be
// balanced by exactly one `pop()` on hover-out. We track a per-view
// `pushed` flag (in the modifier below) so a view that disappears
// mid-hover — or receives back-to-back `onHover(true)` callbacks, which
// AppKit can emit — never leaks an unbalanced push that would strand
// the pointing-hand cursor over unrelated UI. This is the same class
// of bug LESSONS.md flags for `NSCursor.set()` leaks.

/// Plain-row button style with hover + pressed affordances.
///
/// Apply with `.buttonStyle(RowHoverButtonStyle())`. Tune the corner
/// radius / inset to match the row's own padding; the defaults suit
/// the sidebar/palette rows (full-bleed rows with internal padding).
struct RowHoverButtonStyle: ButtonStyle {
    /// Corner radius of the hover/press background fill.
    var cornerRadius: CGFloat = 5
    /// When true, the row paints no hover fill (used when the row draws
    /// its own selection/alt-row background and a second tint would
    /// muddy it). The pressed-state fill + cursor still apply.
    var suppressesHoverFill: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .modifier(RowHoverEffect(
                isPressed: configuration.isPressed,
                cornerRadius: cornerRadius,
                suppressesHoverFill: suppressesHoverFill
            ))
    }
}

/// The hover-tracking + cursor + background layer. Split out from the
/// `ButtonStyle` so it can own `@State` (the hover flag + the
/// push-balance guard) — `ButtonStyle.makeBody` is a non-stored
/// context and can't hold view state directly.
private struct RowHoverEffect: ViewModifier {
    let isPressed: Bool
    let cornerRadius: CGFloat
    let suppressesHoverFill: Bool

    @State private var isHovering = false
    /// Guards the global `NSCursor` push/pop stack against unbalanced
    /// pushes — see file header.
    @State private var pushedCursor = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(fillColor)
            )
            .opacity(isPressed ? 0.85 : 1.0)
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    // Only push once even if AppKit re-fires onHover(true).
                    if !pushedCursor {
                        NSCursor.pointingHand.push()
                        pushedCursor = true
                    }
                } else if pushedCursor {
                    NSCursor.pop()
                    pushedCursor = false
                }
            }
            .onDisappear {
                // A view torn down while hovered would otherwise strand
                // an unbalanced push on the global cursor stack.
                if pushedCursor {
                    NSCursor.pop()
                    pushedCursor = false
                }
            }
    }

    private var fillColor: Color {
        if isPressed {
            return Color.primary.opacity(0.12)
        }
        if isHovering && !suppressesHoverFill {
            return Color.primary.opacity(0.06)
        }
        return Color.clear
    }
}

// MARK: - Shared icon-button hover/press affordance (UX-H / #230)
//
// A single `ButtonStyle` for the many small ICON / CHIP controls in the
// chrome (toolbar lens buttons, sidebar header toggles, find-bar icons,
// status-bar chips, shoulder-rail buttons). Before this, each used
// `.buttonStyle(.plain)` and was visually inert on hover, and the few
// that DID light up open-coded their own `@State private var hovering`
// + background switch (PanelRailButton, TerminalToggleButton).
//
// This style adds, additively + uniformly, a subtle resting → hover →
// pressed progression:
//   * hover  : faint primary tint fill + a barely-perceptible scale-up,
//   * pressed : a touch stronger fill + slight scale-DOWN + opacity drop,
//   * an `NSCursor.pointingHand` push on hover (balanced pop on exit /
//     disappear — same global-cursor-stack discipline as
//     `RowHoverButtonStyle`, see that header).
//
// Subtle + tasteful, NOT bouncy: scale deltas are ≤2% and the animation
// is a short ease. Hover state is LOCAL `@State` inside the effect view
// — it never touches DocumentModel (UX-H constraint / over-observation).
//
// Compositor-safe: pure SwiftUI chrome, no NSView nesting; the scale is a
// SwiftUI `.scaleEffect` on the button label only.

/// Icon/chip button style with subtle hover + press feedback.
///
/// Apply with `.buttonStyle(IconHoverButtonStyle())`. The `isSelected`
/// flag lets a toggle-style control (lens button "on", panel rail
/// "visible") show an accent-tinted resting fill that hover/press
/// deepen rather than replace.
struct IconHoverButtonStyle: ButtonStyle {
    /// Corner radius of the hover/press background fill.
    var cornerRadius: CGFloat = 5
    /// When true, paint an accent-tinted resting fill (the control is in
    /// its "on" / selected state). Hover/press then deepen it.
    var isSelected: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .modifier(IconHoverEffect(
                isPressed: configuration.isPressed,
                cornerRadius: cornerRadius,
                isSelected: isSelected
            ))
    }
}

/// Hover-tracking + cursor + background + scale layer. Split from the
/// `ButtonStyle` so it can own `@State` (hover flag + push-balance guard)
/// — `makeBody` can't hold view state directly.
private struct IconHoverEffect: ViewModifier {
    let isPressed: Bool
    let cornerRadius: CGFloat
    let isSelected: Bool

    @State private var isHovering = false
    @State private var pushedCursor = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fillColor)
            )
            .scaleEffect(scale)
            .opacity(isPressed ? 0.9 : 1.0)
            .animation(
                MotionGate.animation(.easeOut(duration: 0.10),
                                     reduceMotion: reduceMotion),
                value: isHovering
            )
            .animation(
                MotionGate.animation(.easeOut(duration: 0.08),
                                     reduceMotion: reduceMotion),
                value: isPressed
            )
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    if !pushedCursor {
                        NSCursor.pointingHand.push()
                        pushedCursor = true
                    }
                } else if pushedCursor {
                    NSCursor.pop()
                    pushedCursor = false
                }
            }
            .onDisappear {
                if pushedCursor {
                    NSCursor.pop()
                    pushedCursor = false
                }
            }
    }

    /// ≤2% scale deltas: a hair up on hover, a hair down on press. Reduce
    /// Motion pins it to 1.0 (no scale) — the fill still conveys state.
    private var scale: CGFloat {
        if reduceMotion { return 1.0 }
        if isPressed { return 0.98 }
        if isHovering { return 1.02 }
        return 1.0
    }

    private var fillColor: Color {
        let accent = Color.accentColor
        if isSelected {
            // Accent-tinted resting fill; hover/press deepen it.
            if isPressed { return accent.opacity(0.30) }
            if isHovering { return accent.opacity(0.24) }
            return accent.opacity(0.18)
        }
        if isPressed { return Color.primary.opacity(0.14) }
        if isHovering { return Color.primary.opacity(0.08) }
        return Color.clear
    }
}

// MARK: - Reduce Motion helper (A11Y-06 support)
//
// Pure decision function so the "should this animation run?" rule is
// host-testable without a live view. The view layer reads
// `@Environment(\.accessibilityReduceMotion)` and feeds it here; the
// returned `Animation?` is `nil` when motion should be suppressed,
// which makes `withAnimation(_:)` apply the change instantly.

enum MotionGate {
    /// Returns `animation` when the user has NOT requested reduced
    /// motion, else `nil` (instant, no interpolation). Callers pass the
    /// result straight into `withAnimation(_:)` / `.animation(_:value:)`.
    static func animation(_ animation: Animation,
                          reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

// MARK: - VoiceOver announcements (A11Y-15)
//
// Thin wrapper over SwiftUI's `AccessibilityNotification.Announcement`
// so call sites stay one-liners and the priority is set consistently.
// Used for transient status that has no on-screen focusable element to
// move VoiceOver to — e.g. a find bar reporting "No results", or
// GoToPath surfacing a validation error.

enum AccessibilityAnnouncer {
    /// Post a VoiceOver announcement. The system drops it silently when
    /// VoiceOver is off, so there's no cost on the common path.
    ///
    /// Note: SwiftUI's `AccessibilityNotification.Announcement` on this
    /// SDK exposes only `init(_:)` + `post()` — no priority knob (that
    /// lives on the iOS UIKit variant). Default-priority is fine for our
    /// transient status messages.
    static func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }
}
