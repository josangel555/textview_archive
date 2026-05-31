import SwiftUI
import ViewerCore

/// One shoulder rail — a thin strip of panel-toggle buttons on a window
/// edge. v1 docks every panel to `.left`, so the left rail carries all
/// nine buttons while the right + bottom rails render as bare empty
/// strips (the frame that future right/bottom-docked panels will use).
///
/// OBSERVATION DISCIPLINE (load-bearing): observes `panelLayout`,
/// `sidebar`, and `model` DIRECTLY via `@ObservedObject`. A button
/// click flips the panel's resolved visibility through
/// `panelLayout.toggle(_:dataPresent:)`, which mutates the store's
/// `@Published overrides` — re-bodying only the rails + the sidebar that
/// observe the store, NOT the whole content tree (PERF #1). It never
/// forwards into `DocumentModel.objectWillChange`. Pinned by
/// `PanelLayoutRepublishInvariantTests`.
///
/// The rail VIEW owns the data-presence computation (root / repo / LSP /
/// claude) so the button's filled-state and the accordion's presence
/// read the SAME heuristic (`SidebarDataPresence`) — they must not
/// diverge.
struct ShoulderRailView: View {
    let edge: PanelEdge
    @ObservedObject var panelLayout: PanelLayoutStore
    /// Data-presence inputs: `rootURL`, `gitRepoRoot`,
    /// `claudeHasTranscripts`. Observed so the button fills re-evaluate
    /// when a folder / repo / transcript set changes.
    @ObservedObject var sidebar: SidebarModel
    /// `uiSize` (zoom) + `currentURL` (LSP-language predicate).
    @ObservedObject var model: DocumentModel

    /// Cross-axis thickness of the rail (width for left/right, height
    /// for bottom). Honors zoom; lands in the 28–32pt activity-bar band.
    private var thickness: CGFloat { model.uiSize(30) }

    /// Per-panel data-presence for the CURRENT inputs. Single heuristic
    /// shared with the accordion (`SidebarView`) via `SidebarDataPresence`.
    private var presence: [SidebarPanelKind: Bool] {
        SidebarDataPresence.evaluate(
            SidebarDataPresence.Inputs(
                hasRoot: sidebar.rootURL != nil,
                hasRepo: model.trackedRepos.trackedRoots.isEmpty == false,
                hasLSPLanguage: model.currentURL.flatMap {
                    LSPLanguageRegistry.default.language(for: $0)
                } != nil,
                claudeHasTranscripts: sidebar.claudeHasTranscripts
            )
        )
    }

    var body: some View {
        let panels = panelLayout.railPanels(on: edge)
        let pres = presence
        Group {
            switch edge {
            case .left, .right:
                VStack(spacing: 2) {
                    ForEach(panels) { kind in
                        button(for: kind, present: pres[kind] ?? false)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .frame(width: thickness)
                .frame(maxHeight: .infinity, alignment: .top)
            case .bottom:
                HStack(spacing: 2) {
                    ForEach(panels) { kind in
                        button(for: kind, present: pres[kind] ?? false)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .frame(height: thickness)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Slightly recessed from the content's `Palette.textBackground`
        // so the rail reads as chrome, not content. Empty rails are a
        // bare strip of this background (no buttons / no header).
        .background(Palette.windowBackground)
        .accessibilityIdentifier("mdv.rail.\(edge.rawValue)")
    }

    private func button(
        for kind: SidebarPanelKind, present: Bool
    ) -> some View {
        PanelRailButton(
            edge: edge,
            kind: kind,
            isOn: panelLayout.isVisible(kind, dataPresent: present),
            uiSize: model.uiSize,
            action: { panelLayout.toggle(kind, dataPresent: present) }
        )
    }
}

/// A single rail toggle button. SF Symbol from `kind.systemImage`,
/// accent-filled when the panel resolves visible, `kind.displayName` as
/// the hover tooltip.
struct PanelRailButton: View {
    let edge: PanelEdge
    let kind: SidebarPanelKind
    let isOn: Bool
    let uiSize: (CGFloat) -> CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: kind.systemImage)
                .font(.system(size: uiSize(13)))
                .frame(width: uiSize(26), height: uiSize(26))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn
                              ? Color.accentColor.opacity(0.18)
                              : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(kind.displayName)
        .accessibilityLabel(kind.displayName)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("mdv.rail.\(edge.rawValue).\(kind.rawValue)")
    }
}
