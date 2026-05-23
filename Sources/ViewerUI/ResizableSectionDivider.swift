import SwiftUI
import ViewerCore

// MARK: - Resizable section divider
//
// 1-px hairline that looks identical to a SwiftUI `Divider()` at rest
// but exposes a 4-px hit zone above + below it. Hovering swaps the
// system cursor to `resizeUpDown`; vertical drag adjusts a height
// binding the parent owns (the section ABOVE this divider).
//
// Interactive drag + cursor hover is not unit-tested on the host —
// AppKit cursor / mouse-tracking events require a live NSApplication
// and a real window. Exercised by the VM-only UI test bundles
// (`Tests/ViewerUITests/...`) and the manual checklist. The clamp
// logic (min-height floor, defaults read-back) lives in
// `SidebarPanelHeights` and IS host-testable.
//
// Layout note: the divider is meant to sit BETWEEN two sections in
// the sidebar `VStack`. It does not own the height of the section
// above; it only mutates the binding the parent passes in. That keeps
// the divider stateless and lets the parent persist via
// `@AppStorage`.
//
// Performance note (resize jank fix, 2026-05):
//   * Implicit SwiftUI animations on the height binding were the
//     dominant cause of the visible jank — each drag delta started
//     a fresh spring curve that the next delta interrupted, so the
//     section's height visually lagged the cursor. All binding
//     writes are now wrapped in a `Transaction` with
//     `disablesAnimations = true`, which makes the height track
//     1:1 with the cursor.
//   * Per-delta writes to the `@AppStorage`-backed binding are
//     fine in absolute terms (UserDefaults writes are in-memory +
//     async-flushed), but to be safe + to make the persistence
//     story obvious we still also commit-on-end. The live drag
//     drives a local `@State` and a parent binding mirror; the
//     final commit + clamp lands in `.onEnded`.
struct ResizableSectionDivider: View {
    /// Binding for the height of the section directly above this
    /// divider. Drag deltas are mirrored through here in real time
    /// (wrapped in a no-animation transaction) so the section
    /// resizes as the user drags.
    @Binding var heightAbove: CGFloat
    /// True when the section above is collapsed (header-only). The
    /// drag handle is still drawn (so the visual divider is uniform)
    /// but interaction is disabled — there's nothing meaningful to
    /// resize when only a header is showing.
    var isAboveCollapsed: Bool = false

    /// Drag origin (the height the section had when the user
    /// first pressed). Nil between drags.
    @State private var dragStartHeight: CGFloat? = nil

    var body: some View {
        ZStack {
            // The hairline. Matches a stock `Divider()` in colour
            // and weight; rendered as the literal Divider so the
            // appearance tracks the system style automatically (dark
            // mode / increased-contrast).
            Divider()
        }
        // 4-px hit zone — wider than the 1-px hairline so the user
        // doesn't have to be pixel-perfect. The Divider itself stays
        // centred inside.
        .frame(height: 4)
        .contentShape(Rectangle())
        .onHover { hovering in
            // Only swap the cursor when the section above can
            // actually be resized — i.e. it's expanded.
            guard !isAboveCollapsed else {
                if !hovering { NSCursor.arrow.set() }
                return
            }
            if hovering {
                NSCursor.resizeUpDown.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(dragGesture)
        .accessibilityIdentifier("mdv.sidebar.resizeHandle")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isAboveCollapsed else { return }
                if dragStartHeight == nil {
                    dragStartHeight = heightAbove
                }
                let base = dragStartHeight ?? heightAbove
                let next = SidebarPanelHeights.clamp(
                    base + value.translation.height
                )
                // No-animation transaction: the dominant cause of
                // jank was implicit interpolation on the height
                // binding, not the UserDefaults write itself. Each
                // delta now mutates the height in a single render
                // pass with no spring smoothing.
                withTransaction(noAnimationTransaction()) {
                    heightAbove = next
                }
            }
            .onEnded { _ in
                // Re-clamp + final commit so the persisted value is
                // always inside the legal range, regardless of any
                // floating-point drift across deltas.
                withTransaction(noAnimationTransaction()) {
                    heightAbove = SidebarPanelHeights.clamp(heightAbove)
                }
                dragStartHeight = nil
            }
    }
}

/// `Transaction` with implicit animations disabled. Wrapping a
/// binding write in this prevents SwiftUI from interpolating the
/// height change — the resize tracks the cursor 1:1 instead of
/// running through a default-spring curve that the next mouse delta
/// would interrupt.
private func noAnimationTransaction() -> Transaction {
    var t = Transaction()
    t.animation = nil
    t.disablesAnimations = true
    return t
}
