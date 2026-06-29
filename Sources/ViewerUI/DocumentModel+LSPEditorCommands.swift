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

    /// `editor.rename` (TSK-640 stage 2): rename the symbol at the active
    /// editor cursor via `textDocument/rename`. Apply policy, deliberate:
    ///   • the DISPATCHING buffer is snapshot-guarded exactly like
    ///     `formatActiveEditorViaLSP` — a keystroke racing the server wins;
    ///   • edits to OTHER OPEN tabs apply against their current buffer
    ///     text (cross-file rename inside the session);
    ///   • edits to files NOT open anywhere are SKIPPED, never written to
    ///     disk behind the user's back (recorded for diagnostics).
    /// Returns false when there is no selected tab/URL, no LSP language,
    /// no editor buffer, no cursor, or an empty new name.
    @discardableResult
    public func renameActiveEditorSymbolViaLSP(newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let tab = tabs.selected, let url = tab.url else { return false }
        guard lspLanguageConfigured(for: url) else { return false }
        guard let buf = editor.editorBuffers[tab.id] else { return false }
        guard let cursor = editor.editorCursorByTab[tab.id] else { return false }
        let tabID = tab.id
        let snapshot = buf.text
        #if DEBUG
        _lastRenameDispatch = (url, trimmed)
        #endif
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let workspaceEdit = try await self.lspPool.rename(
                    fileURL: url, line: cursor.line, character: cursor.column,
                    newName: trimmed)
                guard !workspaceEdit.isEmpty else { return }
                await MainActor.run {
                    self.applyWorkspaceEditToOpenTabs(
                        workspaceEdit, dispatchTabID: tabID, dispatchSnapshot: snapshot)
                }
            } catch {
                // Same silent-failure contract as format/go-to: a server
                // error degrades to "nothing happened".
            }
        }
        return true
    }

    /// Whether the active editor offers an LSP rename right now: a selected
    /// tab with an LSP-registered language, a live editor buffer, and a
    /// recorded cursor. Mirrors `renameActiveEditorSymbolViaLSP`'s guards
    /// (minus the new-name check, which is submit-time) so the command/menu can
    /// gate enablement and `showLSPRenamePrompt` can refuse on a non-rename-able
    /// context. (TSK-640.)
    public var canRenameActiveEditorSymbol: Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        guard lspLanguageConfigured(for: url) else { return false }
        guard editor.editorBuffers[tab.id] != nil else { return false }
        guard editor.editorCursorByTab[tab.id] != nil else { return false }
        return true
    }

    /// Present the rename prompt IF the active editor is rename-able (else a
    /// silent no-op — the command's enablement already greys it, this guards
    /// the script/programmatic path). The prompt's submit calls
    /// `submitLSPRename`. (TSK-640.)
    public func showLSPRenamePrompt() {
        guard canRenameActiveEditorSymbol else { return }
        lspRenamePrefill = ""
        isLSPRenamePromptPresented = true
    }

    public func dismissLSPRenamePrompt() {
        isLSPRenamePromptPresented = false
        lspRenamePrefill = ""
    }

    /// Submit the rename prompt: dispatch the (host-tested) rename and dismiss.
    /// Returns the dispatch result (false = guards refused / blank name) so the
    /// view can beep on a no-op. (TSK-640.)
    @discardableResult
    public func submitLSPRename(_ newName: String) -> Bool {
        let dispatched = renameActiveEditorSymbolViaLSP(newName: newName)
        dismissLSPRenamePrompt()
        return dispatched
    }

    /// Apply a decoded WorkspaceEdit to the open tabs (see the policy on
    /// `renameActiveEditorSymbolViaLSP`; `applyCodeAction` shares it).
    /// internal: shared with the code-action commands that stay on DocumentModel
    /// (TSK-1110 — they call this cross-file until they move too).
    func applyWorkspaceEditToOpenTabs(
        _ workspaceEdit: [String: [LSPTextEdit]],
        dispatchTabID: UUID,
        dispatchSnapshot: String
    ) {
        #if DEBUG
        _lastRenameSkippedURIs = []
        #endif
        for (uri, edits) in workspaceEdit {
            guard !edits.isEmpty,
                  let editURL = URL(string: uri), editURL.isFileURL else { continue }
            let editPath = editURL.standardizedFileURL.resolvingSymlinksInPath().path
            let target = tabs.tabs.first { t in
                guard let u = t.url else { return false }
                return u.standardizedFileURL.resolvingSymlinksInPath().path == editPath
            }
            guard let target, let buffer = editor.editorBuffers[target.id] else {
                #if DEBUG
                _lastRenameSkippedURIs.append(uri)
                #endif
                continue
            }
            if target.id == dispatchTabID {
                // Snapshot guard: the user typed while the server worked —
                // their text wins, the stale edits drop.
                guard buffer.text == dispatchSnapshot else { continue }
            }
            let updated = LSPTextEditApplier.apply(edits, to: buffer.text, encoding: .utf16)
            if updated != buffer.text {
                updateEditorText(updated, forTabID: target.id)
            }
        }
    }

    #if DEBUG
    /// Test-only door to the private apply step (the skip policy can't be
    /// reached through the fake server, whose fixture only ever edits the
    /// requested file).
    func _applyRenameWorkspaceEditForTesting(
        _ workspaceEdit: [String: [LSPTextEdit]],
        dispatchTabID: UUID,
        dispatchSnapshot: String
    ) {
        applyWorkspaceEditToOpenTabs(
            workspaceEdit, dispatchTabID: dispatchTabID, dispatchSnapshot: dispatchSnapshot)
    }
    #endif

    /// `editor.codeActions` (TSK-640): actions available at the active
    /// editor cursor (an empty range at the cursor position). Returns []
    /// on any failure — the same silent contract as the go-to verbs.
    public func codeActionsAtCursor() async -> [LSPCodeAction] {
        guard let tab = tabs.selected, let url = tab.url,
              lspLanguageConfigured(for: url),
              let cursor = editor.editorCursorByTab[tab.id] else { return [] }
        let pos = LSPPosition(line: cursor.line, character: cursor.column)
        return (try? await lspPool.codeActions(
            fileURL: url, range: LSPRange(start: pos, end: pos))) ?? []
    }

    /// Apply a picked code action's WorkspaceEdit — same policy as rename
    /// (open tabs only; unopened files are never written). Command-only
    /// actions (empty `edit`) are refused: this viewer applies edits, it
    /// never executes server commands.
    @discardableResult
    public func applyCodeAction(_ action: LSPCodeAction) -> Bool {
        guard !action.edit.isEmpty else { return false }
        guard let tab = tabs.selected else { return false }
        let snapshot = editor.editorBuffers[tab.id]?.text ?? ""
        applyWorkspaceEditToOpenTabs(
            action.edit, dispatchTabID: tab.id, dispatchSnapshot: snapshot)
        return true
    }

    /// Whether the active editor can offer code actions now (an LSP language +
    /// a recorded cursor). Gates the command/menu + showCodeActionPicker. (TSK-640.)
    public var canRequestCodeActions: Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        guard lspLanguageConfigured(for: url) else { return false }
        return editor.editorCursorByTab[tab.id] != nil
    }

    /// Open the code-action picker: present a spinner, fetch actions at the
    /// cursor off-main, then list them (or auto-dismiss if none). No-op on a
    /// non-LSP context (the command's enablement greys it; this guards the
    /// script/programmatic path). (TSK-640.)
    public func showCodeActionPicker() {
        guard canRequestCodeActions else { return }
        codeActionPickerGeneration += 1
        let generation = codeActionPickerGeneration
        codeActionPicker = .loading
        Task { [weak self] in
            guard let self else { return }
            let actions = await self.codeActionsAtCursor()
            // Drop a late fetch the user already dismissed / superseded.
            guard self.codeActionPickerGeneration == generation,
                  self.codeActionPicker == .loading else { return }
            self.codeActionPicker = actions.isEmpty ? .hidden : .presenting(actions)
        }
    }

    public func dismissCodeActionPicker() {
        codeActionPickerGeneration += 1
        codeActionPicker = .hidden
    }

    /// Apply a picked action and dismiss. Returns applyCodeAction's result
    /// (false = command-only / refused) so the view can beep on a no-op. (TSK-640.)
    @discardableResult
    public func pickCodeAction(_ action: LSPCodeAction) -> Bool {
        let applied = applyCodeAction(action)
        dismissCodeActionPicker()
        return applied
    }

    #if DEBUG
    /// Harness-only (TSK-492/640 VM render lane): present the code-action picker
    /// DIRECTLY with canned actions, bypassing the async LSP fetch, so a
    /// `MDV_UI_SCENE` can put the picker on screen deterministically for a
    /// real-pixel capture (the spawned app has no live LSP server). NOT a
    /// product path — the real flow is `showCodeActionPicker()`. Mirrors the
    /// `_applyRenameWorkspaceEditForTesting` DEBUG seam.
    func _presentCodeActionsForHarness(_ actions: [LSPCodeAction]) {
        codeActionPicker = .presenting(actions)
    }
    #endif
}
