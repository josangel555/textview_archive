import Foundation
import ViewerCore

// Editor-mode buffer lifecycle + save (TSK-1110 SRP slice; Phase 6.x) — the
// per-tab EditorBuffer forwarders to the EditorCoordinator, plus the save path
// that also refreshes the git diff feed / repo badge / LSP didSave on success.
// Storage lives on tabCoordinator/editor; this is the DocumentModel-level glue.
// Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// Forwarder. New code should observe
    /// `tabCoordinator.editorBuffers` directly so editor-text changes
    /// don't republish DocumentModel.
    public var editorBuffers: [UUID: EditorBuffer] {
        tabCoordinator.editorBuffers
    }

    /// Source-compat re-alias for the prompt enum. Old call sites that
    /// switched on `DocumentModel.DirtyClosePrompt` keep compiling
    /// against the new EditorCoordinator type.
    public typealias DirtyClosePrompt = EditorCoordinator.DirtyClosePrompt

    /// Forwarder. New code should call `editor.hasAnyUnsavedEdits`.
    public var hasAnyUnsavedEdits: Bool {
        editor.hasAnyUnsavedEdits
    }

    /// Forwarder. New code should call `editor.editorBuffer(forTabID:)`.
    public func editorBuffer(forTabID id: UUID) -> EditorBuffer? {
        editor.editorBuffer(forTabID: id)
    }

    /// Forwarder. New code should call `editor.ensureEditorBuffer(...)`.
    public func ensureEditorBuffer(for file: TextFile, tabID: UUID) {
        editor.ensureEditorBuffer(for: file, tabID: tabID)
    }

    /// Forwarder. New code should call `editor.updateEditorText(...)`.
    public func updateEditorText(_ newText: String, forTabID id: UUID) {
        editor.updateEditorText(newText, forTabID: id)
        // Editing a preview tab commits it: a dirty buffer must not be
        // silently discarded by the next single-click reusing the slot, so
        // promote it to a permanent tab (VSCode parity — TSK-306 §2.2). No-op
        // for a non-preview tab. Cheap: `previewTabID` is one scan of the tab
        // list, only equal when there IS a preview and it's the edited tab.
        if tabs.previewTabID == id {
            tabCoordinator.promoteTab(id: id)
            // Now it's a real open, so it belongs in Open Recent — the
            // transient peek that created it was deliberately skipped.
            notePreviewPromoted(tabID: id)
        }
        // Recompute folds against the edited text (TSK-466). Only for the
        // selected tab — a background tab's editor isn't on screen.
        if tabs.selected?.id == id { refreshEditorFolds() }
    }

    /// Forwarder. New code should call `editor.saveActiveEditor()`.
    /// Also re-runs the git diff feed on success so the CM6 gutter
    /// bars + source-view diff stripe update against the new HEAD
    /// delta — without this, the bars stay frozen at "as of file open"
    /// until the next tab switch (which is what hits `updateDerived`).
    @discardableResult
    public func saveActiveEditor() -> Bool {
        let ok = editor.saveActiveEditor()
        if ok {
            refreshDiffMarks()
            // Sibling: refresh the tracked repo's badge status against
            // the new on-disk state (deterministic; doesn't wait on the
            // FSEvents debounce).
            if let url = currentURL {
                repoFocus.refreshRepo(enclosing: url)
                notifyLSPDidSave(url)
            }
        }
        return ok
    }

    /// Forwarder. New code should call `editor.saveEditor(forTabID:)`.
    /// Same refresh-on-success rationale as `saveActiveEditor` above.
    @discardableResult
    public func saveEditor(forTabID id: UUID) -> Bool {
        let ok = editor.saveEditor(forTabID: id)
        if ok {
            refreshDiffMarks()
            if let url = tabs.tabs.first(where: { $0.id == id })?.url {
                repoFocus.refreshRepo(enclosing: url)
                notifyLSPDidSave(url)
            }
            // Local History snapshot-on-save is recorded ONCE at the chokepoint
            // in EditorCoordinator.saveEditor (single hook; the store self-gates
            // toggle + secret/binary). The forwarder no longer double-snapshots.
        }
        return ok
    }

    /// Fire a `textDocument/didSave` to the LSP server after a successful
    /// editor write so on-save server behaviour (format/lint/index-on-save)
    /// triggers — `didChange` alone never does. Fire-and-forget like
    /// `ensureOpened`/`closeFile`; the pool no-ops when the file isn't open or
    /// the language has no LSP. (TSK-521.)
    private func notifyLSPDidSave(_ url: URL) {
        let pool = self.lspPool
        Task { try? await pool.didSave(fileURL: url) }
    }

    /// Forwarder. New code should call `editor.discardEditorBuffer(...)`.
    public func discardEditorBuffer(forTabID id: UUID) {
        editor.discardEditorBuffer(forTabID: id)
    }

    /// TSK-1472: the CSV grid's explicit save — write the serialized edited
    /// table through the EDITOR save chokepoint so it inherits the whole safe
    /// path for free: atomic write + re-stat, local-history snapshot, git
    /// diff-marks refresh, and the LSP didSave. The grid view calls this with
    /// `EditableCSVModel.serialize()` output; on success the file watcher
    /// reloads the tab and the grid reparses clean.
    @discardableResult
    public func saveCSVEdits(_ serialized: String, forTabID id: UUID) -> Bool {
        editor.updateEditorText(serialized, forTabID: id)
        return saveEditor(forTabID: id)
    }
}
