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
    /// The RENDERED (resolved) heights of the adjacent panels — what the
    /// user actually SEES. Owner 2026-08-09 round 2 ("racing past the
    /// mouse, then stuck"): the drag mutates the STORED height, but
    /// `SidebarStackLayout.resolve` can render LESS than stored (crowded
    /// band) — any stored↔rendered gap is a dead zone or a catch-up leap,
    /// and the runaway stored value persists, poisoning every later
    /// session. Fix: at drag START the stored value SNAPS to the rendered
    /// one (no visual change by construction — rendered is what's on
    /// screen), so every subsequent write renders 1:1 AND old runaway
    /// values self-heal on first touch. nil = fall back to the stored
    /// value (pre-measurement pass).
    var renderedAbove: CGFloat? = nil
    var renderedBelow: CGFloat? = nil
    /// How much the PAIR may grow in total before the flex panel hits its
    /// floor (the flex absorbs pair growth by layout). Cascade: a grow
    /// drag takes from the pair neighbor first, then from this slack —
    /// "the third panel won't move" is gone without any panel PUSHING
    /// chrome. 0 = pair-only (the old behavior).
    var flexSlack: CGFloat = 0

    /// The FROZEN drag session (owner 2026-08-12): every input the drag
    /// math reads — the height bases AND the flex budget — snapshotted at
    /// origin. The budget used to be read live per body eval, which fed a
    /// halving feedback loop (the "can't grow past 50%" wall + the mouse
    /// desync). Nil between drags. See `DividerDragSession`.
    @State private var session: DividerDragSession? = nil

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
            // VISIBLE gutter band (owner 2026-08-09): the hit zone used to
            // be transparent with a 1px hairline centred inside — flanked
            // by the old section-container padding it read as an accidental
            // "white → line → white" seam, and the actual grab area had no
            // visual footprint. The band now paints edge-to-edge with a
            // centred grabber pill, so what you see IS the click target.
            Rectangle()
                .fill(Palette.underPageBackground)
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 26, height: 3)
        }
        .frame(height: 12)
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
                if session == nil {
                    // Origin capture: the stored→rendered SNAP (bases are
                    // what the user SEES; the write-through makes stored ==
                    // rendered from the first delta) AND the flex-budget
                    // freeze (a live budget feeds back into itself — the
                    // halving loop). One immutable session for the drag.
                    let baseAbove = heightAbove.map { renderedAbove ?? $0.wrappedValue }
                    let baseBelow = heightBelow.map { renderedBelow ?? $0.wrappedValue }
                    session = DividerDragSession(
                        baseAbove: baseAbove, baseBelow: baseBelow, slack: flexSlack)
                    withTransaction(noAnimationTransaction()) {
                        if let above = heightAbove, let base = baseAbove {
                            above.wrappedValue = bounded(base)
                        }
                        if let below = heightBelow, let base = baseBelow {
                            below.wrappedValue = bounded(base)
                        }
                    }
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
                session = nil
            }
    }

    /// TSK-440 — route the drag by which neighbors own a height:
    ///   * pair       → sum-preserving redistribution between the two,
    ///                  cascading into the ORIGIN flex budget
    ///   * above only → legacy clamp (above grows as you drag down)
    ///   * below only → FILES boundary: drag down grows the flex FILES
    ///                  panel above by SHRINKING the fixed panel below
    /// Internal (not private) as the exact-closure test seam: the drag
    /// gesture's `onChanged` is exactly `apply(delta:)` after origin
    /// capture, so `SidebarDividerWiringTests` exercises the IDENTICAL
    /// routing the live drag drives. Without a live session (the test
    /// seam), a one-shot session is derived from the rendered/live values
    /// — identical inputs to what origin capture would freeze.
    func apply(delta: CGFloat) {
        let live = session ?? DividerDragSession(
            baseAbove: heightAbove.map { renderedAbove ?? $0.wrappedValue },
            baseBelow: heightBelow.map { renderedBelow ?? $0.wrappedValue },
            slack: flexSlack)
        switch (heightAbove, heightBelow) {
        case let (above?, below?):
            // Cascade (owner 2026-08-09): neighbor first, then the flex
            // budget — FROZEN at origin (owner 2026-08-12: a live budget
            // halves itself and desyncs the mouse).
            guard let next = live.pairTargets(delta: delta) else { return }
            above.wrappedValue = bounded(next.above)
            below.wrappedValue = bounded(next.below)
        case let (above?, nil):
            guard let target = live.aboveTarget(delta: delta) else { return }
            above.wrappedValue = bounded(target)
        case let (nil, below?):
            // The flex boundary (drag up grows the panel BELOW, taking
            // from the flex panel above): growth is bounded by the ORIGIN
            // slack so the stored value can't run past what renders.
            guard let target = live.belowTarget(delta: delta) else { return }
            below.wrappedValue = bounded(target)
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
