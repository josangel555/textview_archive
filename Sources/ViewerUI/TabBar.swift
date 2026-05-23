import SwiftUI
import ViewerCore

struct TabBar: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        HStack(spacing: 0) {
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
                        .contextMenu {
                            TabContextMenu(model: model, tabIndex: index, tab: tab)
                        }
                        .onDrag {
                            NSItemProvider(object: NSString(string: "mdv-tab:\(index)"))
                        }
                        .onDrop(
                            of: [.plainText],
                            delegate: TabDropDelegate(model: model, targetIndex: index)
                        )
                        if index < model.tabs.tabs.count - 1 {
                            Divider().frame(height: 16)
                        }
                    }
                }
            }
            Button(action: { model.newTab() }) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help("New Tab (⌘T)")
            .padding(.horizontal, 4)
        }
        .frame(height: 30)
        .background(Palette.windowBackground)
    }
}

private struct TabDropDelegate: DropDelegate {
    let model: DocumentModel
    let targetIndex: Int

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let str = obj as? String,
                  str.hasPrefix("mdv-tab:"),
                  let src = Int(str.dropFirst("mdv-tab:".count)) else { return }
            Task { @MainActor in
                guard src != self.targetIndex else { return }
                // Drop onto a row → place the dragged tab in that row's
                // position; the target tab slides to the other side.
                let dst = src < self.targetIndex ? self.targetIndex + 1 : self.targetIndex
                self.model.moveTab(from: src, to: dst)
            }
        }
        return true
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
                    .help("Close Tab (⌘W)")
                    .accessibilityLabel("Close \(tab.title)")
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
