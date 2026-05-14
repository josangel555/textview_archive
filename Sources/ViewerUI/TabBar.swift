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
                            onSelect: { model.selectTab(at: index) },
                            onClose: { model.closeTab(at: index) }
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
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct TabBarItem: View {
    let tab: ViewerCore.Tab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            ZStack {
                Rectangle()
                    .fill(background)
                HStack(spacing: 6) {
                    Text(tab.title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .font(.system(size: 12))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
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
            return Color(nsColor: .controlBackgroundColor).opacity(0.4)
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
