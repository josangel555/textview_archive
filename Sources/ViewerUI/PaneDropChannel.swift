import SwiftUI

/// I-21 S4c — the cross-PANE geometry channel: two seams, one object,
/// both keyed by pane id and measured in GLOBAL (window-root) space
/// because every pane strip/region is its own local coordinate space.
///
/// 1. **Cross-strip tab drag** (the `TabSessionDropChannel` pattern):
///    each `PaneTabStrip` records its strip rect as a drop target; a tab
///    drag from another pane's strip hit-tests those rects via
///    `StripExternalTarget` and commits `TabCoordinator.movePaneTab`.
///    Only `hoveredPaneID` publishes (deduped) so the target strip
///    re-bodies exactly when its highlight must change.
/// 2. **Content-click focus**: each pane's content region records its
///    rect; `PaneFocusClickMonitor` hit-tests mouse-downs against them
///    so clicking INTO a pane's content (WKWebView clicks never reach a
///    SwiftUI gesture) focuses that pane, like the strip already does.
///
/// Owned by `TabCoordinator` (one per window, same lifetime as the pane
/// assignment). Rect writes are plain stored mutations — frames change
/// on every layout pass, publishing them would re-body split chrome
/// constantly (`SessionStripReBodyTests` reasoning).
@MainActor
public final class PaneDropChannel: ObservableObject {

    /// The pane whose strip a live tab drag is currently over — drives
    /// that strip's drop-target highlight. Nil outside a drag.
    @Published private(set) var hoveredPaneID: UUID?

    /// Pane STRIP rects (drop targets) in global space.
    private var stripRects: [UUID: CGRect] = [:]

    /// Pane CONTENT-REGION rects (click-focus targets) in global space.
    private var contentRects: [UUID: CGRect] = [:]

    public init() {}

    func recordStrip(id: UUID, rect: CGRect) { stripRects[id] = rect }

    /// Forget a strip (its pane closed). Clears the highlight if it was
    /// the hovered one, so a pane closed mid-drag can't stay lit.
    func removeStrip(id: UUID) {
        stripRects.removeValue(forKey: id)
        if hoveredPaneID == id { setHovered(nil) }
    }

    func recordContent(id: UUID, rect: CGRect) { contentRects[id] = rect }
    func removeContent(id: UUID) { contentRects.removeValue(forKey: id) }

    /// The pane strip under `point`, restricted to `live` pane ids and
    /// excluding the drag's SOURCE pane (a drop on your own strip is a
    /// reorder, not a cross-pane move — its caret is the indicator).
    /// Entries for dead panes prune as a side effect (the channel
    /// outlives individual panes, same hygiene as `StripFrameBox`).
    func paneID(at point: CGPoint, live: Set<UUID>, excluding: UUID?) -> UUID? {
        if stripRects.count > live.count {
            stripRects = stripRects.filter { live.contains($0.key) }
        }
        return stripRects.first {
            $0.key != excluding && live.contains($0.key) && $0.value.contains(point)
        }?.key
    }

    /// The pane a content CLICK should focus: the pane whose content
    /// region contains `point`, excluding the already-focused one (a
    /// click there must change nothing). Nil outside every pane.
    func focusTarget(at point: CGPoint, live: Set<UUID>, focused: UUID?) -> UUID? {
        if contentRects.count > live.count {
            contentRects = contentRects.filter { live.contains($0.key) }
        }
        return contentRects.first {
            $0.key != focused && live.contains($0.key) && $0.value.contains(point)
        }?.key
    }

    /// Deduped: republishing an unchanged value would re-body the strip
    /// once per pointer SAMPLE instead of once per target CHANGE.
    func setHovered(_ id: UUID?) {
        guard hoveredPaneID != id else { return }
        hoveredPaneID = id
    }
}

extension View {
    /// Publish this pane STRIP's global frame into `channel` (and retract
    /// it on disappear). Non-invalidating background reader — same
    /// pattern and reasoning as `stripItemFrame`.
    func paneStripDropFrame(id: UUID, into channel: PaneDropChannel) -> some View {
        background(
            GeometryReader { geo in
                let f = geo.frame(in: .global)
                Color.clear
                    .onAppear { channel.recordStrip(id: id, rect: f) }
                    .onChange(of: f) { _, new in channel.recordStrip(id: id, rect: new) }
            }
        )
        .onDisappear { channel.removeStrip(id: id) }
    }

    /// Publish this pane CONTENT REGION's global frame into `channel`
    /// for the click-focus monitor.
    func paneContentFocusFrame(id: UUID, into channel: PaneDropChannel) -> some View {
        background(
            GeometryReader { geo in
                let f = geo.frame(in: .global)
                Color.clear
                    .onAppear { channel.recordContent(id: id, rect: f) }
                    .onChange(of: f) { _, new in channel.recordContent(id: id, rect: new) }
            }
        )
        .onDisappear { channel.removeContent(id: id) }
    }
}
