import Foundation
import ViewerCore
import ViewerKit

/// The mode bar's "Split" segment (owner ask 2026-07-29: markdown's picker
/// should read Render | Split | Editor | HEX).
///
/// Split is deliberately NOT a `ViewMode` case: a ViewMode is a content LENS
/// (persisted per tab, locked per file, exhaustively switched in the render
/// tree), while split-editing is a LAYOUT — the `.editor` lens plus the split
/// pane showing the SAME file's rendered preview. A new enum case would
/// ripple through persistence, per-file locks, lens coercion and every
/// exhaustive switch for what is really just a composition of two shipped
/// pieces: the split pane already previews a file's live UNSAVED buffer
/// (TSK-806) through the debounced off-main renderer.
public enum ModeBarEntry: Hashable {
    case mode(ViewMode)
    /// Markdown edit-and-preview: `.editor` in the main pane + the rendered
    /// split pane on the same file.
    case splitEdit

    public var label: String {
        switch self {
        case .splitEdit: return "Split"
        case .mode(let m): return m.displayName
        }
    }
}

/// One segment of the toolbar's mode control (`ContentToolbar`, TSK-898):
/// the visible primaries plus the synthesized Split segment. The FIRST
/// version of this feature edited the legacy `ModeBar` view instead — which
/// is never mounted — and the partial-T6 pixel pass (owner directive) is
/// what caught the segment missing from the real toolbar.
public enum ToolbarModeSegment: Hashable {
    case primary(ViewModeControl.Primary)
    case split

    public var label: String {
        switch self {
        case .split: return "Split"
        case .primary(let p): return p.label
        }
    }
}

extension DocumentModel {

    /// Picker entries: the plain available modes, with `Split` inserted
    /// after `Rendered` for files that have BOTH a rendered preview and an
    /// editor lens (markdown/mermaid). Pure — host-tested.
    static func modeBarEntries(available: [ViewMode]) -> [ModeBarEntry] {
        var out = available.map(ModeBarEntry.mode)
        if available.contains(.rendered), available.contains(.editor),
           let i = out.firstIndex(of: .mode(.rendered)) {
            out.insert(.splitEdit, at: i + 1)
        }
        return out
    }

    /// Whether the current file supports split-editing at all: it needs a
    /// rendered preview AND an editor lens (markdown/mermaid; not plain
    /// text, not HTML, not media).
    public var splitEditingIsOffered: Bool {
        showsRenderPrimary && showsEditorPrimary
            && ViewModeOptions.availableModes(for: currentURL).contains(.rendered)
    }

    /// The toolbar's segment row: `visibleViewPrimaries` (the TSK-898 single
    /// source of truth) with Split inserted after Render when offered —
    /// Render | Split | Editor | HEX for markdown.
    public var toolbarModeSegments: [ToolbarModeSegment] {
        var out = visibleViewPrimaries.map(ToolbarModeSegment.primary)
        if splitEditingIsOffered,
           let i = out.firstIndex(of: .primary(.render)) {
            out.insert(.split, at: i + 1)
        }
        return out
    }

    /// Whether `segment` should paint selected. Split-editing claims the
    /// selection exclusively — Editor is what the MAIN pane shows, but the
    /// user's chosen arrangement is Split, and two lit segments would read
    /// as a broken control.
    public func isToolbarSegmentSelected(
        _ segment: ToolbarModeSegment, presentation: ViewModeControl.Presentation
    ) -> Bool {
        switch segment {
        case .split:
            return isSplitEditingActive
        case .primary(let p):
            guard !isSplitEditingActive else { return false }
            // Byte-for-byte the toolbar's original per-case rule (TSK-898):
            // render/editor deselect under the Format lens; hex does not.
            switch p {
            case .render, .editor:
                return presentation.primary == p && !presentation.isFormatted
            case .hex:
                return presentation.primary == .hex
            }
        }
    }

    // MARK: per-TAB variants (I-21 pane toolbars — see the
    // DocumentModel+ViewModeControl per-tab section for the rationale)

    /// Per-tab `splitEditingIsOffered`.
    public func splitEditingIsOffered(for tab: ViewerCore.Tab) -> Bool {
        let available = availableViewModes(for: tab)
        return ViewModeControl.showsRender(available: available)
            && ViewModeControl.showsEditor(available: available)
            && (tab.url.map { ViewModeOptions.availableModes(for: $0).contains(.rendered) }
                ?? false)
    }

    /// Per-tab `toolbarModeSegments`.
    public func toolbarModeSegments(for tab: ViewerCore.Tab) -> [ToolbarModeSegment] {
        var out = visibleViewPrimaries(for: tab).map(ToolbarModeSegment.primary)
        if splitEditingIsOffered(for: tab),
           let i = out.firstIndex(of: .primary(.render)) {
            out.insert(.split, at: i + 1)
        }
        return out
    }

    /// Per-tab split-editing state (the tab's OWN lens + flag, not the
    /// selected tab's).
    public func isSplitEditingActive(for tab: ViewerCore.Tab) -> Bool {
        tab.viewMode == .editor && tab.isSplitEditing
    }

    /// Per-tab `isToolbarSegmentSelected`.
    public func isToolbarSegmentSelected(
        _ segment: ToolbarModeSegment,
        presentation: ViewModeControl.Presentation,
        tab: ViewerCore.Tab
    ) -> Bool {
        let splitActive = isSplitEditingActive(for: tab)
        switch segment {
        case .split:
            return splitActive
        case .primary(let p):
            guard !splitActive else { return false }
            switch p {
            case .render, .editor:
                return presentation.primary == p && !presentation.isFormatted
            case .hex:
                return presentation.primary == .hex
            }
        }
    }

    /// Toolbar tap → model change. Split enters split-editing; a primary tap
    /// out of split-editing exits the layout first (the user asked for ONE
    /// pane of that lens).
    public func selectToolbarSegment(_ segment: ToolbarModeSegment) {
        switch segment {
        case .split:
            enterSplitEditing()
        case .primary(let p):
            if isSplitEditingActive { exitSplitEditing() }
            selectViewPrimary(p, viewOnly: viewModePresentation.viewOnly)
        }
    }

    /// True when the SELECTED TAB is in the split-editing layout: editor
    /// lens with the same-file rendered preview inside the tab's content
    /// area. PER-TAB (I-19, owner 2026-08-11) — the old model rode the
    /// window-scoped `splitURL` pane, so switching tabs stranded the
    /// preview on the previous file; each tab now keeps its own
    /// arrangement. A split pane showing a DIFFERENT file (`splitURL`) is
    /// the ordinary side-by-side feature, not this.
    public var isSplitEditingActive: Bool {
        currentViewMode == .editor
            && tabCoordinator.tabs.selected?.isSplitEditing == true
    }

    /// What the mode-bar picker should show selected right now.
    public var modeBarSelection: ModeBarEntry {
        isSplitEditingActive ? .splitEdit : .mode(currentViewMode)
    }

    /// Apply a picker choice. Selecting a plain mode out of split-editing
    /// exits the layout (the user asked for ONE pane of that lens); a
    /// different-file split pane is left alone — it isn't ours.
    public func setModeBarSelection(_ entry: ModeBarEntry) {
        switch entry {
        case .splitEdit:
            enterSplitEditing()
        case .mode(let m):
            if isSplitEditingActive { exitSplitEditing() }
            setCurrentViewMode(m)
        }
    }

    /// Enter markdown edit-and-preview for the SELECTED TAB: editor lens +
    /// the per-tab split flag (the preview renders inside the tab's
    /// content area, tracking the live buffer via `splitPaneText`,
    /// debounced off-main by `SplitMarkdownRenderModel`).
    public func enterSplitEditing() {
        guard currentURL != nil else { return }
        setCurrentViewMode(.editor)
        setSplitEditingOnSelectedTab(true)
    }

    /// Leave the split-editing layout for the selected tab (the editor
    /// lens keeps the main pane).
    public func exitSplitEditing() {
        setSplitEditingOnSelectedTab(false)
    }

    private func setSplitEditingOnSelectedTab(_ on: Bool) {
        guard let idx = tabCoordinator.tabs.selectedIndex else { return }
        var tab = tabCoordinator.tabs.tabs[idx]
        guard tab.isSplitEditing != on else { return }
        tab.isSplitEditing = on
        tabCoordinator.replace(at: idx, with: tab)
    }
}
