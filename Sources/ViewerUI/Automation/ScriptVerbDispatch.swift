import Foundation
import ViewerCore
import ViewerKit

/// Keystone of the testing-pyramid migration (§3.1).
///
/// The `--script PATH` verb dispatcher used to live *inside*
/// `AppDelegate.runScriptStep` — a giant `switch` whose cases were plain
/// method calls coupled to `AppDelegate`'s `model` / `sessions` / `window`.
/// That coupling forced every script-driven UI test to spawn the real
/// `.app` (an L4 process round-trip) just to reach `@MainActor` model
/// state that is, today, cleanly constructable in-process.
///
/// This free function lifts the *model + sessions* portion of that switch
/// out of `AppDelegate` so it can be driven against ANY hermetic
/// `DocumentModel` / `SessionsAppCoordinator` pair — no `NSApplication`,
/// no window, no process spawn. Two callers:
///
///   1. `AppDelegate.runScriptStep` (the VM `--script` path) — delegates
///      here for the model/sessions verbs, then handles the residual
///      window / `NSApp` / AppDelegate-only verbs (`resize`, `find`,
///      `diagnostic-window`, …) itself. Production behaviour is unchanged.
///   2. `HeadlessHarness` (Tests/ViewerUITests/Harness) — drives the same
///      verbs in-process against a throwaway `DocumentModel`, then emits
///      the SAME dump dict in-memory via `modelStateDump(...)`, feeding the
///      existing Page Objects unchanged.
///
/// ## Why `Bool`-returning, not exhaustive
///
/// A handful of verbs are irreducibly tied to a real window or the
/// `NSApp` responder chain (`resize` needs `NSWindow.setFrame`, `find`
/// needs `NSApp.sendAction`, the tool-window verbs call AppDelegate
/// methods). Those can't run against a bare `(model, sessions)` pair, so
/// they are NOT handled here. `apply` returns `true` when it recognised
/// and applied the verb, `false` when the verb is one of the residual
/// window/AppDelegate-coupled ones — letting the AppDelegate caller fall
/// through to its own handling. The headless harness simply ignores a
/// `false` return (those verbs are out of scope for an in-process model).
///
/// This split is deliberate: every verb a migrated headless suite needs
/// (tabs, zoom, view mode, palette, goto, editor, bookmark, find-bar,
/// sidebar, sessions, open-as, file-history, observability) is handled
/// here; only the genuine ④/cross-process residue is left to the caller.
@MainActor
public enum ScriptVerb {

    /// Maps a `convert-encoding <id>` palette/script arg to a text encoding
    /// (TSK-1335). Internal so the registry test can assert the descriptor verb
    /// args round-trip. Mirrors AppDelegate.encodingChoices (the menu source).
    /// A dictionary (NOT a switch) on purpose: the ScriptVerbCatalog test scans
    /// this file for `case "<token>":` labels to extract verbs, so a switch here
    /// would mis-register the encoding ids as bogus verbs.
    static let convertEncodingMap: [String: String.Encoding] = [
        "utf-8": .utf8,
        "utf-16": .utf16,
        "windows-1252": .windowsCP1252,
        "iso-latin-1": .isoLatin1,
    ]
    static func encodingForConvertID(_ id: String) -> String.Encoding? {
        convertEncodingMap[id]
    }

    /// Apply one script verb line (`"<cmd> <arg>"`) to `model` / `sessions`.
    ///
    /// - Returns: `true` if the verb was recognised and applied here;
    ///   `false` if it is a window / `NSApp` / AppDelegate-coupled verb
    ///   the caller must handle (or, for the headless harness, skip).
    /// Canvas verb plumbing (M2.S6): resolve "<doc>" as an open id first,
    /// else as a .canvas path opened through the store.
    private static func canvasDoc(
        _ ref: String, _ store: CanvasDocumentStore
    ) throws -> CanvasOpenDocument {
        if let open = try? store.doc(ref) { return open }
        return try store.open(url: URL(fileURLWithPath: (ref as NSString).expandingTildeInPath))
    }

    /// Run a canvas verb body, logging faults (verbs have no return channel).
    private static func canvasVerb(
        _ model: DocumentModel, _ body: (CanvasDocumentStore) throws -> Void
    ) {
        do {
            try body(model.automationCanvasStore)
        } catch {
            NSLog("canvas verb failed: %@", String(describing: error))
        }
    }

    @discardableResult
    public static func apply(
        verb line: String,
        to model: DocumentModel,
        sessions: SessionsAppCoordinator
    ) -> Bool {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first else { return true }
        let arg = parts.count > 1 ? parts[1] : ""
        // TSK-1162: capture the invocation into an in-flight macro recording.
        // recordVerb gates internally (no-op when not recording / replaying / the
        // verb maps to no replayable command); the macro-control verbs are
        // excluded so a recording never captures its own start/stop/replay.
        if !cmd.hasPrefix("macro-") { model.macros.recordVerb(cmd) }
        switch cmd {
        // Canvas (M2.S6, TSK-1371): one-line script access to the canvas
        // engine. Doc references accept an open doc id or a .canvas path
        // (auto-opened). Failures log-and-return-true (the verb WAS
        // recognised; scripts read the log like every other verb fault).
        case "canvas-export":
            let fields = arg.split(separator: " ").map(String.init)
            guard fields.count == 2 else {
                NSLog("canvas-export needs \"<doc> <outPath>\"")
                return true
            }
            canvasVerb(model) { store in
                let doc = try canvasDoc(fields[0], store)
                let html = try doc.adapter.html()
                try EditorWriter.save(html, to: URL(fileURLWithPath: fields[1]))
            }
        case "canvas-apply-file":
            let fields = arg.split(separator: " ").map(String.init)
            guard fields.count == 3, let baseRev = UInt64(fields[1]) else {
                NSLog("canvas-apply-file needs \"<doc> <baseRev> <dslPath>\"")
                return true
            }
            canvasVerb(model) { store in
                let doc = try canvasDoc(fields[0], store)
                let dsl = try String(contentsOf: URL(fileURLWithPath: fields[2]), encoding: .utf8)
                _ = try doc.adapter.applyDSL(baseRev: baseRev, dsl)
            }
        case "toggle-view":    model.toggleViewMode()
        case "toggle-sidebar": model.sidebar.toggleVisibility()
        case "zoom-in":        model.zoomIn()
        case "zoom-out":       model.zoomOut()
        case "zoom-reset":     model.zoomReset()
        case "copy-reference":
            // TSK-1256/942: copy an mdv:// reference to the current editor SELECTION
            // (a line range for a multi-line span, else the current line) to the
            // clipboard.
            if let ref = model.currentSelectionReference() { Pasteboard.copy(ref) }
        case "goto-line":
            // Script-bus nav primitive: scroll the active editor/source to a
            // 1-based line. Invalid (≤0 / non-numeric) args are a recognized no-op.
            if let n = Int(arg), n >= 1 { model.sourceView.scrollSource(toLine: n) }
        case "convert-encoding":
            // TSK-1335: palette parity for Edit ▸ Convert Encoding — re-save the
            // active file in the chosen encoding (reuses the existing host method,
            // DocumentModel.convertActiveFileEncoding via EditorWriter w/ lossy guard).
            // Unknown arg is a recognized no-op.
            if let enc = Self.encodingForConvertID(arg) {
                _ = model.convertActiveFileEncoding(to: enc)
            }
        case "align-tables":
            // TSK-1335: palette parity for Edit ▸ Align Markdown Tables — re-align
            // GFM pipe tables in the active markdown editor (reuses the host method).
            _ = model.formatMarkdownTablesInActiveEditor()
        case "open":           model.openPath(URL(fileURLWithPath: arg))
        case "open-lazy":
            // Append a file as a LAZY (`.empty`) tab without selecting it —
            // the exact shape workspace-restore / multi-file-drop produce.
            // The tab materializes on the next `select-tab`, driving the
            // `materializeIfNeeded` async path (LOADBUG bug 1's repro).
            model.appendLazyTab(
                url: URL(fileURLWithPath: arg),
                viewMode: ViewModeOptions.defaultMode(
                    for: URL(fileURLWithPath: arg)))
        case "confirm-dirty-close":
            // Pre-arm the dirty-close NSAlert with a scripted choice so a
            // following `close-tab` (or close-others/-to-right) on a dirty
            // tab is automatable headlessly instead of blocking the main
            // thread on `NSAlert.runModal()` forever. Routes through the
            // existing `dirtyClosePromptOverride` test seam. One-shot: the
            // override clears itself the first time it fires, so it maps to
            // a single user click and doesn't leak into a later close.
            let choice: EditorCoordinator.DirtyClosePrompt?
            switch arg {
            case "save":    choice = .save
            case "discard": choice = .discard
            case "cancel":  choice = .cancel
            default:        choice = nil
            }
            if let choice {
                let editor = model.editor
                editor.dirtyClosePromptOverride = { [weak editor] _ in
                    editor?.dirtyClosePromptOverride = nil
                    return choice
                }
            }
        case "close-tab":      model.closeCurrentTab()
        case "new-tab":        model.newTab()
        case "next-tab":       model.selectNextTab()
        case "prev-tab":       model.selectPreviousTab()
        case "select-tab":
            if let n = Int(arg), n >= 1 { model.selectTab(at: n - 1) }
        // Move the selected tab within the bar (Omni-invokability: tabs.moveLeft
        // / tabs.moveRight previously had no script verb — menu/⌘⌥[ ⌘⌥]-only).
        case "move-tab-left":   model.moveCurrentTabLeft()
        case "move-tab-right":  model.moveCurrentTabRight()
        case "terminal-open-here": model.openTerminalHere()
        case "show-palette":    model.showPalette()
        case "show-dependency-graph": model.showDependencyGraph()
        case "show-folder-treemap": model.showFolderTreemap()
        case "show-http-client": _ = model.openHTTPClient()
        case "show-feed-reader": _ = model.openFeedReader()
        case "new-image":       model.newBlankImageForLanding()
        case "show-walkthroughs": model.showWalkthroughsBrowser()
        case "dismiss-palette": model.dismissPalette()
        case "show-goto":       model.showGoToPath()
        case "dismiss-goto":    model.dismissGoToPath()
        case "goto-commit":     model.commitGoToPath(arg, newSession: false)
        case "goto-commit-new-session": model.commitGoToPath(arg, newSession: true)
        case "toggle-format":   model.toggleFormat()
        // TSK-951: palette parity for the two nil-verb view toggles — pure
        // model toggles, headless-safe.
        case "toggle-word-wrap": model.toggleSourceWordWrap()
        case "toggle-invisibles": model.toggleShowInvisibleChars()
        case "toggle-view-only": model.toggleViewOnly()   // TSK-936
        // TSK-951: menu-only active-file Edit text-transforms surfaced to the
        // palette. Each wires to an existing host-tested model method (no-op,
        // returns false, when there's no active text file / editor caret).
        case "edit-remove-empty-lines":    _ = model.removeEmptyActiveFileLines()
        case "edit-collapse-blank-lines":  _ = model.collapseBlankActiveFileLines()
        case "edit-trim-trailing":         _ = model.trimTrailingWhitespaceInActiveFile()
        case "edit-ensure-final-newline":  _ = model.ensureFinalNewlineInActiveFile()
        case "edit-minify-json":           _ = model.minifyActiveJSON()
        case "edit-insert-toc":            _ = model.insertTableOfContents()
        case "edit-insert-date":           model.insertDateAndTime()
        // TSK-1113: TextEdit-parity case transforms (engine TSK-351).
        case "edit-uppercase":             _ = model.makeActiveFileUpperCase()
        case "edit-lowercase":             _ = model.makeActiveFileLowerCase()
        case "edit-capitalize":            _ = model.capitalizeActiveFile()
        // TSK-1186: heading promote/demote (MarkdownHeadingShift) — menu-only until now.
        case "edit-promote-heading":       _ = model.shiftActiveMarkdownHeadings(by: -1)
        case "edit-demote-heading":        _ = model.shiftActiveMarkdownHeadings(by: 1)
        // TSK-1186: line ops (sort/reverse/dedup) — menu-only model methods until now.
        case "edit-sort-lines":            _ = model.sortActiveFileLines(ascending: true)
        case "edit-sort-lines-desc":       _ = model.sortActiveFileLines(ascending: false)
        case "edit-reverse-lines":         _ = model.reverseActiveFileLines()
        case "edit-remove-duplicate-lines": _ = model.removeDuplicateActiveFileLines()
        // TSK-1186: line-ending converters (per-target, param-less) — file-write.
        case "convert-line-endings-lf":    _ = model.convertActiveFileLineEnding(to: .lf)
        case "convert-line-endings-crlf":  _ = model.convertActiveFileLineEnding(to: .crlf)
        case "convert-line-endings-cr":    _ = model.convertActiveFileLineEnding(to: .cr)
        // TSK-1186: indentation converters (per-target, param-less) — file-write.
        case "convert-indentation-to-spaces": _ = model.convertActiveFileIndentation(toSpaces: true)
        case "convert-indentation-to-tabs":   _ = model.convertActiveFileIndentation(toSpaces: false)
        // TSK-1162: macro record/replay control verbs (excluded from capture).
        case "macro-record-start": model.macros.startRecording()
        case "macro-record-stop":  model.macros.finishRecording()
        case "macro-replay-last":
            var dispatcher = LiveMacroDispatcher(model: model, sessions: sessions)
            model.macros.replayLast(on: &dispatcher)
        // Split view (Omni-invokability: view.toggleSplit / view.swapSplit
        // previously had no script verb, so they were menu/⌘\-only). Both wire
        // to existing @MainActor model methods — headless-safe, no window.
        case "toggle-split":    model.toggleSplit()
        case "close-split":     model.closeSplit()
        case "swap-split":      model.swapSplit()
        // TSK-326 (omni-search coverage): Fold All / Unfold All previously had
        // no script verb (menu/⌥⌘[ ⌥⌘]-only), so they greyed out in the `>`
        // palette. Both route through the SAME host-tested model methods the
        // View-menu items call (`cmFoldAll`/`cmUnfoldAll`); each is a no-op
        // (returns false) outside a foldable lens, exactly like the menu's
        // `validateMenuItem` gate. The collapse RENDERING is the VM tail; the
        // published `lastFoldDispatch` intent is host-tested.
        case "fold-all":        _ = model.foldAllActiveDocument()
        case "unfold-all":      _ = model.unfoldAllActiveDocument()
        // ---- Editor (CM6) — VM-only flow verbs (Phase 6.x) ----
        // These drive the Swift-side editor state machine that backs
        // the CodeMirror WebView. Used by EditorMultiScenarioTests to
        // simulate keystrokes without needing to drive JS directly.
        case "editor-set-mode":
            // Force the active tab into a specific view mode.
            // Accepts the raw `ViewMode.rawValue` ("source","editor","rendered","hex","table").
            if let mode = ViewMode(rawValue: arg) {
                model.setCurrentViewMode(mode)
            }
        case "editor-focus":
            // TSK-1020: hand keyboard first-responder to the ACTIVE document
            // surface for the current view mode — for an `.editor` tab that
            // bumps `editorFocusRequest`, which the CM6 representable consumes
            // (`webView.window?.makeFirstResponder(webView)` + JS `.focus()`),
            // so a following `ui-type` posts real keydowns into the CM6 field
            // rather than into nothing. Reuses the host-tested, mode-aware
            // `returnFocusToActiveDocument` (the SAME nonce TSK-905/906/938
            // drive) — `editor-set-mode editor` alone only sets the view mode,
            // it does NOT focus the editor (the KEY_01 root cause). No-op when
            // there's no active document or the mode owns its first-responder
            // by other means (source/hex/table/diff NSTextView surfaces).
            _ = model.returnFocusToActiveDocument(currentFocusIsDocument: false)
        case "editor-set-text":
            // Push text into the active tab's editor buffer — same
            // entry point the CM6 JS bridge would fire on every
            // debounced change event.
            if let id = model.tabs.selected?.id {
                // Materialize the buffer first so a freshly-loaded
                // tab can be edited from script.
                _ = model.editorBuffer(forTabID: id)
                model.updateEditorText(arg, forTabID: id)
            }
        case "editor-save":
            // ⌘S equivalent: write the active tab's buffer to disk.
            _ = model.saveActiveEditor()
        // ---- LSP go-to commands (TSK-464) ----
        // Deliberate-command form of the editor's Cmd-click navigation:
        // resolve the verb at the ACTIVE editor cursor and jump to the
        // first result. No-ops (returns quietly) when there's no cursor
        // or the file's language has no LSP.
        case "editor-goto-definition":
            _ = model.navigateViaLSPAtCursor(kind: .definition)
        case "editor-goto-declaration":
            _ = model.navigateViaLSPAtCursor(kind: .declaration)
        case "editor-goto-type-definition":
            _ = model.navigateViaLSPAtCursor(kind: .typeDefinition)
        case "editor-goto-implementation":
            _ = model.navigateViaLSPAtCursor(kind: .implementation)
        case "editor-find-references":
            // TSK-950: list references at the active editor cursor in the LSP
            // navigation panel. Silent no-op without a cursor / language server.
            _ = model.findReferencesAtCursor()
        case "editor-format":
            // Whole-document LSP format of the active editor buffer
            // (TSK-627). Snapshot-guarded; silent no-op without a
            // formatter, like the go-to verbs.
            _ = model.formatActiveEditorViaLSP()
        case "lsp-rename":
            // LSP rename of the symbol at the active editor cursor (TSK-640).
            // `arg` is the new name. The headless/automation entry (the engine —
            // request → decode → snapshot-guarded reverse apply across open tabs
            // — is fully host-tested); the Edit-menu item + rename prompt sheet
            // that supply the name interactively are the live follow-up. Silent
            // no-op without an LSP server / cursor, like editor-format.
            _ = model.renameActiveEditorSymbolViaLSP(newName: arg)
        case "show-lsp-rename":
            // Open the interactive "Rename Symbol…" prompt (TSK-640) — the
            // command/menu entry. No-op on a non-rename-able context (the
            // command's enablement greys it; showLSPRenamePrompt guards too).
            // The prompt's submit calls renameActiveEditorSymbolViaLSP.
            model.showLSPRenamePrompt()
        case "show-code-actions":
            // Open the LSP "Code Actions…" picker at the active editor cursor
            // (TSK-640) — the command/menu entry. Fetches off-main + lists;
            // picking applies the edit-bearing action (command-only refused).
            model.showCodeActionPicker()
        case "toggle-blame":
            // TSK-814: toggle the editor blame gutter (per-line author/time/
            // summary). Routes through refreshDiffMarks → blame-or-diff per the
            // editorBlameActive flag, so toggling off restores the diff bars.
            model.toggleEditorBlame()
        case "set-theme":
            // Headless theming seam (TSK-641): select a theme by id — the
            // automation/UAT equivalent of the Settings → Appearance picker.
            // Empty arg = Follow System (nil selection). An unknown id falls
            // back per ThemeStore. This is the entry a VM T5 chrome-pixel test
            // drives to validate the chrome surface (the one un-host-testable
            // theming surface); the picker UI is the user-facing equivalent.
            model.selectedThemeID = arg.isEmpty ? nil : arg
        case "save-copy":
            // Write a COPY of the active tab's current content to `arg` (an
            // absolute path), leaving the open tab untouched (TSK-300). This
            // is the headless/automation entry; the menu + NSSavePanel that
            // pick the path are a thin live follow-up. Errors go to Obs (the
            // harness has no window for an alert).
            do {
                _ = try model.saveCopyOfCurrentTab(to: URL(fileURLWithPath: arg))
                Obs.shared.emit(ObsEvent(
                    level: .info, subsystem: "save",
                    message: "save-copy: wrote copy to \(arg)"))
            } catch {
                Obs.shared.emit(ObsEvent(
                    level: .error, subsystem: "save",
                    message: "save-copy failed: \(error)",
                    fields: ["target": arg, "error": "\(error)"]))
            }
        case "reload":
            // Re-read the active tab's file from disk (the ⌘R / File ▸ Reload
            // action). Same entry point the menu uses; exposing it here makes
            // Reload Omni-invokable + automatable + headless-testable. A dirty
            // editor buffer is preserved (applyReload only rebases a CLEAN
            // buffer), so this never silently clobbers unsaved edits.
            model.reloadCurrentFile()
        // TSK-326: "Clear Recent Files" previously had no verb (File-menu
        // only). Routes through the SAME model method the menu's `clearRecents`
        // action calls — clears the recents/history store. Pure model state,
        // headless-safe, idempotent (clearing an empty list is a no-op).
        case "clear-recents":   model.clearRecents()
        case "toggle-bookmark": model.toggleCurrentTabBookmark()
        // Omni-invokability (git.showPanel / view.toggleLineBookmark previously
        // had no script verb). Both wire to existing @MainActor model methods.
        case "show-git-panel":  model.showGitPanel()
        // TSK-326: "Show Repository History" previously had no verb (View-menu
        // only). Same call the menu's `showRepoHistory` makes — opens the Git
        // panel on the Log tab. Pure @MainActor state, headless-safe.
        case "show-repo-history": model.showGitPanel(tab: .log)
        // Focus shortcuts (TSK-937): move keyboard focus to a specific
        // surface. Each opens/shows its target if needed then bumps the
        // surface's focus-request nonce.
        case "focus-terminal":  model.focusTerminal()
        case "focus-file-nav":  model.focusFileNav()
        case "focus-git":       model.focusGitPanel()
        case "focus-document":  model.focusActiveDocument()
        case "toggle-line-bookmark": model.toggleCurrentLineBookmark()
        case "git-file-history":
            // Omni-invokable "Show File History" for the CURRENT file (the
            // palette can't supply a path; the existing `file-history <path>`
            // verb stays for explicit-path automation). No-op off-repo /
            // untracked, exactly like the menu action.
            if let u = model.currentURL { model.openFileHistory(for: u) }
        case "metadata-compute-checksum":
            // TSK-505: invoke the EXACT action the MetadataPanel
            // "Compute SHA-256" button is wired to (in-process SwiftUI event
            // synthesis is impossible — LESSONS; same fallback as the
            // session-strip verbs). Needs a mounted panel: a preview-category
            // file open with the Info toggle on.
            guard let checksums = MetadataChecksumModel.live else {
                FileHandle.standardError.write(Data(
                    "script: metadata-compute-checksum needs a mounted MetadataPanel\n".utf8))
                return true
            }
            checksums.compute()
        case "metadata-set-checksum-algorithm":
            // TSK-748: drive the panel's algorithm picker (the exact `select`
            // the SwiftUI Picker is bound to). Same mounted-panel requirement
            // and in-process-event-synthesis fallback as the compute verb.
            guard let checksums = MetadataChecksumModel.live else {
                FileHandle.standardError.write(Data(
                    "script: metadata-set-checksum-algorithm needs a mounted MetadataPanel\n".utf8))
                return true
            }
            guard let algo = ChecksumAlgorithm(rawValue: arg) else {
                FileHandle.standardError.write(Data(
                    "script: metadata-set-checksum-algorithm unknown algorithm '\(arg)'\n".utf8))
                return true
            }
            checksums.select(algorithm: algo)
        case "show-cross-search":    model.showCrossSearch()
        case "dismiss-cross-search": model.dismissCrossSearch()
        case "set-cross-query":
            // Catalog contract (PMA-04 step 8): "implies show+run" — present
            // the panel before populating + running, so a script that omits an
            // explicit `show-cross-search` still surfaces the overlay rather
            // than running the grep behind a closed panel.
            model.showCrossSearch()
            model.crossSearchQuery = arg
            model.runCrossSearch()
        case "show-find":       model.showRenderedFindBar()
        case "dismiss-find":    model.dismissRenderedFindBar()
        case "find-next":       model.renderedFindNext()
        case "find-prev":       model.renderedFindPrev()
        // ---- LSP store seeding (headless-gatable UAT, LSP-02/03) ----
        // A real language server needs a GUI/VM lane to drive; these verbs
        // push deterministic data straight into the @MainActor LSP stores
        // via the SAME public mutation methods the server-push / context-
        // menu paths use, so the Problems + References surfaces become
        // regression-gatable on the host without spawning anything.
        case "lsp-seed-diagnostics":
            // "<errors> <warnings> [info] [hints]" — seed N diagnostics of
            // each severity, all on a synthetic file URL, so the dump's
            // per-severity counts can be asserted. Each count maps to one
            // file URL so `files` reflects how many distinct files carry
            // problems (one synthetic file per severity bucket present).
            let counts = arg.split(separator: " ").map { Int($0) ?? 0 }
            let errs = counts.count > 0 ? counts[0] : 0
            let warns = counts.count > 1 ? counts[1] : 0
            let infos = counts.count > 2 ? counts[2] : 0
            let hints = counts.count > 3 ? counts[3] : 0
            let seedSpecs: [(LSPDiagnostic.Severity, Int)] = [
                (.error, errs), (.warning, warns),
                (.information, infos), (.hint, hints),
            ]
            for (severity, n) in seedSpecs where n > 0 {
                let url = URL(fileURLWithPath: "/tmp/mdv-lsp-seed-\(severity.rawValue).swift")
                let diags = (0..<n).map { i in
                    LSPDiagnostic(
                        range: LSPRange(
                            start: LSPPosition(line: i, character: 0),
                            end: LSPPosition(line: i, character: 1)),
                        severity: severity, code: nil, source: "seed",
                        message: "seeded \(severity) \(i)")
                }
                model.lspDiagnostics.replace(url: url, with: diags)
            }
        case "lsp-clear-diagnostics":
            model.lspDiagnostics.clearAll()
        case "lsp-seed-references":
            // "<count>" — seed a references result set with N synthetic
            // rows so the nav panel's row count + references-mode can be
            // asserted headless (the right-click "Find References" path).
            let n = max(0, Int(arg) ?? 0)
            let locations = (0..<n).map { i in
                LSPLocation(
                    uri: "file:///tmp/mdv-lsp-ref-\(i).swift",
                    range: LSPRange(
                        start: LSPPosition(line: i, character: 0),
                        end: LSPPosition(line: i, character: 4)))
            }
            model.lspNavigation.setReferences(
                originLabel: "References to seed", locations: locations)
        case "lsp-clear-navigation":
            model.lspNavigation.clear()
        case "sidebar-set-root":
            model.sidebar.setRoot(URL(fileURLWithPath: arg))
        case "sidebar-select-next":
            model.sidebar.selectNext()
        case "sidebar-select-prev":
            model.sidebar.selectPrevious()
        case "sidebar-walk-up":
            model.sidebar.collapseOrFocusParent()
        // ---- Sessions (Phase 1; see SessionTabBar a11y ids) ----
        // The script runner can't reach the SessionTabBar's SwiftUI
        // buttons; these verbs drive the same SessionsAppCoordinator
        // calls the buttons would. VM UI tests assert on the resulting
        // `model.sessions` snapshot in the dump.
        case "session-open-folder":
            sessions.openFolder(URL(fileURLWithPath: arg))
        case "session-open-new":
            // forceNew variant — invoked by the tree/bookmarks
            // "Open in New Session" context-menu items. Same wiring
            // as the AppDelegate's `openFolderInNewSession(_:)` action.
            sessions.openFolder(URL(fileURLWithPath: arg), forceNew: true)
        case "session-activate":
            // 1-based index, matching `select-tab` convention.
            if let n = Int(arg), n >= 1 {
                sessions.activate(index: n - 1)
            }
        case "session-close-active":
            sessions.closeActive()
        case "session-open-home":
            // TSK-313: the strip double-click action — new session at ~.
            sessions.openHomeSession()
        // TSK-522/523: the Git Log row/toolbar EXACT action closures
        // (GitLogDiffActions — the same functions GitLogTab's buttons
        // call). The panel model is a view-local @StateObject, resolved
        // through GitPanelModel.live; `show-git-panel` (plus a settle)
        // must have mounted it first or these are loud no-ops.
        case "git-panel-root":
            // The header repo-picker's EXACT closure (`pickRepoRoot`).
            // Focus-follow doesn't bind in a headless harness launch
            // (proven by the it13 trace: "NO repoRoot"), so scenarios pin
            // the root explicitly — by default the opened sidebar root,
            // which the script can't name (the launcher rewrites paths
            // for the cross-user hand-off).
            guard let panel = GitPanelModel.live else {
                FileHandle.standardError.write(Data(
                    "script: git-panel-root needs a mounted git panel\n".utf8))
                return true
            }
            let rootURL = arg.isEmpty
                ? model.sidebar.rootURL
                : URL(fileURLWithPath: arg)
            if let rootURL {
                panel.pickRepoRoot(rootURL)
            } else {
                FileHandle.standardError.write(Data(
                    "script: git-panel-root — no sidebar root to pin\n".utf8))
            }
        case "git-panel-tab":
            // The panel's tab-switch closure (same `selectTab` the segmented
            // control calls) — needed before the log verbs: the panel
            // defaults to Status and `refreshCurrent` loads only the
            // VISIBLE tab, so `logEntries` stays empty until Log shows.
            guard let panel = GitPanelModel.live,
                  let tab = GitPanelModel.Tab(rawValue: arg) else {
                FileHandle.standardError.write(Data(
                    "script: git-panel-tab needs a mounted panel and a tab name\n".utf8))
                return true
            }
            panel.selectTab(tab)
        case "git-log-click", "git-log-cmd-click", "git-log-shift-click":
            guard let panel = GitPanelModel.live, !arg.isEmpty else {
                FileHandle.standardError.write(Data(
                    "script: \(cmd) needs a mounted git panel and a SHA arg\n".utf8))
                return true
            }
            GitLogDiffActions.rowClicked(
                sha: arg,
                command: cmd == "git-log-cmd-click",
                shift: cmd == "git-log-shift-click",
                panel: panel, doc: model)
        case "git-log-cumulative-diff":
            guard let panel = GitPanelModel.live else {
                FileHandle.standardError.write(Data(
                    "script: \(cmd) needs a mounted git panel\n".utf8))
                return true
            }
            GitLogDiffActions.showCumulativeDiff(panel: panel, doc: model)
        case "session-new-via-goto":
            // TSK-314: the strip "+" button's EXACT action closure —
            // spawn a session whose first paint opens the GoTo prompt
            // prefilled with "~". (In-process real-event synthesis for
            // SwiftUI controls is impossible — 8 constraints, LESSONS
            // "in-process event synthesis" — so the mandate's sanctioned
            // fallback applies: exercise the exact closure, assert the
            // RENDERED outcome in the dump.)
            sessions.requestNewSessionViaGoTo()
        case "session-next":     sessions.nextSession()
        case "session-prev":     sessions.previousSession()
        case "session-rename":
            // Renames the currently-active session. Inline rename in
            // the UI goes through the same SessionsAppCoordinator.rename
            // call; the empty-name guard lives there.
            if let id = sessions.core.activeID {
                sessions.rename(id: id, to: arg)
            }
        // ---- WAVE 2b verification verbs (drive the model directly so
        // the screencap harness can open the built-but-unwired views) ----
        case "file-history":
            // Open the in-app FileHistoryView for `arg` (a file path) as
            // a view-hosting tab. No-op if not a tracked file in a repo.
            model.openFileHistory(for: URL(fileURLWithPath: arg))
        case "emit-test-log":
            // Emit a couple of observability events so the Logs view has
            // visible data in a fresh run (the sink is otherwise quiet
            // until real ViewerCore activity happens).
            Obs.shared.emit(ObsEvent(
                level: .info, subsystem: "wave2b",
                message: "instrumentation smoke event 1"))
            Obs.shared.emit(ObsEvent(
                level: .warn, subsystem: "wave2b",
                message: "instrumentation smoke event 2"))
        // ---- Text tools (clipboard surface; TSK-292/294/295) ----
        // Generators (`tools.uuid`) write fresh output to the clipboard;
        // transforms (`tools.sha256`, `tools.base64Encode/Decode`) read the
        // clipboard, apply, and overwrite it on success. All clipboard IO +
        // status lives in the headless-tested `TextToolRunner`; this layer
        // only picks the verb and surfaces the status string via `Obs`.
        case "tools.uuid":          Self.runTextTool(.generateUUID)
        case "tools.sha256":        Self.runTextTool(.sha256)
        case "tools.base64Encode":  Self.runTextTool(.base64Encode)
        case "tools.base64Decode":  Self.runTextTool(.base64Decode)
        case "tools.sortLinesAsc":  Self.runTextTool(.sortLinesAsc)
        case "tools.sortLinesDesc": Self.runTextTool(.sortLinesDesc)
        case "tools.uniqueLines":   Self.runTextTool(.uniqueLines)
        case "tools.reverseLines":  Self.runTextTool(.reverseLines)
        case "tools.upperCase":     Self.runTextTool(.upperCase)
        case "tools.lowerCase":     Self.runTextTool(.lowerCase)
        case "tools.trimTrailing":  Self.runTextTool(.trimTrailing)
        case "tools.urlEncode":     Self.runTextTool(.urlEncode)
        case "tools.urlDecode":     Self.runTextTool(.urlDecode)
        case "tools.htmlEncode":    Self.runTextTool(.htmlEncode)
        case "tools.htmlDecode":    Self.runTextTool(.htmlDecode)
        case "tools.fileChecksum":
            // SHA-256 of the CURRENT FILE → clipboard. Hash OFF-MAIN (a large
            // file's disk read must not block the UI — cf. TSK-214); the
            // pasteboard write inside the runner hops back to main. Read the
            // @MainActor model.currentURL here (we're on main), capture it.
            let checksumURL = model.currentURL
            DispatchQueue.global(qos: .userInitiated).async {
                let status = FileChecksumRunner.copyChecksum(
                    ofFileAt: checksumURL, pasteboard: SystemPasteboard())
                DispatchQueue.main.async {
                    Obs.shared.emit(ObsEvent(
                        level: .info, subsystem: "tools", message: status))
                }
            }
        case "open-as":
            // WAVE 2b item 6: "<category> <path>" — open a file forced to
            // a viewer category (sqlite/code/plainText/markdown/image/
            // binary/...). Verifies opening a binary as another viewer.
            // NOTE: the byte-grid (HEX) lens is the `binary` category, not a
            // `hex` category — `hex` is a *view mode*, not a `FileCategory`.
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2, let cat = FileCategory(rawValue: bits[0]) {
                model.openAs(url: URL(fileURLWithPath: bits[1]), category: cat)
            } else if bits.count == 2 {
                Self.emitUnknownCategory(verb: "open-as", raw: bits[0])
            }
        case "set-open-as":
            // Override the CURRENT tab's viewer category. "<category>" or
            // "auto" to clear. The byte-grid (HEX) lens is the `binary`
            // category — `hex` is a *view mode*, not a `FileCategory`, so
            // `set-open-as hex` is rejected (use `binary`, or
            // `editor-set-mode hex` to switch the active tab's view mode).
            if arg == "auto" {
                model.setCurrentCategoryOverride(nil)
            } else if let cat = FileCategory(rawValue: arg) {
                model.setCurrentCategoryOverride(cat)
            } else {
                Self.emitUnknownCategory(verb: "set-open-as", raw: arg)
            }
        case "folder-stats":
            // Toggle the folder-stats slide-down under the FILES header.
            // `arg` "on"/"off" sets explicitly; empty toggles.
            switch arg {
            case "on":  model.folderStatsExpanded = true
            case "off": model.folderStatsExpanded = false
            default:    model.folderStatsExpanded.toggle()
            }
        case "nav-sweep":
            // "CYCLES" — run the whole navigation-interaction sweep
            // (NavSweep: tab walk + sidebar toggle + view-mode toggle,
            // each signpost-anchored) inside ONE verb so per-step
            // snapshots don't pollute a profiling capture (TSK-603;
            // resize-sweep precedent). Fire-and-forget: pair with a
            // `delay SECS` line covering ~interactions×0.15s.
            let cycles = max(1, Int(arg) ?? 1)
            Task { @MainActor in
                let n = await NavSweep.run(model: model, cycles: cycles)
                Obs.shared.emit(ObsEvent(
                    level: .info, subsystem: "perf",
                    message: "nav-sweep: \(n) interactions over \(cycles) cycles"))
            }
        case "delay":
            // No model effect. The actual pause is the caller's sleep: the
            // VM `--script` runner parses the arg as seconds (see
            // `AppDelegate.settleNanos(for:)`); the in-process headless
            // harness has no wall clock to wait on, so it just no-ops.
            _ = arg
        // wait-editor-line / wait-rendered-scroll are DELIBERATELY NOT handled here
        // (no `case`): they must fall through to `return false` so the VM `--script`
        // runner (ScriptRunner.swift) runs the REAL blocking poll
        // (waitForRenderedScroll / waitForEditorTopLine) that stashes the live scroll
        // into LiveScrollProbe for the next dump. A no-op `case` here would report
        // them HANDLED → runScriptStep returns early → the runner SKIPS the poll →
        // renderedScrollY stays −1 (the TSK-1046 ScrollRestoreUAT setup −1 bug). The
        // in-process headless harness has no live view and skips unhandled verbs.
        case "editor-scroll-to-line":
            // TSK-1046 (VM scroll-restore test setup): scroll the LIVE CM6 editor
            // so line N is at the viewport top, WITHOUT moving the caret — the
            // faithful analogue of a wheel/trackpad scroll (the bug's scenario).
            // Drives `window.cmDispatch({type:'scrollToLine', line:N})` on the
            // live editor WebView; CM6's DOM scroll event then posts `scrollChanged`
            // back, updating `editorScrollByTab` exactly like a hardware scroll.
            // Needed because synthesized CGEvent keys can't reach the CM6 WebView
            // (KeySynthUATTests / TSK-1020), so a key-driven scroll is impossible.
            if let n = Int(arg), n >= 1,
               let webView = CodeMirrorEditorRegistry.shared.current() {
                webView.evaluateJavaScript(
                    "window.cmDispatch && window.cmDispatch({type:'scrollToLine', line: \(n)})",
                    completionHandler: nil)
            }
        case "rendered-scroll-to":
            // TSK-1046 (VM scroll-restore test setup): scroll the LIVE rendered
            // Markdown preview to pixel offset N (`window.scrollTo`) — a genuine
            // on-screen scroll on the real WKWebView, so the switch-away capture
            // records it and the switch-back restore (the path under test) must
            // bring it back. Same WKWebView-can't-take-CGEvent-keys constraint as
            // the editor verb above.
            if let y = Double(arg), y >= 0,
               let webView = MarkdownRenderedRegistry.shared.current() {
                webView.evaluateJavaScript(
                    "window.scrollTo({top: \(y), behavior: 'instant'})",
                    completionHandler: nil)
            }
        case "capture-rendered-scroll":
            // TSK-1046: probe the LIVE on-screen `window.scrollY` of the active
            // rendered-Markdown preview into `LiveScrollProbe.renderedScrollY`,
            // which the NEXT per-step dump surfaces as `renderedScrollY`. The JS
            // read is async but resolves well within the post-verb settle delay,
            // so a scenario does `capture-rendered-scroll` → `delay 0.3` and then
            // reads the offset off the following dump. This is the only authority
            // for "did the rendered scroll actually restore on switch-IN" — the
            // model dump can't see the WebView's real scroll. No-op headless.
            LiveScrollProbe.captureRenderedScroll()
        case "capture-editor-scroll":
            // TSK-1047: probe the LIVE on-screen CM6 scroll of the active editor
            // (`__mdvView.scrollDOM.scrollTop` + viewport top line) into
            // `LiveScrollProbe.editorScrollTop` / `.editorTopLine`, which the NEXT
            // per-step dump surfaces as `liveEditorScrollTop` / `liveEditorTopLine`.
            // Same capture→settle→read-next-dump pattern as
            // `capture-rendered-scroll`. This is the RENDER AUTHORITY for the
            // editor scroll-restore: the dump's model-only `editorScrollTopLine`
            // is keyed by the CURRENT `Tab.id` and goes stale/empty after a switch
            // mints a fresh id, even when the WebView is correctly scrolled. No-op
            // headless (no WebView).
            LiveScrollProbe.captureEditorScroll()
        case "snapshot":
            // Handled by caller after this returns.
            _ = arg
        default:
            // Window / NSApp / AppDelegate-coupled verbs (resize, find,
            // diagnostic-window, instrumentation-window) and any unknown
            // verb fall through to the caller.
            return false
        }
        return true
    }

    /// Run a clipboard text tool against the system pasteboard and surface
    /// the resulting status through `Obs` (visible in the Logs view and, in
    /// the live app, the natural hook for a toast). Factored out so all four
    /// verb cases share one line and the live adapter stays trivial — the
    /// testable logic already lives in `TextToolRunner` (driven against a
    /// fake pasteboard in `TextToolRunnerTests`, never the real clipboard).
    private static func runTextTool(_ verb: TextToolVerb) {
        let status = TextToolRunner.run(verb, pasteboard: SystemPasteboard())
        Obs.shared.emit(ObsEvent(
            level: .info, subsystem: "tools", message: status))
    }

    /// Surface an explicit error when an `open-as` / `set-open-as` verb is
    /// handed a category arg that is not a `FileCategory` raw value — the
    /// old behaviour silently no-op'd (e.g. `set-open-as hex`, where the
    /// byte-grid lens is actually the `binary` category). Emitting through
    /// `Obs` makes the bad arg visible in the Logs view / stderr instead
    /// of vanishing, and lists the accepted values to self-document.
    private static func emitUnknownCategory(verb: String, raw: String) {
        let valid = FileCategory.allCases
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")
        Obs.shared.emit(ObsEvent(
            level: .error,
            subsystem: "automation",
            message: "\(verb): unknown FileCategory '\(raw)' — ignored",
            fields: ["verb": verb, "arg": raw, "valid": valid]))
    }

    /// The `model` sub-dictionary embedded in every per-step diagnostic
    /// dump. Lifted out of `AppDelegate.captureStepArtifacts` so the VM
    /// `--script` path and the in-process `HeadlessHarness` emit a
    /// byte-identical projection — the existing Page Objects read these
    /// keys (`zoom`, `currentViewMode`, `sessions`, `activeSessionID`, …)
    /// and don't care which producer wrote them.
    ///
    /// Pure value projection: no AppKit, no window. The strongly-typed
    /// session structs are flattened to `[String: Any]` because the dump
    /// serializer (and `JSONSerialization`) only accepts plist-able types.
    public static func modelStateDump(
        model: DocumentModel,
        sessions: SessionsAppCoordinator
    ) -> [String: Any] {
        // Sessions snapshot for VM UI tests. We project the coordinator's
        // canonical list to plain JSON-able dictionaries; the dump
        // serializer rejects strongly-typed structs.
        let sessionSummaries: [[String: Any]] = sessions.core.sessions.map { snap in
            [
                "id": snap.id.uuidString,
                "displayName": snap.displayName,
                "sidebarRootPath": snap.sidebarRootPath ?? "",
            ]
        }
        let stateKind: String = {
            switch model.currentState {
            case .empty: return "empty"
            case .loading: return "loading"
            case .loaded: return "loaded"
            case .binary: return "binary"
            case .error: return "error"
            case .hostedView: return "hostedView"
            case .preview: return "preview"
            }
        }()
        // Active editor buffer projection (TSK-818). Lets the VM key-synthesis
        // smoke assert the live `DocumentModel` actually received injected
        // keystrokes (`ui-type`/`ui-key` posting real CGEvents into the focused
        // CM6 field). Read-only: `editorBuffer` returns nil until a tab's buffer
        // is materialized, so an un-edited tab projects "" / false — never
        // forces a buffer into existence here.
        let activeEditor = model.tabs.selected.flatMap { model.editorBuffer(forTabID: $0.id) }
        return [
            "zoom": model.zoom,
            "currentViewMode": model.currentViewMode.rawValue,
            "currentStateKind": stateKind,
            "editorText": activeEditor?.text ?? "",
            "editorIsDirty": activeEditor?.isDirty ?? false,
            // `windowTitle` is a pure model projection (`tabs.selected?.title
            // ?? "TextView"` — see DocumentModel) that `main.swift` mirrors
            // onto `NSWindow.title`. Surfacing it here lets the title-based
            // Page Object accessors (TabBarPage.activeTabTitle, the
            // title-change-count invariants in Scenario/LongFlow/Deep) read
            // the same value headless that they read from the live
            // `window.title` — the title was never a ④/window observable, it
            // was always model state.
            "windowTitle": model.windowTitle,
            "tabCount": model.tabs.tabs.count,
            "selectedTabIndex": model.tabs.selectedIndex ?? -1,
            "isCurrentTabFormatted": model.isCurrentTabFormatted,
            "isCurrentTabBookmarked": model.isCurrentTabBookmarked,
            "isPalettePresented": model.isPalettePresented,
            "isGoToPathPresented": model.isGoToPathPresented,
            "isRenderedFindBarPresented": model.isRenderedFindBarPresented,
            "isCrossSearchPresented": model.isCrossSearchPresented,
            "sidebarVisible": model.sidebar.isVisible,
            "currentURL": model.currentURL?.path ?? "",
            // Bounded prefix of the selected tab's LOADED source text (TSK-1241).
            // Lets a UAT assert WHAT loaded for read-only/source-view content —
            // e.g. a routed .rtf/.docx shows its EXTRACTED text — where
            // `editorText` is "" (no materialized buffer for an un-edited
            // read-only tab).
            "loadedTextPrefix": model.selectedLoadedTextPrefix,
            "lastGoToError": model.lastGoToError,
            // TSK-1046: the active editor tab's LIVE top-visible line, as
            // reported by CM6 itself (the JS `scrollChanged` → `recordEditorScroll`
            // channel — NOT a model-only value). After a session/tab switch-IN
            // this reflects where the editor ACTUALLY scrolled on screen, so a VM
            // UI test can assert the editor scroll was restored (0 / absent ⇒ top
            // / not an editor tab). The render-path bug (TSK-1046) was precisely
            // that this came back to the top even though the persisted top line
            // was correct; pinning it here makes the regression observable.
            "editorScrollTopLine":
                model.tabs.selected.flatMap {
                    model.editorScrollByTab[$0.id]?.viewportFromLine
                } ?? 0,
            // TSK-1046: the active rendered-Markdown preview's LIVE on-screen
            // `window.scrollY`, captured by the most recent `capture-rendered-scroll`
            // verb (−1 until one runs). The render authority for the rendered
            // surface's scroll-restore — the dump can't read a live WebView, so the
            // verb stashes it in `LiveScrollProbe` for the following dump to surface.
            "renderedScrollY": LiveScrollProbe.renderedScrollY,
            "renderedProbeDiag": LiveScrollProbe.lastProbeDiag,
            "editorProbeDiag": LiveScrollProbe.lastEditorProbeDiag,
            // TSK-1047: the LIVE CM6 scroll the active editor WebView ACTUALLY
            // holds on screen, read straight off `__mdvView` by the
            // `capture-editor-scroll` / `wait-editor-line` verbs (−1 until one
            // runs / no editor). The RENDER AUTHORITY for "did the editor scroll
            // actually restore on switch-IN" — unlike `editorScrollTopLine` (a
            // MODEL field keyed by the current `Tab.id`, which a switch leaves
            // stale), this reflects the WebView's true viewport. The bug
            // (TSK-1046/1047) was precisely that this returned to the top while
            // the model field looked correct; pinning the LIVE value makes the
            // on-screen regression observable.
            "liveEditorScrollTop": LiveScrollProbe.editorScrollTop,
            "liveEditorTopLine": LiveScrollProbe.editorTopLine,
            "sessions": sessionSummaries,
            "activeSessionID": sessions.core.activeID?.uuidString ?? "",
            // TSK-522/523: Git Log selection projection (via the live
            // panel registry — empty dict when the panel isn't mounted).
            // Lets the UAT scenarios assert multi-select/cumulative-diff
            // outcomes cross-process.
            "gitLog": GitPanelModel.live.map { panel in
                [
                    "repoRoot": panel.repoRoot?.path ?? "",
                    "selectedLogSHA": panel.selectedLogSHA ?? "",
                    "selectedLogSHAs": Array(panel.selectedLogSHAs).sorted(),
                    "logCount": panel.logEntries.count,
                ] as [String: Any]
            } ?? [:],
            // TSK-505: checksum-section projection (via the live panel
            // registry — empty dict when no MetadataPanel is mounted). Lets
            // the UAT assert the compute outcome (state + hash) cross-process.
            "metadataChecksum": MetadataChecksumModel.live.map { cm -> [String: Any] in
                var out: [String: Any] = ["algorithm": cm.algorithm.rawValue]
                switch cm.state {
                case .idle:          out["state"] = "idle"
                case .computing:     out["state"] = "computing"
                case .done(let hex): out["state"] = "done"; out["hash"] = hex
                case .failed:        out["state"] = "failed"
                }
                return out
            } ?? [:],
            // Nested sidebar projection. SidebarPage reads
            // `model.sidebar.rootURL` from here; without it the
            // sidebar-set-root regression guard (InteractionDeepTests)
            // always saw nil and failed. `absoluteString` preserves the
            // directory trailing slash the assertions match on.
            "sidebar": [
                "rootURL": model.sidebar.rootURL?.absoluteString ?? "",
                "isVisible": model.sidebar.isVisible,
            ],
            // LSP surface projection. The diagnostics + navigation stores
            // are @MainActor and synchronously readable, so they project
            // directly here — making the Problems (counts by severity) and
            // References / Workspace-Symbol (nav rows + mode) surfaces
            // dump-observable for the UAT catalog's LSP-02/03 items, which
            // were previously MANUAL/VM-only. Driven headless via the
            // `lsp-seed-*` / `lsp-clear-*` verbs below.
            //
            // NOT included here: the per-server pool state (LSPPool is an
            // `actor`; its `snapshot()` is async and can't be awaited from
            // this synchronous projection) and the outline symbols (the
            // LSPOutlineModel is a `@StateObject` owned by SidebarView, not
            // reachable from this (model, sessions) pair). Surfacing those
            // would need an async dump path / model-ownership change — out
            // of scope for a pure value projection.
            "lsp": [
                "problems": [
                    "total": model.lspDiagnostics.totalCount,
                    "errors": model.lspDiagnostics.errorCount,
                    "warnings": model.lspDiagnostics.warningCount,
                    "information": model.lspDiagnostics.informationCount,
                    "hints": model.lspDiagnostics.hintCount,
                    "files": model.lspDiagnostics.fileCount,
                ],
                "navigation": [
                    "mode": model.lspNavigation.mode.rawValue,
                    "rowCount": model.lspNavigation.rows.count,
                    "isLoading": model.lspNavigation.isLoading,
                    "query": model.lspNavigation.query,
                    "errorMessage": model.lspNavigation.errorMessage ?? "",
                    "contextDescription": model.lspNavigation.contextDescription ?? "",
                ],
            ],
        ]
    }
}

/// Production `MacroDispatcher` (TSK-1162): re-dispatches a recorded command by
/// forwarding its script-verb back through `ScriptVerb.apply` — the same path the
/// verb originally took (its record-hook re-fires but is re-entrancy-guarded by
/// `MacroController.isReplaying`, so a replay never re-records itself). A replay
/// runs on the main thread (`MacroController.replayLast` is `@MainActor`), so the
/// non-isolated protocol hop is bridged with `MainActor.assumeIsolated`.
struct LiveMacroDispatcher: MacroDispatcher {
    let model: DocumentModel
    let sessions: SessionsAppCoordinator
    func dispatch(command: CommandDescriptor, args: [String: String]) -> Bool {
        guard let verb = command.scriptVerb else { return false }
        return MainActor.assumeIsolated {
            ScriptVerb.apply(verb: verb, to: model, sessions: sessions)
        }
    }
}
