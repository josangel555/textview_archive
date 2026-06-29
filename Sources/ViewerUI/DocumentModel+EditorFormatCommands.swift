import Foundation
import ViewerCore

// In-editor format commands (TSK-1110 SRP slice; TSK-350) — local (non-LSP)
// formatting of the ACTIVE editor buffer. Markdown has no format VIEW lens (its
// lenses are Rendered/Source), so GFM pipe-table alignment is a direct editor
// command rather than the `.formatted` toggle. Behavior-preserving move out of
// DocumentModel.swift.
extension DocumentModel {

    /// TSK-350 — align GFM pipe tables in the active editor buffer, in place.
    /// Markdown deliberately has no format VIEW lens (its lenses are
    /// Rendered/Source — FormatToggleTests), so table alignment is a direct
    /// editor command rather than the `.formatted` toggle. No-op unless the
    /// selected tab is a markdown file with an editor buffer AND the alignment
    /// changes something. Returns whether it rewrote the buffer.
    @discardableResult
    public func formatMarkdownTablesInActiveEditor() -> Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        let ext = url.pathExtension.lowercased()
        guard ["md", "markdown", "mdown", "mkd"].contains(ext) else { return false }
        guard let buf = editor.editorBuffers[tab.id] else { return false }
        let formatted = Formatter.prettyPrint(buf.text, as: .markdown)
        guard formatted != buf.text else { return false }
        updateEditorText(formatted, forTabID: tab.id)
        return true
    }

    /// Whether `formatMarkdownTablesInActiveEditor` would act — drives the
    /// Edit-menu item's enablement. True only for a markdown tab with a live
    /// editor buffer.
    public var canAlignMarkdownTables: Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        guard ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
        else { return false }
        return editor.editorBuffers[tab.id] != nil
    }
}
