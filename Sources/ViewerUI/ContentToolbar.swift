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

    var body: some View {
        HStack(spacing: 10) {
            PathBreadcrumbView(model: model)
                .layoutPriority(-1)   // breadcrumb yields width first
            Spacer(minLength: 8)
            ViewModeControlView(model: model)
        }
        .frame(height: 22)
        .accessibilityIdentifier("mdv.contentToolbar")
    }
}

// MARK: - Breadcrumb (LEFT)

/// Clickable, abbreviatable file-path breadcrumb. Segments come from
/// `model.pathBreadcrumb`; clicking one calls `navigateToBreadcrumb` →
/// `revealInSidebar`. When the row is narrow the middle collapses behind a
/// leading "…" overflow menu that still lists every dropped segment.
private struct PathBreadcrumbView: View {
    @ObservedObject var model: DocumentModel

    /// Show at most this many trailing segments inline; the rest fold into
    /// the "…" overflow menu. Keeps the bar from pushing the mode control
    /// off the right edge on deep paths.
    private let maxInlineSegments = 4

    var body: some View {
        let segments = model.pathBreadcrumb
        if segments.isEmpty {
            // No file — nothing to show (the toolbar Spacer keeps the mode
            // control right-aligned).
            EmptyView()
        } else {
            HStack(spacing: 3) {
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
        .buttonStyle(.plain)
        .help(seg.isFile
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
        .help("Earlier path segments")
        .accessibilityIdentifier("mdv.breadcrumb.overflow")
    }
}

// MARK: - View-mode control (RIGHT)

/// Render | Editor | HEX primary buttons + a `View Only` toggle + a
/// conditional `Format` button. Pure presentation over `ViewMode` — see
/// `ViewModeControl`.
private struct ViewModeControlView: View {
    @ObservedObject var model: DocumentModel

    var body: some View {
        let p = model.viewModePresentation
        HStack(spacing: 8) {
            // Primary lens buttons. Media/PDF/binary hide Editor; a plain
            // .txt hides Render — so the row only shows lenses the file
            // actually offers.
            HStack(spacing: 2) {
                if model.showsRenderPrimary {
                    primaryButton(.render, selected: p.primary == .render && !p.isFormatted)
                }
                if model.showsEditorPrimary {
                    primaryButton(.editor,
                                  selected: p.primary == .editor && !p.isFormatted)
                }
                primaryButton(.hex, selected: p.primary == .hex)
            }
            .accessibilityIdentifier("mdv.viewModeControl")

            // View Only toggle. Meaningful for the Editor lens (Source ↔
            // editable CM6) and HEX (read-only ↔ byte-edit, deferred). For
            // Render it's always on; we still show it (disabled) so the
            // control reads consistently, but only when an editable lens is
            // reachable does it actually drive a swap.
            if model.showsEditorPrimary {
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
                .help("View Only: show the file read-only. Turn off to edit "
                      + "(Editor → editable text; HEX byte-edit is planned).")
                .accessibilityIdentifier("mdv.viewOnlyToggle")
            }

            // Conditional Format button — only for pretty-printable types.
            if model.showsFormatButton {
                formatButton(active: p.isFormatted)
            }
        }
    }

    @ViewBuilder
    private func primaryButton(
        _ primary: ViewModeControl.Primary, selected: Bool
    ) -> some View {
        Button {
            // Preserve the current ViewOnly intent when switching primary:
            // the presentation's viewOnly reads the current mode, and
            // `selectViewPrimary` re-resolves under it. Tapping Editor from
            // a read-only lens lands on Source (ViewOnly on) — the
            // owner-resolved default.
            model.selectViewPrimary(primary, viewOnly: model.viewModePresentation.viewOnly)
        } label: {
            Text(primary.label)
                .font(.system(size: model.uiSize(11),
                              weight: selected ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selected
                              ? Color.accentColor.opacity(0.20)
                              : Color.secondary.opacity(0.10))
                )
                .foregroundStyle(selected ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help(helpText(primary))
        .accessibilityIdentifier("mdv.viewMode.\(primary.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(active
                              ? Color.accentColor.opacity(0.20)
                              : Color.secondary.opacity(0.10))
                )
                .foregroundStyle(active ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .help("Pretty-print this file (JSON / XML / SVG / plist / HTML). "
              + "Click again to return to the raw source.")
        .accessibilityIdentifier("mdv.viewMode.format")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func helpText(_ primary: ViewModeControl.Primary) -> String {
        switch primary {
        case .render:
            return "Show the rich rendering for this file "
                + "(Markdown / image / table / diff / native preview)."
        case .editor:
            return "Show the file as text. With View Only on it's read-only "
                + "source; turn View Only off to edit."
        case .hex:
            return "Show the raw bytes as a hex + ASCII grid."
        }
    }
}
