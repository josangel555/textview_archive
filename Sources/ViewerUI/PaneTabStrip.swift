import SwiftUI
import ViewerCore

/// I-21 — THE tab strip. One per editor pane, and since the owner's
/// 2026-08-11 generalization ("tab strips should be contained within the
/// pane") it is the ONLY tab strip: the un-split world is simply one pane,
/// so the strip always starts at the pane's edge and never spans over the
/// tool windows (the old window-level `TabBar` is unmounted).
///
/// Reuses `TabBarItem` chips; the strip shows the PANE's tab order and the
/// PANE's own selection, and every action resolves the tab's STORE index
/// at click time (the flat store stays the mutation surface — selection
/// routes through `DocumentModel.selectTab`, which focuses this pane via
/// the coordinator's reconciler).
///
/// Drag layer (`stripReorderable`, shared substrate): dragging a chip
/// reorders it WITHIN this pane (insertion caret); dragging it onto
/// ANOTHER pane's strip moves it there (`PaneDropChannel` rects, the
/// hovered strip highlights accent); dragging it onto a SESSION pill moves
/// the file into that session (the `TabSessionDropChannel` path the window
/// strip owned before the generalization).
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
    /// Measured strip width → width-fitting chips (owner 2026-08-12: the
    /// generalized strip shipped FIXED-width chips, so a crowded strip
    /// silently overflowed into an unindicated horizontal scroll; the
    /// window strip's shrink-to-fit + overflow menu are ported here).
    @State private var availableWidth: CGFloat = 0

    /// Per-pane coordinate space so two strips' frames never mix.
    private var stripSpace: String { "mdv.paneStrip.\(pane.id.uuidString)" }

    var body: some View {
        #if DEBUG
        let _ = BodyProbe.tick("PaneTabStrip")   // TSK-615 re-eval width probe
        #endif
        let tabs = pane.tabIDs.compactMap { id in
            tabCoordinator.tabs.tabs.first { $0.id == id }
        }
        let isSplit = tabCoordinator.paneAssignment.isSplit
        let isDropTarget = dropChannel.hoveredPaneID == pane.id
        // Shrink-to-fit chips (TabBar's width math, TSK-304): reserve the
        // Close Pane button's width when split on top of the "+" reserve
        // the function already carries.
        let tabWidth = TabBar.computedTabWidth(
            available: availableWidth - (isSplit ? model.uiSize(28) : 0),
            count: tabs.count,
            scale: CGFloat(model.zoom))
        HStack(spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                            TabBarItem(
                                tab: tab,
                                isSelected: tab.id == pane.selectedTabID,
                                isBookmarked: tab.url.map { model.bookmarksStore.contains($0) } ?? false,
                                isInSplit: tabCoordinator.splitTabID == tab.id,
                                scale: CGFloat(model.zoom),
                                width: tabWidth,
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
                            // Scroll anchor so the pane's selected tab can be
                            // brought into view (TabBar parity).
                            .id(tab.id)
                            // Same context menu as ever (incl. the Split Pane
                            // Right/Left tear-outs). The index is resolved when
                            // the menu OPENS, so it can't go stale.
                            .contextMenu {
                                if let i = storeIndex(of: tab.id) {
                                    TabContextMenu(model: model, tabIndex: i, tab: tab)
                                }
                            }
                            .stripReorderable(
                                id: tab.id,
                                index: index,
                                ids: pane.tabIDs,
                                space: stripSpace,
                                frames: frameBox,
                                state: $reorder,
                                external: externalTarget(for: tab),
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
                        // The "+" sits BESIDE the last tab (TSK-261 parity —
                        // the window strip's new-tab affordance moved here
                        // with the generalization). Opens in THIS pane.
                        Button {
                            if !isFocusedPane { model.focusPane(id: pane.id) }
                            model.newTab()
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: model.uiSize(11), weight: .medium))
                                .frame(width: model.uiSize(24), height: model.uiSize(24))
                        }
                        .buttonStyle(IconHoverButtonStyle())
                        .helpInfo(title: "New Tab (⌘T)",
                                  description: "Open a new empty tab in this pane")
                        .padding(.horizontal, model.uiSize(4))
                    }
                    .coordinateSpace(name: stripSpace)
                    .stripContentGlobalOrigin(into: frameBox)
                    .overlay(alignment: .leading) {
                        if let x = reorder?.caretX {
                            StripInsertionCaret(x: x, height: model.uiSize(26))
                        }
                    }
                }
                .onChange(of: pane.selectedTabID) { _, sel in
                    if let sel { withAnimation { proxy.scrollTo(sel) } }
                }
            }
            Spacer(minLength: 0)
            // TSK-304 parity: when the strip is crowded (chips pinned at the
            // shrink floor), a pinned dropdown lists this PANE's tabs so any
            // one is reachable without scrolling — the visible indication
            // the fixed-width strip lacked (owner 2026-08-12).
            if TabBar.tabsAreCrowded(
                available: availableWidth - (isSplit ? model.uiSize(28) : 0),
                count: tabs.count,
                scale: CGFloat(model.zoom)) {
                Menu {
                    ForEach(tabs) { tab in
                        Button {
                            if let i = storeIndex(of: tab.id) { model.selectTab(at: i) }
                        } label: {
                            Text((tab.id == pane.selectedTabID ? "✓ " : "")
                                 + (tab.isDirty ? "• " : "") + tab.title)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: model.uiSize(11), weight: .medium))
                        .frame(width: model.uiSize(24), height: model.uiSize(24))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("All tabs in this pane (\(tabs.count)) — jump to any")
                .accessibilityIdentifier("mdv.tab.overflowMenu")
            }
            // The pane's close affordance: absorb my tabs into the neighbor
            // and un-split (never closes tabs — `PaneAssignment.closePane`).
            // Meaningless for the last pane, so it only renders while split.
            if isSplit {
                Button {
                    model.closePane(id: pane.id)
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
        }
        .frame(height: model.uiSize(30))
        // Background measures the strip width (non-invalidating reader) and
        // carries the TabBar bottom-hairline idiom: the line runs under the
        // inactive chips + empty strip; the ACTIVE chip's fill paints over
        // its segment. The drop-target accent tint layers on top.
        .background(
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Palette.windowBackground
                    Rectangle().fill(Palette.separator).frame(height: 1)
                    if isDropTarget { Color.accentColor.opacity(0.18) }
                }
                .onAppear { availableWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in availableWidth = w }
            })
        // Owner 2026-08-12: a hairline ABOVE the strip too, so the strip
        // reads as a bounded band against whatever sits above it.
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.separator).frame(height: 1)
                .allowsHitTesting(false)
        }
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

    /// Cross-strip capability for one chip's drag: a drop on another pane's
    /// strip moves the tab there (`movePaneTab`); a drop on a SESSION pill
    /// moves the file into that session (the window strip's TSK-274 path,
    /// generalized here). Pane strips are hit-tested first; the SOURCE pane
    /// and the ACTIVE session are excluded (both would be no-ops). Session
    /// drops need a file-backed tab + an attached sessions coordinator.
    private func externalTarget(for tab: ViewerCore.Tab) -> StripExternalTarget? {
        let channel = dropChannel
        let box = frameBox
        let coordinator = tabCoordinator
        let sourcePane = pane.id
        let model = self.model
        let sessionsApp = tab.url != nil ? model.sessionsCoordinator : nil
        let sessionChannel = sessionsApp?.tabDragChannel
        return StripExternalTarget(
            toGlobal: { box.globalPoint(fromStrip: $0) },
            hitTest: { point in
                if let paneHit = channel.paneID(
                    at: point,
                    live: Set(coordinator.paneAssignment.panes.map(\.id)),
                    excluding: sourcePane) {
                    return paneHit
                }
                guard let sessionsApp, let sessionChannel else { return nil }
                return sessionChannel.sessionID(
                    at: point,
                    live: Set(sessionsApp.core.sessions.map(\.id)),
                    excluding: sessionsApp.core.activeID)
            },
            setHovered: { id in
                // Route the highlight to whichever strip owns the target;
                // always clear the other (both channels dedup).
                let isPane = id.map { pid in
                    coordinator.paneAssignment.panes.contains { $0.id == pid }
                } ?? false
                channel.setHovered(isPane ? id : nil)
                sessionChannel?.setHovered(isPane ? nil : id)
            },
            // MODEL-level verbs: the full select pipeline must follow the
            // move (file-nav follow/republish — the stale-FileNav bug).
            commit: { tabID, targetID in
                if coordinator.paneAssignment.panes.contains(where: { $0.id == targetID }) {
                    model.movePaneTab(id: tabID, toPane: targetID)
                } else if let sessionsApp {
                    sessionsApp.moveTab(withID: tabID, toSessionID: targetID)
                }
            })
    }

    private func storeIndex(of id: UUID) -> Int? {
        tabCoordinator.tabs.tabs.firstIndex { $0.id == id }
    }
}
