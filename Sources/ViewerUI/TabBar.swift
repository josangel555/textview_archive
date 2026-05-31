import SwiftUI
import ViewerCore

struct TabBar: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(model.tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabBarItem(
                                tab: tab,
                                isSelected: model.tabs.selectedIndex == index,
                                isBookmarked: tab.url.map { model.bookmarksStore.contains($0) } ?? false,
                                scale: CGFloat(model.zoom),
                                onSelect: { model.selectTab(at: index) },
                                onClose: { model.closeTab(at: index) }
                            )
                            // item12a: scroll anchor so the active tab can be
                            // brought into view via ScrollViewReader.
                            .id(tab.id)
                            .contextMenu {
                                TabContextMenu(model: model, tabIndex: index, tab: tab)
                            }
                            .onDrag {
                                // Encode the tab's stable id, not its index.
                                // Indices go stale the instant tabs reorder
                                // (another drag, a close, a programmatic
                                // move) between drag-start and drop, which
                                // would move the wrong tab. The id is
                                // resolved back to a live index at drop time.
                                NSItemProvider(object: NSString(string: "mdv-tab:\(tab.id.uuidString)"))
                            }
                            .onDrop(
                                of: [.plainText],
                                delegate: TabDropDelegate(model: model, targetID: tab.id)
                            )
                            if index < model.tabs.tabs.count - 1 {
                                Divider().frame(height: 16)
                            }
                        }
                    }
                }
                // item12a: keep the active tab visible. Fires on programmatic
                // selection too (⌘1-9, command palette, revealInSidebar,
                // close-shifts-selection) — driven by selectedIndex, not a tap
                // closure — so an off-screen selection always scrolls in.
                .onChange(of: model.tabs.selectedIndex) { _, _ in
                    scrollToSelected(proxy)
                }
                .onAppear { scrollToSelected(proxy, animated: false) }
            }
            Button(action: { model.newTab() }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            // 0c: migrated to the uniform HelpInfo model — native tooltip
            // shows the title, the status bar shows the longer description
            // on hover, and a11y label/hint are set from the same source.
            .helpInfo(title: "New Tab (⌘T)",
                      description: "Open a new empty tab in the current session")
            .padding(.horizontal, 4)
        }
        .frame(height: 30)
        .background(Palette.windowBackground)
    }

    /// Bring the currently-selected tab into view. Centers it so a tab near
    /// either edge isn't left half-clipped. No-op when there's no selection.
    private func scrollToSelected(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let i = model.tabs.selectedIndex,
              model.tabs.tabs.indices.contains(i) else { return }
        let id = model.tabs.tabs[i].id
        if animated {
            withAnimation(.easeInOut(duration: 0.18)) {
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}

private struct TabDropDelegate: DropDelegate {
    let model: DocumentModel
    let targetID: UUID

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let str = obj as? String,
                  str.hasPrefix("mdv-tab:"),
                  let srcID = UUID(uuidString: String(str.dropFirst("mdv-tab:".count))) else { return }
            Task { @MainActor in
                Self.reorder(model: self.model, srcID: srcID, targetID: self.targetID)
            }
        }
        return true
    }

    /// Resolve both the dragged tab and the drop-target tab back to
    /// live indices *at drop time* (not at drag-start), then move.
    /// Index-based payloads went stale whenever the strip reordered
    /// between picking up a tab and dropping it; resolving by id here
    /// always targets the tabs the user actually grabbed and aimed at,
    /// and bails cleanly if either has since been closed.
    @MainActor
    static func reorder(model: DocumentModel, srcID: UUID, targetID: UUID) {
        guard srcID != targetID else { return }
        let tabs = model.tabs.tabs
        guard let src = tabs.firstIndex(where: { $0.id == srcID }),
              let target = tabs.firstIndex(where: { $0.id == targetID }) else { return }
        // Drop onto a row → place the dragged tab in that row's
        // position; the target tab slides to the other side.
        let dst = src < target ? target + 1 : target
        model.moveTab(from: src, to: dst)
    }
}

private struct TabContextMenu: View {
    @ObservedObject var model: DocumentModel
    let tabIndex: Int
    let tab: ViewerCore.Tab

    var body: some View {
        Button("Close Tab") { model.closeTab(at: tabIndex) }
        Button("Close Other Tabs") { model.closeOtherTabs(keeping: tabIndex) }
            .disabled(model.tabs.tabs.count <= 1)
        Button("Close Tabs to the Right") { model.closeTabsToRight(of: tabIndex) }
            .disabled(tabIndex >= model.tabs.tabs.count - 1)
        Divider()
        if let url = tab.url {
            // bug6: force-reload this tab from disk regardless of detected
            // change. Dirty editor buffers route through the Keep/Discard
            // prompt (see DocumentModel.refreshTab) so this never silently
            // discards unsaved edits.
            Button("Refresh") { model.refreshTab(at: tabIndex) }
            Divider()
            Button("Copy Path") { Pasteboard.copy(url.path) }
            Button("Reveal in Finder") { Finder.reveal(url) }
            Button("Reveal in Sidebar") {
                model.revealInSidebar(url)
            }
        }
    }
}

struct TabBarItem: View {
    let tab: ViewerCore.Tab
    let isSelected: Bool
    let isBookmarked: Bool
    let scale: CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                Rectangle()
                    .fill(background)
                HStack(spacing: 6) {
                    if let url = tab.url {
                        FileIconView(url: url, isDirectory: false, size: .tree)
                            .frame(width: 14, height: 14)
                    }
                    Text(tab.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        // Bold current tab so the active document is
                        // obvious at a glance.
                        .font(.system(size: 12 * scale, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if tab.isDirty {
                        // Unsaved-edit dot. Sized to match the close
                        // button so the two glyphs occupy the same
                        // visual column when the close button is
                        // hidden (the unhovered, non-selected state).
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7 * scale, height: 7 * scale)
                            .help("Unsaved changes")
                            .accessibilityLabel("Unsaved changes")
                            .accessibilityIdentifier("mdv.tab.dirtyDot")
                    }
                    if isBookmarked {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8 * scale))
                            .foregroundStyle(.yellow)
                            .help("Bookmarked")
                            .accessibilityLabel("Bookmarked")
                    }
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 18, height: 18)  // U2: HIG hit target ≥ ~24pt with padding
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovering || isSelected ? 0.6 : 0)
                    // Fade the close button in/out rather than popping
                    // it. Driven by the hover/selection state so the
                    // glyph eases to visible on hover and back out on
                    // leave instead of snapping.
                    .animation(.easeInOut(duration: 0.12), value: isHovering || isSelected)
                    // 0c: uniform HelpInfo — title for the bubble, longer
                    // description fed to the status bar on hover.
                    .helpInfo(title: "Close Tab (⌘W)",
                              description: "Close \(tab.title)")
                }
                .padding(.horizontal, 10)
            }
            .frame(minWidth: 100, idealWidth: 180, maxWidth: 240)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(tabHelpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var background: Color {
        if isSelected {
            return Color(nsColor: .controlAccentColor).opacity(0.18)
        }
        if isHovering {
            return Palette.controlBackground.opacity(0.4)
        }
        return Color.clear
    }

    private var tabHelpText: String {
        if let url = tab.url { return url.path }
        return tab.title
    }

    private var accessibilityLabel: String {
        let base = "Tab: \(tab.title)"
        return isSelected ? base + ", selected" : base
    }
}
