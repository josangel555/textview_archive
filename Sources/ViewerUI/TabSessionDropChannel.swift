import SwiftUI

/// Cross-strip drag channel (TSK-274's drag affordance, back as a REAL
/// gesture 2026-07-31): lets the file-tab strip's reorder drag target the
/// SESSION pills, so a tab dropped onto a pill moves its file into that
/// session (`SessionsAppCoordinator.moveTab(withID:toSessionID:)` — which
/// also activates the target session and selects the moved file there).
///
/// Two strips, one drag: the tab strip owns the gesture; the session strip
/// owns the targets. This object is the seam between them —
/// `SessionsAppCoordinator` holds one instance, the session strip records
/// pill frames and renders the highlight, the tab strip hit-tests and
/// commits. Frames are recorded in GLOBAL space because the two strips
/// have different local coordinate spaces (each is its own scroll content);
/// the drag converts its strip-space samples via
/// `StripFrameBox.globalPoint(fromStrip:)`.
///
/// PERF (the chrome re-body budget, `SessionStripReBodyTests`): pill-frame
/// writes are plain stored mutations — frames change on every layout/
/// scroll pass, so publishing them would re-body the strip constantly.
/// ONLY `hoveredSessionID` publishes, deduped, so the session strip
/// re-bodies exactly when the highlight must change: a handful of times
/// per drag, never outside one.
@MainActor
final class TabSessionDropChannel: ObservableObject {

    /// The pill a live tab drag is currently over — drives that pill's
    /// drop-target highlight. Nil outside a drag / when not over a pill.
    @Published private(set) var hoveredSessionID: UUID?

    /// Session-pill frames in GLOBAL (window-root) space.
    private var pillRects: [UUID: CGRect] = [:]

    func recordPill(id: UUID, rect: CGRect) {
        pillRects[id] = rect
    }

    /// Forget a pill (it left the strip). Clears the highlight if it was
    /// the hovered one, so a session closed mid-drag can't stay lit.
    func removePill(id: UUID) {
        pillRects.removeValue(forKey: id)
        if hoveredSessionID == id { setHovered(nil) }
    }

    /// The pill under `point`, restricted to `live` session ids and
    /// excluding `excluding` (the ACTIVE session: dropping a tab on the
    /// session it is already in is a no-op by `moveTab`'s contract, so
    /// its pill must never light up as a target). Entries for ids no
    /// longer in `live` are pruned as a side effect — the channel
    /// outlives individual sessions, same hygiene as `StripFrameBox`.
    func sessionID(at point: CGPoint,
                   live: Set<UUID>,
                   excluding: UUID?) -> UUID? {
        if pillRects.count > live.count {
            pillRects = pillRects.filter { live.contains($0.key) }
        }
        return pillRects.first {
            $0.key != excluding && live.contains($0.key) && $0.value.contains(point)
        }?.key
    }

    /// Set the highlighted pill. Deduped: republishing an unchanged value
    /// would re-body the session strip once per pointer SAMPLE instead of
    /// once per target CHANGE.
    func setHovered(_ id: UUID?) {
        guard hoveredSessionID != id else { return }
        hoveredSessionID = id
    }
}

extension View {
    /// Publish this pill's GLOBAL-space frame into `channel` (and retract
    /// it on disappear). A non-invalidating background reader — same
    /// pattern and reasoning as `stripItemFrame`.
    func sessionDropTargetFrame(id: UUID, into channel: TabSessionDropChannel) -> some View {
        background(
            GeometryReader { geo in
                let f = geo.frame(in: .global)
                Color.clear
                    .onAppear { channel.recordPill(id: id, rect: f) }
                    .onChange(of: f) { _, new in channel.recordPill(id: id, rect: new) }
            }
        )
        .onDisappear { channel.removePill(id: id) }
    }
}
