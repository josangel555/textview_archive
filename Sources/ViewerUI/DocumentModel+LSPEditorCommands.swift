import Foundation
import ViewerCore

// LSP editor commands (TSK-1110 SRP slice; TSK-950/627) — server-driven commands on
// the ACTIVE editor: "Find References" (multi-result → populates the shared
// lspNavigation store) and whole-document Format (snapshot-guarded: a keystroke that
// races the formatter wins, the stale response is dropped). Both honest no-ops
// without a selected tab / cursor / LSP language. The `_lastReferencesRequest` /
// `_lastFormatDispatch` DEBUG probes + the lspLanguageConfigured/lspPosition seams
// (+LSPShared) stay on DocumentModel. Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// Command/verb entry: run LSP "Find References" at the ACTIVE editor cursor
    /// and populate the navigation panel (TSK-950). Returns false (no-op) when
    /// there's no selected tab with a URL, no recorded editor cursor, or no
    /// language server for the file — same honest no-op contract as
    /// `navigateViaLSPAtCursor`. References is a multi-result flow, so it routes
    /// into `lspNavigation` (the SAME store the source-view hover menu's "Find
    /// References" populates), never a go-to-first jump.
    @discardableResult
    public func findReferencesAtCursor() -> Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        guard let cursor = editor.editorCursorByTab[tab.id] else { return false }
        guard lspLanguageConfigured(for: url) else { return false }
        let (lspLine, lspChar) = lspPosition(line: cursor.line, character: cursor.column)
        #if DEBUG
        _lastReferencesRequest = (url, lspLine, lspChar)
        #endif
        let originLabel = "References at \(url.lastPathComponent):\(cursor.line)"
        let pool = lspPool
        let store = lspNavigation
        Task {
            do {
                let locs = try await pool.references(
                    fileURL: url, line: lspLine, character: lspChar,
                    includeDeclaration: true)
                await MainActor.run {
                    store.setReferences(originLabel: originLabel, locations: locs)
                }
            } catch {
                // Silent — same contract as navigateViaLSP (no "LSP returned
                // nothing" surface; users notice by the panel staying empty).
            }
        }
        return true
    }

    /// True when "Find References" can act — there's an editable tab with a
    /// recorded cursor in a language the LSP pool serves. Gates the menu item.
    public var canFindReferences: Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        guard editor.editorCursorByTab[tab.id] != nil else { return false }
        return lspLanguageConfigured(for: url)
    }

    /// `editor.format` (TSK-627): whole-document format of the ACTIVE
    /// editor buffer via `textDocument/formatting`. Snapshot-guarded:
    /// the edits are resolved against the buffer text captured at
    /// dispatch, and applied only if the buffer is still unchanged when
    /// the response lands — a keystroke that raced the formatter wins,
    /// the stale response is dropped. Returns false when there is no
    /// selected tab with a URL, no editor buffer, or no LSP language.
    @discardableResult
    public func formatActiveEditorViaLSP() -> Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        guard lspLanguageConfigured(for: url) else { return false }
        guard let buf = editor.editorBuffers[tab.id] else { return false }
        let tabID = tab.id
        let snapshot = buf.text
        #if DEBUG
        _lastFormatDispatch = (url, snapshot)
        #endif
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let edits = try await self.lspPool.formatting(fileURL: url)
                guard !edits.isEmpty else { return }
                // CM6 documents are UTF-16; the negotiated LSP encoding is
                // utf-16 everywhere this app touches (same as the
                // diagnostics path in EditorCoordinator).
                let formatted = LSPTextEditApplier.apply(
                    edits, to: snapshot, encoding: .utf16)
                guard formatted != snapshot else { return }
                await MainActor.run {
                    // Snapshot guard: drop the result if the user typed
                    // while the formatter ran.
                    guard self.editor.editorBuffers[tabID]?.text == snapshot else { return }
                    self.updateEditorText(formatted, forTabID: tabID)
                }
            } catch {
                // Same silent-failure contract as the go-to verbs: no
                // formatter / server error degrades to "nothing happened".
            }
        }
        return true
    }
}
