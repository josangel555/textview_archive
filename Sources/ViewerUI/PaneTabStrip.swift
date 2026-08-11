import SwiftUI
import ViewerCore

/// I-21 S3 — one editor PANE's tab strip (rendered only while the window
/// is split; the classic window-level `TabBar` keeps the un-split world).
/// Reuses `TabBarItem` chips; the strip shows the PANE's tab order and the
/// PANE's own selection, and every action resolves the tab's STORE index
/// at click time (the flat store stays the mutation surface — selection
/// routes through `DocumentModel.selectTab`, which focuses this pane via
/// the coordinator's reconciler).
struct PaneTabStrip: View {
    @ObservedObject var model: DocumentModel
    @ObservedObject var tabCoordinator: TabCoordinator
    let pane: PaneAssignment.Pane
    let isFocusedPane: Bool

    var body: some View {
        let tabs = pane.tabIDs.compactMap { id in
            tabCoordinator.tabs.tabs.first { $0.id == id }
        }
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabs) { tab in
                        TabBarItem(
                            tab: tab,
                            isSelected: tab.id == pane.selectedTabID,
                            isBookmarked: tab.url.map { model.bookmarksStore.contains($0) } ?? false,
                            isInSplit: false,
                            scale: CGFloat(model.zoom),
                            width: model.uiSize(160),
                            onSelect: {
                                if let i = storeIndex(of: tab.id) { model.selectTab(at: i) }
                            },
                            onClose: {
                                if let i = storeIndex(of: tab.id) { model.closeTab(at: i) }
                            }
                        )
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
        .background(Palette.windowBackground)
        .accessibilityElement(children: .contain)
        // The focused marker rides the STRIP id (container-level ids on the
        // pane column don't materialize out-of-process — same bridge quirk
        // family as the tab close-button frames).
        .accessibilityIdentifier(isFocusedPane ? "mdv.paneStrip.focused" : "mdv.paneStrip")
    }

    private func storeIndex(of id: UUID) -> Int? {
        tabCoordinator.tabs.tabs.firstIndex { $0.id == id }
    }
}
