import SwiftUI
import ViewerKit
import ViewerCore

/// UX-A (#224) — the content-toolbar that sits DIRECTLY ABOVE the
/// editor/content pane (replacing the old `ModeBar` that lived under the
/// tab strip with a wrap/special-char/Source·Raw·Hex attributes bar).
///
/// Layout:
///   LEFT  = an abbreviatable, navigable breadcrumb of the file path.
///           Clicking a segment reveals that folder/file in the sidebar.
///   RIGHT = the view-mode control: Render | Editor | HEX primary buttons,
///           a `View Only` toggle, and a conditional `Format` button.
///
/// The view-mode control is a PRESENTATION layer over the existing
/// `ViewMode` set (see `ViewModeControl` / the `DocumentModel` UX-A
/// section). It never introduces new modes — it routes through the
/// unchanged `setCurrentViewMode`, so the LOADBUG-sensitive load/routing
/// path is untouched and `editor-set-mode` automation + the
/// `ViewModeMatrixSmokeTests` keep working.
///
/// OBSERVATION DISCIPLINE: `@ObservedObject var model` is the standard
/// narrow channel — this bar must NOT observe per-scroll/per-caret state
/// (those ride `SourceViewChannel` / `TabCoordinator`, observed only by
/// the StatusBar / source subtree). The toolbar re-bodies on the same
/// `DocumentModel` republishes the old ModeBar did (open / close / select
/// / mode-change), which is exactly when its breadcrumb + selection can
/// change.
struct ContentToolbar: View {
    @ObservedObject var model: DocumentModel
    /// I-21 pane toolbars (owner 2026-08-11: "each tab identifies its
    /// content and decides its own visualization"): when set, the toolbar
    /// renders THIS tab's display state — its lens, its segment set, its
    /// path — instead of the app-wide selected tab's. COMMANDS stay
    /// selected-tab-routed: a click in an unfocused pane focuses it on the
    /// same mouse-down (`PaneFocusClickMonitor`), so by action time the
    /// pane's tab IS the selected tab. Nil = the classic un-split toolbar.
    var tab: ViewerCore.Tab? = nil

    var body: some View {
        #if DEBUG
        let _ = BodyProbe.tick("ContentToolbar")   // TSK-615 re-eval width probe
        #endif
        Group {
            if tab != nil {
                // A pane can be dragged NARROW; unbounded compression turns
                // the breadcrumb into chevron litter and the mode segments
                // into slivers (VM capture, 2026-08-11). Degrade in steps
                // instead: full path → file name only → controls only. The
                // mode control never compresses (`.fixedSize` in the row).
                ViewThatFits(in: .horizontal) {
                    toolbarRow(path: .full)
                    toolbarRow(path: .fileOnly)
                    toolbarRow(path: .hidden)
                }
            } else {
                toolbarRow(path: .full)   // the classic un-split bar, unchanged
            }
        }
        .frame(height: model.uiSize(22))
        .accessibilityIdentifier("mdv.contentToolbar")
    }

    private enum PathStyle { case full, fileOnly, hidden }

    @ViewBuilder
    private func toolbarRow(path: PathStyle) -> some View {
        HStack(spacing: model.uiSize(10)) {
            switch path {
            case .full:
                PathBreadcrumbView(model: model, tab: tab)
                    .layoutPriority(-1)   // breadcrumb yields width first
            case .fileOnly:
                PathBreadcrumbView(model: model, tab: tab, fileOnly: true)
            case .hidden:
                EmptyView()
            }
            Spacer(minLength: 8)
            ViewModeControlView(model: model, tab: tab)
                // Pane mode: the mode control is the toolbar's core — it
                // keeps its ideal width and the PATH degrades instead.
                .fixedSize(horizontal: tab != nil, vertical: false)
            CommandPaletteButton(model: model)   // TSK-756: far top-right
        }
    }
}

// MARK: - Breadcrumb (LEFT)

/// Clickable, abbreviatable file-path breadcrumb. Segments come from
/// `model.pathBreadcrumb`; clicking one calls `navigateToBreadcrumb` →
/// `revealInSidebar`. When the row is narrow the middle collapses behind a
/// leading "…" overflow menu that still lists every dropped segment.
private struct PathBreadcrumbView: View {
    @ObservedObject var model: DocumentModel
    var tab: ViewerCore.Tab? = nil
    /// Narrow-pane degradation step (ViewThatFits): just the file segment.
    var fileOnly = false

    /// Show at most this many trailing segments inline; the rest fold into
    /// the "…" overflow menu. Keeps the bar from pushing the mode control
    /// off the right edge on deep paths.
    private let maxInlineSegments = 4

    var body: some View {
        let segments = tab.map { model.pathBreadcrumb(for: $0.url) }
            ?? model.pathBreadcrumb
        if segments.isEmpty {
            // No file — nothing to show (the toolbar Spacer keeps the mode
            // control right-aligned).
            EmptyView()
        } else if fileOnly {
            if let file = segments.last {
                segmentButton(file)   // keeps its mdv.breadcrumb.segment id
            }
        } else {
            HStack(spacing: model.uiSize(3)) {
                let overflow = segments.count > maxInlineSegments
                let inline = overflow
                    ? Array(segments.suffix(maxInlineSegments))
                    : segments
                if overflow {
                    overflowMenu(dropped: Array(
                        segments.prefix(segments.count - maxInlineSegments)))
                    separator
                }
                ForEach(Array(inline.enumerated()), id: \.element.id) { idx, seg in
                    segmentButton(seg)
                    if idx < inline.count - 1 { separator }
                }
            }
            .accessibilityIdentifier("mdv.breadcrumb")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("File path")
        }
    }

    @ViewBuilder
    private func segmentButton(_ seg: DocumentModel.BreadcrumbSegment) -> some View {
        Button {
            model.navigateToBreadcrumb(seg)
        } label: {
            Text(seg.name)
                .font(.system(size: model.uiSize(11),
                              weight: seg.isFile ? .semibold : .regular))
                .foregroundStyle(seg.isFile ? Color.primary : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(IconHoverButtonStyle(cornerRadius: model.uiSize(3)))
        .helpInfo(title: seg.name,
                  description: seg.isFile
                    ? "Reveal \(seg.name) in the sidebar"
                    : "Reveal folder \(seg.name) in the sidebar")
        .accessibilityIdentifier("mdv.breadcrumb.segment")
    }

    @ViewBuilder
    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: model.uiSize(7), weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    /// Leading "…" menu listing the segments that don't fit inline. Each
    /// row navigates to its folder, same as an inline segment.
    @ViewBuilder
    private func overflowMenu(dropped: [DocumentModel.BreadcrumbSegment]) -> some View {
        Menu {
            ForEach(dropped) { seg in
                Button(seg.name) { model.navigateToBreadcrumb(seg) }
            }
        } label: {
            Text("…")
                .font(.system(size: model.uiSize(11), weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .helpInfo(title: "Earlier path segments",
                  description: "Folders above this point in the file's path")
        .accessibilityIdentifier("mdv.breadcrumb.overflow")
    }
}

// MARK: - Command palette button (FAR RIGHT)

/// TSK-756: a discoverability affordance for the command palette. Tapping the
/// far-right ⌘ button opens the same palette the keybinding/menu item does
/// (`model.showPalette()` → `isPalettePresented`), so the feature is reachable
/// without knowing the shortcut.
private struct CommandPaletteButton: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        Button {
            model.showPalette()
        } label: {
            Image(systemName: "command")
                .font(.system(size: model.uiSize(12), weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(IconHoverButtonStyle(cornerRadius: model.uiSize(4)))
        .helpInfo(title: "Command Palette",
                  description: "Open the command palette — search and run any command.")
        .accessibilityIdentifier("mdv.commandPaletteButton")
    }
}

// MARK: - View-mode control (RIGHT)

/// Render | Editor | HEX primary buttons + a `View Only` toggle + a
/// conditional `Format` button. Pure presentation over `ViewMode` — see
/// `ViewModeControl`.
private struct ViewModeControlView: View {
    @ObservedObject var model: DocumentModel
    var tab: ViewerCore.Tab? = nil

    // Per-pane display reads (nil tab = the classic selected-tab reads).
    private var presentation: ViewModeControl.Presentation {
        tab.map { model.viewModePresentation(for: $0) } ?? model.viewModePresentation
    }
    private var segments: [ToolbarModeSegment] {
        tab.map { model.toolbarModeSegments(for: $0) } ?? model.toolbarModeSegments
    }
    private var editorPrimaryShown: Bool {
        tab.map { model.showsEditorPrimary(for: $0) } ?? model.showsEditorPrimary
    }
    private var formatButtonShown: Bool {
        tab.map { model.showsFormatButton(for: $0) } ?? model.showsFormatButton
    }
    private func segmentSelected(
        _ seg: ToolbarModeSegment, _ p: ViewModeControl.Presentation
    ) -> Bool {
        tab.map { model.isToolbarSegmentSelected(seg, presentation: p, tab: $0) }
            ?? model.isToolbarSegmentSelected(seg, presentation: p)
    }

    var body: some View {
        let p = presentation
        HStack(spacing: model.uiSize(8)) {
            // TSK-898 — the primary lenses as a single unified SEGMENTED
            // group (continuous rounded container, hairline dividers between
            // segments, the selected segment filled) instead of three loose
            // buttons. The segment SET + order come from
            // `model.visibleViewPrimaries` (media/PDF/binary hide Editor; a
            // plain .txt hides Render; .hex is always last), so the group
            // only shows lenses the file actually offers. Each segment still
            // routes through the unchanged `selectViewPrimary` — the model is
            // untouched; only the chrome is unified.
            segmentedPrimaries(p)
                .accessibilityIdentifier("mdv.viewModeControl")
                .accessibilityElement(children: .contain)
                .accessibilityLabel("View mode")

            // View Only toggle. Meaningful for the Editor lens (Source ↔
            // editable CM6) and HEX (read-only ↔ byte-edit, deferred). For
            // Render it's always on; we still show it (disabled) so the
            // control reads consistently, but only when an editable lens is
            // reachable does it actually drive a swap.
            // Show for any editable lens: Editor (Source ↔ CM6) OR HEX
            // (read-only ↔ byte-edit). A binary file opens straight into HEX
            // with no Editor lens, so gating on `showsEditorPrimary` alone hid
            // the toggle there and made HEX byte-edit unreachable (TSK-467).
            if editorPrimaryShown || p.primary == .hex {
                Toggle("View Only", isOn: Binding(
                    get: { p.viewOnly },
                    set: { model.setViewOnly($0) }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.mini)
                .font(.system(size: model.uiSize(11)))
                // Render is inherently read-only; the toggle only does
                // something for Editor/HEX. Disable it under Render so the
                // user isn't offered a no-op.
                .disabled(p.primary == .render)
                .helpInfo(title: "View Only",
                          description: "Show the file read-only. Turn off to edit "
                          + "(Editor → editable text; HEX → editable byte grid).")
                .accessibilityIdentifier("mdv.viewOnlyToggle")
            }

            // Conditional Format button — only for pretty-printable types.
            if formatButtonShown {
                formatButton(active: p.isFormatted)
            }
        }
    }

    /// Whether a given primary reads as selected for the current
    /// presentation. Render/Editor are deselected while the Format lens is
    /// active (`isFormatted`) — the Format button owns the selection then.
    private func isSelected(
        _ primary: ViewModeControl.Primary, _ p: ViewModeControl.Presentation
    ) -> Bool {
        switch primary {
        case .render, .editor: return p.primary == primary && !p.isFormatted
        case .hex:             return p.primary == .hex
        }
    }

    /// TSK-898 — the unified segmented mode control: one continuous rounded
    /// container holding the currently-visible primaries, with a hairline
    /// divider between adjacent segments and the selected segment filled.
    /// Built from `model.visibleViewPrimaries` so the segment set/order is
    /// the model's single source of truth.
    @ViewBuilder
    private func segmentedPrimaries(_ p: ViewModeControl.Presentation) -> some View {
        // `toolbarModeSegments` = visibleViewPrimaries (the single source of
        // truth, unchanged) + the synthesized Split segment after Render for
        // markdown/mermaid — Render | Split | Editor | HEX (owner 2026-07-29).
        let segments = self.segments
        let radius = model.uiSize(5)
        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element) { idx, seg in
                if idx > 0 {
                    // Hairline divider between segments. Dim it next to a
                    // filled segment so the selection's edge reads cleanly.
                    Rectangle()
                        .fill(Color.primary.opacity(
                            segmentSelected(seg, p)
                            || segmentSelected(segments[idx - 1], p)
                            ? 0.0 : 0.12))
                        .frame(width: 1, height: model.uiSize(13))
                }
                segment(seg, selected: segmentSelected(seg, p))
            }
        }
        .background(
            // Continuous capsule/rounded container behind the whole group.
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// One segment of the segmented group. The selected segment paints an
    /// accent-tinted fill; taps route through `selectToolbarSegment`, which
    /// preserves the ViewOnly intent for primaries (the owner-resolved
    /// default) and enters/leaves split-editing for the Split segment.
    @ViewBuilder
    private func segment(
        _ seg: ToolbarModeSegment, selected: Bool
    ) -> some View {
        Button {
            model.selectToolbarSegment(seg)
        } label: {
            Text(seg.label)
                .font(.system(size: model.uiSize(11),
                              weight: selected ? .semibold : .regular))
                .padding(.horizontal, model.uiSize(9))
                .padding(.vertical, model.uiSize(2))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .background(
                    // Selected segment fill. Sits INSIDE the group's clip so
                    // the fill's corners follow the container on the ends.
                    selected
                        ? Color.accentColor.opacity(0.18)
                        : Color.clear
                )
        }
        .buttonStyle(.plain)
        .pointingCursor()   // I-07
        .helpInfo(title: "\(seg.label) view", description: helpText(seg))
        .accessibilityIdentifier(segmentAccessibilityID(seg))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Stable AX ids: primaries keep their long-standing
    /// `mdv.viewMode.<raw>` ids (VM tests target them); Split gets its own.
    private func segmentAccessibilityID(_ seg: ToolbarModeSegment) -> String {
        switch seg {
        case .split: return "mdv.viewMode.split"
        case .primary(let p): return "mdv.viewMode.\(p.rawValue)"
        }
    }

    @ViewBuilder
    private func formatButton(active: Bool) -> some View {
        Button {
            // Route through the view-mode lens (not the standalone
            // toggleFormat flag) so `currentViewMode == .formatted` stays
            // authoritative — the button's active state reads off the enum.
            model.toggleFormatLens()
        } label: {
            Text("Format")
                .font(.system(size: model.uiSize(11),
                              weight: active ? .semibold : .regular))
                .padding(.horizontal, model.uiSize(8))
                .padding(.vertical, model.uiSize(2))
                .foregroundStyle(active ? Color.accentColor : .secondary)
        }
        .buttonStyle(IconHoverButtonStyle(cornerRadius: model.uiSize(4),
                                          isSelected: active))
        .helpInfo(title: "Format",
                  description: "Pretty-print this file (JSON / XML / SVG / plist / "
                  + "HTML). Click again to return to the raw source.")
        .accessibilityIdentifier("mdv.viewMode.format")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func helpText(_ seg: ToolbarModeSegment) -> String {
        switch seg {
        case .split:
            return "Edit and preview side by side: the editor on the left, "
                + "the live rendered page on the right, following your typing."
        case .primary(.render):
            return "Show the rich rendering for this file "
                + "(Markdown / image / table / diff / native preview)."
        case .primary(.editor):
            return "Show the file as text. With View Only on it's read-only "
                + "source; turn View Only off to edit."
        case .primary(.hex):
            return "Show the raw bytes as a hex + ASCII grid."
        }
    }
}
