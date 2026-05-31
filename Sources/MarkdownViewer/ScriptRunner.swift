import AppKit
import Foundation
import ViewerCore
import ViewerKit
import ViewerUI

/// `--script PATH` interpreter for the L4/L5 VM-driven UI tests.
///
/// Pure code-motion out of `main.swift` (Quality #I, 2026-05-25). The
/// dispatcher reaches into AppDelegate's `model`, `sessions`, and
/// `window` — kept as an extension so the access stays direct and we
/// don't have to widen any internal API surfaces.
extension AppDelegate {

    /// Reads a newline-separated command script and executes it
    /// step-by-step against the model. After each step, writes a JSON
    /// diagnostic + PNG snapshot to `/var/folders/.../mdv-step-NN.{json,png}`.
    /// Exits 0 after the final step. Used by L4 / L5 interaction tests.
    ///
    /// Commands (one per line, # for comments):
    ///   toggle-view             cycle rendered <-> source
    ///   toggle-sidebar
    ///   zoom-in / zoom-out / zoom-reset
    ///   open PATH               open a file or folder
    ///   close-tab
    ///   new-tab
    ///   next-tab / prev-tab
    ///   select-tab N            (1-indexed)
    ///   show-palette / dismiss-palette
    ///   delay SECS              pause without action
    ///   snapshot                explicit snapshot (otherwise done after each command)
    func runScript(at path: String) {
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write(Data("script: cannot read \(path)\n".utf8))
            exit(2)
        }
        let lines = data.split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        Task { @MainActor in
            // Give launch one full second to settle (window appears, file loads).
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            for (step, line) in lines.enumerated() {
                self.runScriptStep(line)
                try? await Task.sleep(nanoseconds: 300_000_000)
                self.captureStepArtifacts(step: step + 1, label: line)
            }
            exit(0)
        }
    }

    func runScriptStep(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        switch cmd {
        case "toggle-view":    model.toggleViewMode()
        case "toggle-sidebar": model.sidebar.toggleVisibility()
        case "zoom-in":        model.zoomIn()
        case "zoom-out":       model.zoomOut()
        case "zoom-reset":     model.zoomReset()
        case "open":           model.openPath(URL(fileURLWithPath: arg))
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
        case "resize":
            // "WxH" e.g. "1200x800"
            let dims = arg.split(separator: "x").compactMap { Int($0) }
            if dims.count == 2, let win = self.window {
                var frame = win.frame
                frame.size = NSSize(width: dims[0], height: dims[1])
                win.setFrame(frame, display: true, animate: false)
            }
        // ---- WAVE 2b verification verbs (drive the model directly so
        // the screencap harness can open the built-but-unwired views) ----
        case "file-history":
            // Open the in-app FileHistoryView for `arg` (a file path) as
            // a view-hosting tab. No-op if not a tracked file in a repo.
            model.openFileHistory(for: URL(fileURLWithPath: arg))
        case "diagnostic-window":
            // WAVE 2b item 4: open the diagnostic tool window (gated).
            showDiagnosticWindow(nil)
        case "instrumentation-window":
            // WAVE 2b item 5: open the instrumentation tool window (gated).
            showInstrumentationWindow(nil)
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
        case "find":
            // Invoke the system find action on first responder NSTextView.
            NSApp.sendAction(
                #selector(NSTextView.performFindPanelAction(_:)),
                to: nil, from: nil
            )
        case "delay":
            // Handled by caller's sleep; no-op here.
            _ = arg
        case "snapshot":
            // Handled by caller after this returns.
            _ = arg
        default:
            FileHandle.standardError.write(
                Data("script: unknown command '\(cmd)'\n".utf8))
        }
    }

    func captureStepArtifacts(step: Int, label: String) {
        guard let win = window else { return }
        let n = String(format: "%02d", step)
        // #193: run-scoped artifact dir. `MDV_ARTIFACT_DIR` (set by the
        // harness) gives each parallel live-app test its own directory so
        // `mdv-step-NN.json` writes don't stomp each other; falls back to
        // the per-user tmpdir (/var/folders/..., safe from the symlink-
        // hijack scenario possible in /tmp) for non-test launches.
        let tmp = ArtifactDir.url
        let json = tmp.appendingPathComponent("mdv-step-\(n).json").path
        let png  = tmp.appendingPathComponent("mdv-step-\(n).png").path
        let dump = DiagnosticDump.dump(window: win)
        var enriched = dump
        enriched["step"] = step
        enriched["label"] = label
        // Expose model state so tests can verify zoom / mode / tab
        // count without scraping NSTextView fonts (which don't exist
        // in the pure-SwiftUI source view).
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
        enriched["model"] = [
            "zoom": model.zoom,
            "currentViewMode": model.currentViewMode.rawValue,
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
        if let data = try? JSONSerialization.data(
            withJSONObject: enriched,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: URL(fileURLWithPath: json))
        }
        _ = DiagnosticDump.captureWindowToPNG(win, path: png)
        // Verification-only: when a separate tool window (Diagnostics /
        // Instrumentation) is the key window, also snapshot it via the
        // same permission-free in-process cacheDisplay path. The main
        // capture above only ever targets `self.window`, so without this
        // the WAVE-2b tool windows are uncapturable by the screencap
        // harness. No effect on app behaviour — purely an extra artifact.
        // Prefer the key window, but fall back to any *other* visible
        // window — in MDV_BACKGROUND / non-activated runs the app has no
        // key window, yet the tool window is still ordered-in and fully
        // laid out, so cacheDisplay snapshots it correctly.
        let otherWindow = NSApp.keyWindow.flatMap { $0 !== win ? $0 : nil }
            ?? NSApp.windows.first { $0 !== win && $0.isVisible && $0.contentView != nil }
        if let other = otherWindow {
            let keyPNG = tmp.appendingPathComponent("mdv-step-\(n)-key.png").path
            if DiagnosticDump.captureWindowToPNG(other, path: keyPNG) {
                FileHandle.standardError.write(
                    Data("step \(n) [\(label)] tool-window '\(other.title)' → \(keyPNG)\n".utf8))
            }
        }
        FileHandle.standardError.write(
            Data("step \(n) [\(label)] → \(json) + \(png)\n".utf8))
    }
}
