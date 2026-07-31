import SwiftUI
import ViewerCore

/// Drag-to-reorder plumbing shared by the file tab strip (`TabBar`) and the
/// session tab strip (`SessionTabBar`). The geometry rules live in
/// `ViewerCore.StripReorder` (host-tested); this file is the SwiftUI wiring:
/// measure each item, track one live drag, draw the insertion caret.
///
/// Replaces the old `.onDrag`/`.onDrop` + `NSItemProvider` reorder — see the
/// `StripReorder` doc comment for why that round-trip was abandoned rather
/// than patched.

/// Measured horizontal extent of every strip item, keyed by item id.
///
/// Two deliberate choices here, both forced by the chrome re-body budget
/// (PERF #1, pinned by `ChromeBodyEvalCountTests` + `SessionStripReBodyTests`):
///
/// 1. **A reference type whose mutations don't publish.** Frames change on
///    every layout pass — a sidebar resize or panel toggle changes the
///    computed tab width, hence every frame — so holding them in a `@State`
///    ARRAY would re-body the strip on layout changes the chrome must be
///    inert to. Frames are DRAG-TIME input, not render input.
///    NOTE the flip side: `@State private var box = StripFrameBox()`
///    allocates a fresh object per view-value rebuild, which costs the
///    OWNING view its body-skip — so this box must live on a leaf view
///    (`TabStripContent` / `SessionStripContent`), never on the strip
///    itself. See LESSONS.md 2026-07-27.
/// 2. **No `PreferenceKey`.** The first version collected frames through a
///    preference and wrote them into this box from `onPreferenceChange`.
///    That still failed the guard: SwiftUI's preference propagation costs
///    an extra update cycle per layout by construction, which showed up as
///    exactly one surplus `TabBar` body on EVERY republish — including a
///    find keystroke that changes no layout at all. Writing straight from
///    the geometry reader keeps the measurement free of update cycles.
final class StripFrameBox {
    private var byID: [UUID: (minX: CGFloat, maxX: CGFloat)] = [:]

    func record(id: UUID, minX: CGFloat, maxX: CGFloat) {
        byID[id] = (minX, maxX)
    }

    // MARK: click-vs-drag arbitration

    /// A `DragGesture` attached alongside a Button does NOT stop the button's
    /// action from firing on mouse-up. By the time it fires the strip has
    /// already reordered and the dragged item's `.offset` has been cleared,
    /// so the click lands on whichever tab now sits under the pointer — and
    /// selects THAT one. Owner-reported: "after move, it selects the tab I
    /// moved over, not the one I moved."
    ///
    /// The model layer is already correct (`TabsState.move` carries the
    /// selection with the moved tab), so the fix is to swallow the click
    /// that terminates a drag. Armed continuously while a drag is in flight
    /// and for a short tail after it ends; self-expiring, so a missed
    /// mouse-up can never leave clicks permanently dead.
    private var selectSuppressedUntil: Date = .distantPast

    /// Window kept long enough to cover the mouse-up that ends a drag, short
    /// enough that a deliberate click right after a drop still registers.
    static let selectSuppressionWindow: TimeInterval = 0.3

    func armSelectSuppression(now: Date = Date(),
                              window: TimeInterval = StripFrameBox.selectSuppressionWindow) {
        selectSuppressedUntil = now.addingTimeInterval(window)
    }

    func shouldSuppressSelect(now: Date = Date()) -> Bool {
        now < selectSuppressedUntil
    }

    // MARK: cross-strip geometry (tab → session-pill drop)

    /// Origin of the strip's named coordinate space in GLOBAL (window-root)
    /// space, recorded by `stripContentGlobalOrigin`. Lets a drag whose
    /// gesture reports strip-space points be hit-tested against targets
    /// OUTSIDE this strip (the session pills), which measure globally —
    /// see `TabSessionDropChannel`.
    private var contentOriginInGlobal: CGPoint = .zero

    func recordContentOrigin(_ origin: CGPoint) {
        contentOriginInGlobal = origin
    }

    func globalPoint(fromStrip p: CGPoint) -> CGPoint {
        CGPoint(x: contentOriginInGlobal.x + p.x,
                y: contentOriginInGlobal.y + p.y)
    }

    /// Frames for exactly `ids`, in that order — so the array index of a
    /// frame always equals the item's model index, which is what
    /// `StripReorder`'s gap arithmetic assumes.
    ///
    /// Returns nil when any item has not been measured yet (before the
    /// first layout pass): a partial array would silently shift every
    /// index and drop the dragged tab in the wrong slot, so callers must
    /// refuse to start a drag rather than guess.
    func frames(for ids: [UUID]) -> [StripReorder.ItemFrame]? {
        // Drop entries for items that have since closed; the box outlives
        // individual tabs.
        if byID.count > ids.count {
            let live = Set(ids)
            byID = byID.filter { live.contains($0.key) }
        }
        var out: [StripReorder.ItemFrame] = []
        out.reserveCapacity(ids.count)
        for id in ids {
            guard let f = byID[id] else { return nil }
            out.append(StripReorder.ItemFrame(id: id, minX: f.minX, maxX: f.maxX))
        }
        return out
    }
}

/// The one in-flight strip drag. Nil when nothing is being dragged.
struct StripReorderState: Equatable {
    let itemID: UUID
    let sourceIndex: Int
    /// Live horizontal translation, used to make the dragged item track
    /// the pointer.
    var translation: CGFloat
    /// Insertion gap under the pointer right now (`StripReorder` coords).
    var gap: Int
    /// Item frames snapshotted at drag START. Deliberately NOT re-read
    /// live: the dragged item is `.offset` while dragging, which moves
    /// the frame it reports, so live frames would feed the drag's own
    /// displacement back into the gap and make the caret oscillate.
    let frames: [StripReorder.ItemFrame]
    /// Non-nil while the pointer is over an EXTERNAL drop target (a
    /// session pill): the drop would leave this strip entirely, so the
    /// insertion caret hides — a caret would promise a reorder that
    /// isn't going to happen. See `StripExternalTarget`.
    var externalTargetID: UUID? = nil

    var isNoOp: Bool { StripReorder.isNoOp(source: sourceIndex, gap: gap) }

    /// Caret x, or nil when the drop would not move anything (so a tab
    /// nudged a few points doesn't flash a misleading indicator), or when
    /// the pointer is over an external target (the pill highlight is the
    /// indicator then, not the caret).
    var caretX: CGFloat? {
        guard externalTargetID == nil, !isNoOp else { return nil }
        return StripReorder.caretX(gap: gap, frames: frames)
    }
}

/// Optional cross-strip drop capability for `stripReorderable`: while a
/// drag is live, each pointer sample is converted to global space and
/// hit-tested against targets outside the strip (the session pills).
/// Hovering one hides the reorder caret and highlights the target
/// (`setHovered`); dropping on one commits via `commit` INSTEAD of a
/// reorder. The file-tab strip passes this; the session strip (whose
/// items have no external destination) passes nil.
struct StripExternalTarget {
    /// Strip-space → global space (the space `hitTest` rects live in).
    let toGlobal: (CGPoint) -> CGPoint
    /// The external target under a global point, or nil.
    let hitTest: (CGPoint) -> UUID?
    /// Hover feedback for the target's highlight. May be called once per
    /// pointer sample — the receiver dedups (`TabSessionDropChannel`).
    let setHovered: (UUID?) -> Void
    /// Drop commit: (dragged item id, external target id).
    let commit: (UUID, UUID) -> Void
}

extension View {
    /// Measure this item into `box`. A `.background` reader never
    /// influences its parent's layout (same reasoning as
    /// `TabBar.availableWidth`), and writing to the box invalidates
    /// nothing, so measuring is free of re-body cost.
    func stripItemFrame(id: UUID, space: String, into box: StripFrameBox) -> some View {
        background(
            GeometryReader { geo in
                let f = geo.frame(in: .named(space))
                Color.clear
                    .onAppear { box.record(id: id, minX: f.minX, maxX: f.maxX) }
                    .onChange(of: f) { _, new in
                        box.record(id: id, minX: new.minX, maxX: new.maxX)
                    }
            }
        )
    }

    /// Record the strip CONTENT's origin in GLOBAL space into `box`, so
    /// drag locations (measured in the strip's named space) can be
    /// converted for cross-strip hit-testing (`StripExternalTarget`).
    /// Same non-invalidating background-reader pattern as `stripItemFrame`.
    func stripContentGlobalOrigin(into box: StripFrameBox) -> some View {
        background(
            GeometryReader { geo in
                let f = geo.frame(in: .global)
                Color.clear
                    .onAppear { box.recordContentOrigin(f.origin) }
                    .onChange(of: f) { _, new in box.recordContentOrigin(new.origin) }
            }
        )
    }

    /// Make one strip item draggable-to-reorder.
    ///
    /// `ids` is the strip's items in visual order; `commit` receives the
    /// dragged item's ID and the destination gap in
    /// `TabsState.move(from:to:)` coordinates, and is called ONLY for a real
    /// move — no-op drops are filtered here so every call site can move
    /// unconditionally.
    ///
    /// The ID, not the start-time index, is what's handed over: a tab can
    /// close mid-drag (an external delete, another window) and a stale index
    /// would then move the WRONG tab. Call sites re-resolve it against the
    /// live list, which is the property the old drop-delegate had and this
    /// must not lose.
    ///
    /// `external` (optional) additionally lets the drag target drop zones
    /// OUTSIDE the strip — the tab→session-pill move. See
    /// `StripExternalTarget`.
    func stripReorderable(
        id: UUID,
        index: Int,
        ids: [UUID],
        space: String,
        frames: StripFrameBox,
        state: Binding<StripReorderState?>,
        external: StripExternalTarget? = nil,
        commit: @escaping (UUID, Int) -> Void
    ) -> some View {
        modifier(StripReorderableItem(id: id, index: index, ids: ids, space: space,
                                      frames: frames, state: state,
                                      external: external, commit: commit))
    }
}

private struct StripReorderableItem: ViewModifier {
    /// Drop settle. Short enough to feel immediate, long enough to read as a
    /// glide rather than a jump. Owned here (not by call sites) so the offset
    /// release and the model reorder are guaranteed to share one transaction.
    static let dropAnimation: Animation = .easeOut(duration: 0.18)

    let id: UUID
    let index: Int
    let ids: [UUID]
    let space: String
    let frames: StripFrameBox
    @Binding var state: StripReorderState?
    let external: StripExternalTarget?
    let commit: (UUID, Int) -> Void

    private var isDragging: Bool { state?.itemID == id }

    func body(content: Content) -> some View {
        content
            // Measured BEFORE `.offset` so the resting layout is what the
            // strip records; the drag itself uses a start-time snapshot.
            .stripItemFrame(id: id, space: space, into: frames)
            .offset(x: isDragging ? (state?.translation ?? 0) : 0)
            // Lift the dragged item so it reads as "picked up" and rides
            // over its neighbours instead of being clipped by them.
            .opacity(isDragging ? 0.75 : 1)
            .zIndex(isDragging ? 1 : 0)
            // SIMULTANEOUS, not `.gesture`: the item is a Button, and its
            // click-to-select must keep working. A plain `.gesture` would
            // compete with the button's press gesture; `minimumDistance`
            // keeps an ordinary click from ever starting a drag.
            .simultaneousGesture(drag)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(space))
            .onChanged { value in
                if state?.itemID != id {
                    // Refuse to start on unmeasured geometry rather than
                    // reorder against a partial frame list.
                    guard let snapshot = frames.frames(for: ids) else { return }
                    state = StripReorderState(itemID: id, sourceIndex: index,
                                              translation: 0, gap: index,
                                              frames: snapshot)
                }
                guard var live = state, live.itemID == id else { return }
                // Keep the trailing click suppressed for as long as the drag
                // lasts, not just from its end.
                frames.armSelectSuppression()
                live.translation = value.translation.width
                live.gap = StripReorder.insertionGap(pointerX: value.location.x,
                                                     frames: live.frames)
                // Cross-strip targeting: is the pointer over a session pill?
                // (`setHovered` drives the pill's highlight; the receiver
                // dedups, so calling per-sample is fine.)
                if let ext = external {
                    let target = ext.hitTest(ext.toGlobal(value.location))
                    ext.setHovered(target)
                    live.externalTargetID = target
                }
                state = live
            }
            .onEnded { value in
                let finished = state
                guard let s = finished, s.itemID == id else { state = nil; return }
                // The button's action fires AFTER this; keep it swallowed
                // whether or not the drop turns out to be a real move.
                frames.armSelectSuppression()
                // Cross-strip drop: released over an external target, the
                // item leaves this strip entirely — commit the move instead
                // of a reorder. The highlight clears either way (the drag
                // is over).
                if let ext = external {
                    ext.setHovered(nil)
                    if let target = ext.hitTest(ext.toGlobal(value.location)) {
                        withAnimation(Self.dropAnimation) {
                            state = nil
                            ext.commit(s.itemID, target)
                        }
                        return
                    }
                }
                let gap = StripReorder.insertionGap(pointerX: value.location.x,
                                                    frames: s.frames)
                guard !StripReorder.isNoOp(source: s.sourceIndex, gap: gap) else {
                    // Snap back from wherever it was dropped — animated, so a
                    // no-op drag doesn't teleport either.
                    withAnimation(Self.dropAnimation) { state = nil }
                    return
                }
                // ONE transaction for BOTH the offset release and the reorder.
                //
                // Clearing `state` separately (as this first shipped) zeroes the
                // drag `.offset` INSTANTLY, so the tab teleports back to where
                // the drag started and only then animates to its new slot —
                // "the move animation starts from the tab's original position"
                // (owner, 2026-07-29). Animating both together lets SwiftUI
                // interpolate the layout change against the offset unwinding, so
                // the tab glides from where it was actually dropped.
                withAnimation(Self.dropAnimation) {
                    state = nil
                    commit(s.itemID, gap)
                }
            }
    }
}

/// Accent insertion line showing where a dragged item will land.
struct StripInsertionCaret: View {
    let x: CGFloat
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.accentColor)
            .frame(width: 2, height: height)
            // Centred ON the gap rather than starting at it.
            .offset(x: x - 1)
            .allowsHitTesting(false)
            .accessibilityIdentifier("mdv.strip.insertionCaret")
    }
}
