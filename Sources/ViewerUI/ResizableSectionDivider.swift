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
    /// Height binding for the section directly above this divider, or
    /// nil when the panel above is the flex-fill FILES tree (which owns
    /// no height key — it absorbs whatever the fixed panels release).
    /// Drag deltas are mirrored in real time (wrapped in a no-animation
    /// transaction) so the sections resize as the user drags.
    var heightAbove: Binding<CGFloat>?
    /// TSK-440: height binding for the section directly BELOW. When both
    /// bindings are present the drag is SUM-PRESERVING — height moves
    /// between the adjacent pair (`SidebarResize.redistribute`) instead
    /// of the old above-only mutation that let the flex FILES panel
    /// absorb the slack and made multi-panel resize feel erratic.
    /// With only `heightAbove` the legacy clamp behavior applies; with
    /// only `heightBelow` (the FILES↔accordion boundary) the drag drives
    /// the below panel inversely — drag down grows FILES, shrinks the
    /// tool window.
    var heightBelow: Binding<CGFloat>? = nil
    /// True when the section above is collapsed (header-only). The
    /// drag handle is still drawn (so the visual divider is uniform)
    /// but interaction is disabled — there's nothing meaningful to
    /// resize when only a header is showing.
    var isAboveCollapsed: Bool = false
    /// The RENDER ceiling for the adjacent panels (the window-fraction
    /// clamp SidebarView applies). Drag writes are bounded to it: the
    /// stored height used to run PAST the ceiling while the panel
    /// stopped moving, so the mouse decorrelated and reversing had a
    /// dead zone (owner 2026-08-09 "proportions off"). nil = floor-only
    /// (pre-measurement pass).
    var maxHeight: CGFloat? = nil

    /// Drag origins (the heights the adjacent sections had when the
    /// user first pressed). Nil between drags.
    @State private var dragStartAbove: CGFloat? = nil
    @State private var dragStartBelow: CGFloat? = nil

    /// Tracks whether this divider has an outstanding `NSCursor.push()`
    /// on the global cursor stack, so hover-out / disappear pop exactly
    /// once. See UIRESP-10 below.
    @State private var pushedResizeCursor = false

    /// Which drag mode this divider instance is wired for — the realized-
    /// presence probe label (TSK-440): a wiring slip that drops a divider
    /// from `sidebarBody` (or constructs it with the wrong bindings) flips
    /// the per-role body-eval count `SidebarDividerWiringTests` pins.
    var role: String {
        switch (heightAbove != nil, heightBelow != nil) {
        case (true, true): return "pair"
        case (true, false): return "aboveOnly"
        case (false, true): return "boundary"
        case (false, false): return "inert"
        }
    }

    var body: some View {
        #if DEBUG
        let _ = BodyProbe.tick("ResizableSectionDivider.\(role)")
        #endif
        ZStack {
            // The hairline. Matches a stock `Divider()` in colour
            // and weight; rendered as the literal Divider so the
            // appearance tracks the system style automatically (dark
            // mode / increased-contrast).
            Divider()
        }
        // 10-px hit zone (owner 2026-08-09: 4px was "tiny and very hard
        // to find") — the 1-px hairline stays centred inside, so the
        // visual weight is unchanged while the grab target more than
        // doubles.
        .frame(height: 10)
        .contentShape(Rectangle())
        .onHover { hovering in
            // UIRESP-10: use the balanced push()/pop() cursor stack
            // rather than `set()`. The previous `.set()` / `.arrow.set()`
            // pair clobbered the global cursor unconditionally — on
            // hover-out it forced the arrow even if some other view
            // (e.g. a text field's I-beam) legitimately owned the cursor,
            // and a section collapsing mid-hover stranded the resize
            // cursor entirely. push()/pop() restores whatever cursor was
            // active before we pushed.
            updateCursor(hovering: hovering && !isAboveCollapsed)
        }
        .onDisappear {
            // Balance any outstanding push if the divider is torn down
            // while hovered.
            updateCursor(hovering: false)
        }
        .gesture(dragGesture)
        .accessibilityIdentifier("mdv.sidebar.resizeHandle")
    }

    /// Pushes the resize cursor on hover-in, pops it on hover-out —
    /// exactly once each way, guarded by `pushedResizeCursor` so AppKit
    /// re-firing `onHover(true)` can't leak an unbalanced push.
    private func updateCursor(hovering: Bool) {
        if hovering {
            if !pushedResizeCursor {
                NSCursor.resizeUpDown.push()
                pushedResizeCursor = true
            }
        } else if pushedResizeCursor {
            NSCursor.pop()
            pushedResizeCursor = false
        }
    }

    private var dragGesture: some Gesture {
        // .global — the divider moves as the heights redistribute; local-space
        // translation oscillates + half-tracks (see DraggableSidebar).
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                guard !isAboveCollapsed else { return }
                if dragStartAbove == nil {
                    dragStartAbove = heightAbove?.wrappedValue
                    dragStartBelow = heightBelow?.wrappedValue
                }
                let delta = value.translation.height
                // No-animation transaction: the dominant cause of
                // jank was implicit interpolation on the height
                // binding, not the UserDefaults write itself. Each
                // delta mutates the heights in a single render pass
                // with no spring smoothing.
                withTransaction(noAnimationTransaction()) {
                    apply(delta: delta)
                }
            }
            .onEnded { _ in
                // Re-clamp + final commit so the persisted values are
                // always inside the legal range, regardless of any
                // floating-point drift across deltas.
                withTransaction(noAnimationTransaction()) {
                    if let above = heightAbove {
                        above.wrappedValue = bounded(above.wrappedValue)
                    }
                    if let below = heightBelow {
                        below.wrappedValue = bounded(below.wrappedValue)
                    }
                }
                dragStartAbove = nil
                dragStartBelow = nil
            }
    }

    /// TSK-440 — route the drag by which neighbors own a height:
    ///   * pair       → sum-preserving redistribution between the two
    ///   * above only → legacy clamp (above grows as you drag down)
    ///   * below only → FILES boundary: drag down grows the flex FILES
    ///                  panel above by SHRINKING the fixed panel below
    /// Internal (not private) as the exact-closure test seam: the drag
    /// gesture's `onChanged` is exactly `apply(delta:)` after origin
    /// capture, so `SidebarDividerWiringTests` exercises the IDENTICAL
    /// routing the live drag drives.
    func apply(delta: CGFloat) {
        switch (heightAbove, heightBelow) {
        case let (above?, below?):
            let baseA = dragStartAbove ?? above.wrappedValue
            let baseB = dragStartBelow ?? below.wrappedValue
            let next = SidebarResize.redistribute(above: baseA, below: baseB, delta: delta)
            above.wrappedValue = bounded(next.above)
            below.wrappedValue = bounded(next.below)
        case let (above?, nil):
            let base = dragStartAbove ?? above.wrappedValue
            above.wrappedValue = bounded(base + delta)
        case let (nil, below?):
            let base = dragStartBelow ?? below.wrappedValue
            below.wrappedValue = bounded(base - delta)
        case (nil, nil):
            break
        }
    }

    /// Floor + (when known) render-ceiling clamp — the stored height a drag
    /// writes always equals the height that RENDERS, so movement is 1:1 and
    /// reversing direction responds immediately (no dead zone).
    func bounded(_ height: CGFloat) -> CGFloat {
        let floored = SidebarPanelHeights.clamp(height)
        guard let maxHeight else { return floored }
        return min(floored, max(maxHeight, SidebarPanelHeights.minExpandedHeight))
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
