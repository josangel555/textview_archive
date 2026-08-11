import SwiftUI
import ViewerCore

/// I-21 S3 — one editor PANE's tab strip (rendered only while the window
/// is split; the classic window-level `TabBar` keeps the un-split world).
/// Reuses `TabBarItem` chips; the strip shows the PANE's tab order and the
/// PANE's own selection, and every action resolves the tab's STORE index
/// at click time (the flat store stays the mutation surface — selection
/// routes through `DocumentModel.selectTab`, which focuses this pane via
/// the coordinator's reconciler).
///
/// S4c adds the drag layer (`stripReorderable`, the TabBar substrate):
/// dragging a chip reorders it WITHIN this pane (insertion caret), and
/// dragging it onto ANOTHER pane's strip moves it there — the strip rects
/// ride `PaneDropChannel` (the tab→session-pill pattern); the hovered
/// target strip highlights accent while a drag is over it.
struct PaneTabStrip: View {
    @ObservedObject var model: DocumentModel
    @ObservedObject var tabCoordinator: TabCoordinator
    /// Re-bodies this strip when its drop-target highlight must change
    /// (`hoveredPaneID` is the channel's only published field).
    @ObservedObject var dropChannel: PaneDropChannel
    let pane: PaneAssignment.Pane
    let isFocusedPane: Bool

    /// Leaf-owned drag geometry (see `StripFrameBox` — the box must live
    /// on a leaf view, and its mutations never publish).
    @State private var frameBox = StripFrameBox()
    @State private var reorder: StripReorderState?

    /// Per-pane coordinate space so two strips' frames never mix.
    private var stripSpace: String { "mdv.paneStrip.\(pane.id.uuidString)" }

    var body: some View {
        let tabs = pane.tabIDs.compactMap { id in
            tabCoordinator.tabs.tabs.first { $0.id == id }
        }
        let isDropTarget = dropChannel.hoveredPaneID == pane.id
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        TabBarItem(
                            tab: tab,
                            isSelected: tab.id == pane.selectedTabID,
                            isBookmarked: tab.url.map { model.bookmarksStore.contains($0) } ?? false,
                            isInSplit: false,
                            scale: CGFloat(model.zoom),
                            width: model.uiSize(160),
                            onSelect: {
                                // Swallow the click that terminates a drag
                                // (StripFrameBox.armSelectSuppression).
                                guard !frameBox.shouldSuppressSelect() else { return }
                                if let i = storeIndex(of: tab.id) { model.selectTab(at: i) }
                            },
                            onClose: {
                                if let i = storeIndex(of: tab.id) { model.closeTab(at: i) }
                            }
                        )
                        .stripReorderable(
                            id: tab.id,
                            index: index,
                            ids: pane.tabIDs,
                            space: stripSpace,
                            frames: frameBox,
                            state: $reorder,
                            external: crossPaneTarget(),
                            commit: { draggedID, gap in
                                // Re-resolve against the LIVE pane order —
                                // the strip can change under a drag
                                // (StripReorder.resolveMove rationale).
                                let live = tabCoordinator.paneAssignment
                                    .pane(containing: draggedID)?.tabIDs ?? []
                                guard let move = StripReorder.resolveMove(
                                    itemID: draggedID, ids: live, gap: gap) else { return }
                                tabCoordinator.reorderPaneTab(id: draggedID, to: move.destination)
                            }
                        )
                    }
                }
                .coordinateSpace(name: stripSpace)
                .stripContentGlobalOrigin(into: frameBox)
                .overlay(alignment: .leading) {
                    if let x = reorder?.caretX {
                        StripInsertionCaret(x: x, height: model.uiSize(26))
                    }
                }
            }
            Spacer(minLength: 0)
            // The pane's close affordance: absorb my tabs into the neighbor
            // and un-split (never closes tabs — `PaneAssignment.closePane`).
            Button {
                tabCoordinator.closePane(id: pane.id)
            } label: {
                Image(systemName: "rectangle.split.2x1.slash")
                    .font(.system(size: model.uiSize(11), weight: .medium))
                    .foregroundStyle(Palette.secondaryLabel)
                    .frame(width: model.uiSize(24), height: model.uiSize(24))
                    .contentShape(Rectangle())
            }
            .buttonStyle(IconHoverButtonStyle())
            .helpInfo(title: "Close Pane",
                      description: "Merge this pane's tabs into the neighboring pane")
            .accessibilityIdentifier("mdv.pane.close")
            .padding(.trailing, 4)
        }
        .frame(height: model.uiSize(30))
        .background(isDropTarget
            ? AnyShapeStyle(Color.accentColor.opacity(0.18))
            : AnyShapeStyle(Palette.windowBackground))
        // Drop-target highlight: a visible accent frame while a tab drag
        // from another pane hovers this strip (drop = move it here).
        .overlay {
            if isDropTarget {
                Rectangle()
                    .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        // This strip IS a cross-pane drop target: publish its rect.
        .paneStripDropFrame(id: pane.id, into: dropChannel)
        .accessibilityElement(children: .contain)
        // The focused marker rides the STRIP id (container-level ids on the
        // pane column don't materialize out-of-process — same bridge quirk
        // family as the tab close-button frames).
        .accessibilityIdentifier(isFocusedPane ? "mdv.paneStrip.focused" : "mdv.paneStrip")
    }

    /// Cross-strip capability for one chip's drag: dropping it on another
    /// pane's strip moves the tab there (`movePaneTab` — the destination
    /// pane takes focus and shows it, appended at the end v1). The SOURCE
    /// pane is excluded — a drop on your own strip is a reorder.
    private func crossPaneTarget() -> StripExternalTarget? {
        let channel = dropChannel
        let box = frameBox
        let coordinator = tabCoordinator
        let sourcePane = pane.id
        return StripExternalTarget(
            toGlobal: { box.globalPoint(fromStrip: $0) },
            hitTest: { point in
                channel.paneID(
                    at: point,
                    live: Set(coordinator.paneAssignment.panes.map(\.id)),
                    excluding: sourcePane)
            },
            setHovered: { channel.setHovered($0) },
            commit: { tabID, paneID in
                coordinator.movePaneTab(id: tabID, toPane: paneID)
            })
    }

    private func storeIndex(of id: UUID) -> Int? {
        tabCoordinator.tabs.tabs.firstIndex { $0.id == id }
    }
}
