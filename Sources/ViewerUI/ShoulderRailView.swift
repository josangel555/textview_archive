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
    /// Terminal pane open/closed state (#226). Observed directly so the
    /// left-rail bottom-aligned terminal toggle reflects + drives it
    /// without republishing the content tree.
    @ObservedObject var terminalPane: TerminalPaneStore

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
                claudeHasTranscripts: sidebar.claudeHasTranscripts,
                // RECENTS RAIL FIX (2026-06-01): see ContentView.railDataPresence
                // — both rail builders omitted hasRecents, leaving the Recents
                // shoulder toggle permanently "no data". Mirror SidebarView.
                hasRecents: model.recents.isEmpty == false
            )
        )
    }

    var body: some View {
        #if DEBUG
        let _ = BodyProbe.tick("ShoulderRailView")   // TSK-615 re-eval width probe
        #endif
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
                    // BOTTOM-ALIGNED terminal toggle (#226 / UX-D). Lives
                    // on the LEFT shoulder, pushed to the bottom by the
                    // Spacer above — a dedicated control separate from the
                    // panel-accordion buttons (it toggles the bottom shell
                    // pane, not a sidebar panel). Only the left rail carries
                    // it; the right rail leaves the slot empty.
                    if edge == .left {
                        TerminalToggleButton(
                            isOn: terminalPane.isOpen,
                            uiSize: model.uiSize,
                            action: { terminalPane.toggle() }
                        )
                    }
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
        // WHITE rail (owner decision, 2026-06-01). The rail now paints
        // `Palette.textBackground` — pure white in light mode, the SAME tone
        // as the sibling sidebar accordion — so the shoulder reads as a clean
        // continuation of the sidebar rather than a recessed grey activity
        // bar (the prior `underPageBackground` from cca666b). Pure SwiftUI
        // chrome — no NSView nesting, so the compositor rule (LESSONS.md) is
        // untouched.
        //
        // The risk this reintroduces is exactly what cca666b fixed: with a
        // matching-white background, the rail can visually merge into the
        // white sidebar and "vanish". We bound it WITHOUT going grey again by:
        //   (1) a STRONGER inner-edge separator (1.5pt, full separatorColor)
        //       as the now-primary divider between rail and content/sidebar;
        //   (2) full-strength `Palette.labelColor` icons (already the case,
        //       see PanelRailButton) which read crisply on white;
        //   (3) a faint resting hairline-bounded delineation via the
        //       separator overlay below.
        .background(Palette.textBackground)
        // Edge separator on the rail's INNER border so the column stays
        // bounded against the white sidebar/content now that the background
        // no longer contrasts. Bumped to 1.5pt (was 1pt) so it is the clear
        // primary divider. Left/right rails get a vertical hairline on the
        // content-facing edge; the bottom rail gets a horizontal hairline on
        // its top edge.
        .overlay(alignment: railSeparatorAlignment) {
            switch edge {
            case .left, .right:
                Rectangle()
                    .fill(Palette.separator)
                    .frame(width: 1.5)
            case .bottom:
                Rectangle()
                    .fill(Palette.separator)
                    .frame(height: 1.5)
            }
        }
        .accessibilityIdentifier("mdv.rail.\(edge.rawValue)")
    }

    /// Which edge of the rail carries its own hairline separator: the
    /// content-facing edge. Left rail → its trailing edge; right rail →
    /// its leading edge; bottom rail → its top edge.
    private var railSeparatorAlignment: Alignment {
        switch edge {
        case .left:   return .trailing
        case .right:  return .leading
        case .bottom: return .top
        }
    }

    private func button(
        for kind: SidebarPanelKind, present: Bool
    ) -> some View {
        PanelRailButton(
            edge: edge,
            kind: kind,
            isOn: panelLayout.isVisible(kind, dataPresent: present),
            uiSize: model.uiSize,
            action: { panelLayout.toggle(kind, dataPresent: present) },
            // UX-E: every rail button is a redock entry point — right-click
            // → "Move to Left / Right / Bottom". This makes the dock-move
            // discoverable even for a panel still in the left accordion (it
            // has a rail button but no draggable tool-window header yet).
            currentEdge: panelLayout.edge(of: kind),
            onMove: { dest in panelLayout.move(kind, to: dest) }
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
    /// The panel's current dock (UX-E). Drives the "Move to…" context
    /// menu's checkmark / disabled-current state. Defaults to `.left` so
    /// existing call sites compile unchanged.
    var currentEdge: PanelEdge = .left
    /// Redock callback (UX-E). nil ⇒ no redock context menu.
    var onMove: ((PanelEdge) -> Void)? = nil

    var body: some View {
        if !kind.isDockable {
            // A non-dockable panel (FILES) is never a free-standing tool
            // window — no drag source. Single source of truth: the
            // `isDockable` rule, not an open-coded `== .files`.
            core
        } else {
            // TSK-327: the rail ICON is a drag source too — "drag the tool
            // window icon to any shoulder". Click still toggles; a drag
            // starts the same PanelDragPayload session as the headers.
            core.draggable(PanelDragPayload(kind)) {
                PanelDragChip(kind: kind)
            }
        }
    }

    private var core: some View {
        Button(action: action) {
            Image(systemName: kind.systemImage)
                .font(.system(size: uiSize(13), weight: .medium))
                // Off-state was `Color.secondary` — too faint against the
                // recessed rail to read as a control (part of the "can't
                // see the buttons" report). `Palette.labelColor` is the
                // full-strength primary label tone, so off icons are
                // clearly legible; on icons stay accent-tinted.
                .foregroundStyle(isOn ? Color.accentColor : Palette.labelColor)
                .frame(width: uiSize(26), height: uiSize(26))
                .contentShape(Rectangle())
        }
        // UX-H (#230): shared icon style supplies the resting/hover/press
        // fill (accent-tinted when `isOn`), the subtle scale, and the
        // pointing-hand cursor — replacing the open-coded `@State hovering`
        // + background switch this button used to carry.
        .buttonStyle(IconHoverButtonStyle(isSelected: isOn))
        .helpInfo(title: kind.displayName,
                  description: railHelpDescription(kind))
        .accessibilityLabel(kind.displayName)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("mdv.rail.\(edge.rawValue).\(kind.rawValue)")
        // UX-E: right-click to redock. FILES is never a free-standing tool
        // window, so it gets no move menu.
        .contextMenu {
            if let onMove, kind.isDockable {
                ForEach(PanelEdge.allCases, id: \.self) { dest in
                    Button {
                        onMove(dest)
                    } label: {
                        Label(
                            dest == .left ? "Dock in Sidebar" : "Move to \(dest.displayName)",
                            systemImage: dest.systemImage
                        )
                    }
                    // Grey the current dock AND any illegal placement
                    // (the placement validator is the single arbiter).
                    .disabled(dest == currentEdge
                              || !PanelPlacement.isLegal(kind, to: dest))
                }
            }
        }
    }

    /// Longer hover-description (status-bar feed + floating tooltip body)
    /// per panel kind. Title stays the short `displayName`.
    private func railHelpDescription(_ kind: SidebarPanelKind) -> String {
        let verb = isOn ? "Hide" : "Show"
        return "\(verb) the \(kind.displayName) panel"
    }
}

/// The bottom-aligned terminal toggle on the left shoulder (#226). Same
/// visual language as `PanelRailButton` (SF Symbol, accent fill when on,
/// hover affordance) but it drives `TerminalPaneStore.toggle()` rather
/// than a sidebar panel's visibility.
struct TerminalToggleButton: View {
    let isOn: Bool
    let uiSize: (CGFloat) -> CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "apple.terminal")
                .font(.system(size: uiSize(13), weight: .medium))
                .foregroundStyle(isOn ? Color.accentColor : Palette.labelColor)
                .frame(width: uiSize(26), height: uiSize(26))
                .contentShape(Rectangle())
        }
        .buttonStyle(IconHoverButtonStyle(isSelected: isOn))
        .helpInfo(title: "Terminal",
                  description: isOn
                    ? "Hide the bottom terminal pane"
                    : "Show an integrated terminal at the bottom")
        .accessibilityLabel("Terminal")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("mdv.rail.terminalToggle")
    }
}
