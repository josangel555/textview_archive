import SwiftUI
import ViewerCore

/// The terminal as a REGULAR tool-window section (owner rework
/// 2026-08-09): same chrome as every other panel (header label +
/// disclosure, `sidebarSectionBodyFrame` body, container), hosting the
/// live `TerminalPaneView` (tab strip + PTY surface). Renders wherever
/// the panel model puts it — the left accordion, the tabbed bottom dock,
/// or a right tool window — with zero placement special-casing.
///
/// SHELL LIFECYCLE: the pane's shells spawn lazily when this body mounts
/// (`setOpen(true)` → `ensureTerminal()` + foreground sync) and drop to
/// background when it unmounts (panel hidden / dock tab deselected /
/// section collapsed) — shells KEEP RUNNING in the background, exactly
/// the old closed-pane behavior.
struct TerminalPanelSection: View {
    @ObservedObject var model: DocumentModel
    @AppStorage(SidebarPanelKind.terminal.expandedStateKey)
    private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            header
                // COMPOSITOR (LESSONS): the terminal surface below is an
                // opaque, layer-backed representable — keep the SwiftUI
                // header on its own layer ABOVE it so it can't be occluded.
                .compositingGroup().zIndex(1)
            if isExpanded {
                TerminalPaneView(store: model.terminalPane, fontSize: model.uiSize(12))
                    .zIndex(0)
                    .sidebarSectionBodyFrame()
                    .onAppear { model.terminalPane.setOpen(true) }
                    .onDisappear { model.terminalPane.setOpen(false) }
            }
        }
        .sidebarSectionContainer()
        // .contain — a bare container id would implicitly combine the pane's
        // descendants (swallowing mdv.terminal.pane from the AX tree).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mdv.terminalSection")
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button(action: { isExpanded.toggle() }) {
                SidebarSectionHeaderLabel(
                    title: "Terminal",
                    isExpanded: isExpanded,
                    uiSize: model.uiSize,
                    dragKind: .terminal
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            Button(action: { model.terminalPane.addTab() }) {
                Image(systemName: "plus")
                    .font(.system(size: model.uiSize(9), weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .helpInfo(title: "New Terminal",
                      description: "Open another shell tab")
            .accessibilityIdentifier("mdv.terminalSection.newTab")
        }
        .sidebarHeaderRow(uiSize: model.uiSize)
    }
}
