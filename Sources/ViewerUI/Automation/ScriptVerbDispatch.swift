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
        case "show-palette":    model.showPalette()
        case "dismiss-palette": model.dismissPalette()
        case "show-goto":       model.showGoToPath()
        case "dismiss-goto":    model.dismissGoToPath()
        case "goto-commit":     model.commitGoToPath(arg, newSession: false)
        case "goto-commit-new-session": model.commitGoToPath(arg, newSession: true)
        case "toggle-format":   model.toggleFormat()
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
        case "toggle-bookmark": model.toggleCurrentTabBookmark()
        case "show-cross-search":    model.showCrossSearch()
        case "dismiss-cross-search": model.dismissCrossSearch()
        case "set-cross-query":      model.crossSearchQuery = arg; model.runCrossSearch()
        case "show-find":       model.showRenderedFindBar()
        case "dismiss-find":    model.dismissRenderedFindBar()
        case "find-next":       model.renderedFindNext()
        case "find-prev":       model.renderedFindPrev()
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
        case "open-as":
            // WAVE 2b item 6: "<category> <path>" — open a file forced to
            // a viewer category (sqlite/code/plainText/markdown/image/
            // binary/...). Verifies opening a binary as another viewer.
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if bits.count == 2, let cat = FileCategory(rawValue: bits[0]) {
                model.openAs(url: URL(fileURLWithPath: bits[1]), category: cat)
            }
        case "set-open-as":
            // Override the CURRENT tab's viewer category. "<category>" or
            // "auto" to clear.
            if arg == "auto" {
                model.setCurrentCategoryOverride(nil)
            } else if let cat = FileCategory(rawValue: arg) {
                model.setCurrentCategoryOverride(cat)
            }
        case "folder-stats":
            // Toggle the folder-stats slide-down under the FILES header.
            // `arg` "on"/"off" sets explicitly; empty toggles.
            switch arg {
            case "on":  model.folderStatsExpanded = true
            case "off": model.folderStatsExpanded = false
            default:    model.folderStatsExpanded.toggle()
            }
        case "delay":
            // Handled by caller's sleep; no-op here.
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
            // Nested sidebar projection. SidebarPage reads
            // `model.sidebar.rootURL` from here; without it the
            // sidebar-set-root regression guard (InteractionDeepTests)
            // always saw nil and failed. `absoluteString` preserves the
            // directory trailing slash the assertions match on.
            "sidebar": [
                "rootURL": model.sidebar.rootURL?.absoluteString ?? "",
                "isVisible": model.sidebar.isVisible,
            ],
        ]
    }
}
