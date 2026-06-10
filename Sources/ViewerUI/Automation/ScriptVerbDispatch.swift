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

    /// Apply one script verb line (`"<cmd> <arg>"`) to `model` / `sessions`.
    ///
    /// - Returns: `true` if the verb was recognised and applied here;
    ///   `false` if it is a window / `NSApp` / AppDelegate-coupled verb
    ///   the caller must handle (or, for the headless harness, skip).
    @discardableResult
    public static func apply(
        verb line: String,
        to model: DocumentModel,
        sessions: SessionsAppCoordinator
    ) -> Bool {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first else { return true }
        let arg = parts.count > 1 ? parts[1] : ""
        switch cmd {
        case "toggle-view":    model.toggleViewMode()
        case "toggle-sidebar": model.sidebar.toggleVisibility()
        case "zoom-in":        model.zoomIn()
        case "zoom-out":       model.zoomOut()
        case "zoom-reset":     model.zoomReset()
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
        case "show-palette":    model.showPalette()
        case "dismiss-palette": model.dismissPalette()
        case "show-goto":       model.showGoToPath()
        case "dismiss-goto":    model.dismissGoToPath()
        case "goto-commit":     model.commitGoToPath(arg, newSession: false)
        case "goto-commit-new-session": model.commitGoToPath(arg, newSession: true)
        case "toggle-format":   model.toggleFormat()
        // Split view (Omni-invokability: view.toggleSplit / view.swapSplit
        // previously had no script verb, so they were menu/⌘\-only). Both wire
        // to existing @MainActor model methods — headless-safe, no window.
        case "toggle-split":    model.toggleSplit()
        case "swap-split":      model.swapSplit()
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
        case "toggle-bookmark": model.toggleCurrentTabBookmark()
        // Omni-invokability (git.showPanel / view.toggleLineBookmark previously
        // had no script verb). Both wire to existing @MainActor model methods.
        case "show-git-panel":  model.showGitPanel()
        case "toggle-line-bookmark": model.toggleCurrentLineBookmark()
        case "git-file-history":
            // Omni-invokable "Show File History" for the CURRENT file (the
            // palette can't supply a path; the existing `file-history <path>`
            // verb stays for explicit-path automation). No-op off-repo /
            // untracked, exactly like the menu action.
            if let u = model.currentURL { model.openFileHistory(for: u) }
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
        return [
            "zoom": model.zoom,
            "currentViewMode": model.currentViewMode.rawValue,
            "currentStateKind": stateKind,
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
            "lastGoToError": model.lastGoToError,
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
