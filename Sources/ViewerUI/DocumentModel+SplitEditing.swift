import Foundation
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

    /// True when the current tab is in the split-editing layout: editor lens
    /// with the split pane previewing the SAME file. A split showing a
    /// DIFFERENT file is the ordinary side-by-side feature, not this.
    public var isSplitEditingActive: Bool {
        currentViewMode == .editor
            && tabCoordinator.splitURL != nil
            && tabCoordinator.splitURL == currentURL
    }

    /// What the mode-bar picker should show selected right now.
    public var modeBarSelection: ModeBarEntry {
        isSplitEditingActive ? .splitEdit : .mode(currentViewMode)
    }

    /// Apply a picker choice. Selecting a plain mode out of split-editing
    /// closes the same-file split (the user asked for ONE pane of that
    /// lens); a different-file split is left alone — it isn't ours.
    public func setModeBarSelection(_ entry: ModeBarEntry) {
        switch entry {
        case .splitEdit:
            enterSplitEditing()
        case .mode(let m):
            if isSplitEditingActive { closeSplit() }
            setCurrentViewMode(m)
        }
    }

    /// Enter markdown edit-and-preview: editor lens + rendered split of the
    /// same file. The preview tracks the live buffer (unsaved edits) via
    /// `splitPaneText`, debounced off-main by `SplitMarkdownRenderModel`.
    public func enterSplitEditing() {
        guard let url = currentURL else { return }
        setCurrentViewMode(.editor)
        openInSplit(url)
    }
}
