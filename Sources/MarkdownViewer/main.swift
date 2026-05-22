import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import ViewerCore
import ViewerUI
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    let model = DocumentModel()
    /// Phase-1 session machinery. Owns the value-level
    /// `SessionsCoordinator` + the active `SessionState` façade over
    /// the shared `model`. Bootstraps on launch, drains on terminate.
    /// See `docs/SESSIONS_DESIGN.md` §11.
    lazy var sessions: SessionsAppCoordinator = SessionsAppCoordinator(
        model: self.model,
        initialRoot: PreferencesStore().lastFolderURL
    )
    var window: NSWindow?
    private var openRecentMenu: NSMenu?
    private var sessionJumpMenu: NSMenu?
    private var windowMenu: NSMenu?
    private var cancellables: Set<AnyCancellable> = []
    private var diagnosticSignalSource: DispatchSourceSignal?
    private var mcpServer: MCPServer?
    /// Captured at hosting-controller construction so the
    /// `--walkthrough PATH` flag can start playback against the
    /// SwiftUI-owned controller without rebuilding the view body.
    fileprivate var walkthroughController: WalkthroughPlayerController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `--mcp-stdio`: skip all UI work and run the MCP server on
        // stdin/stdout. We still need an NSApplication to host
        // `@MainActor` model state, but no window, no menu, no
        // Services registration. The activation policy is flipped to
        // `.prohibited` at module scope before `app.run()` so the
        // process never shows in the Dock.
        if mcpStdioMode {
            startMCPServer()
            return
        }

        // Opt out of macOS's automatic window tabbing — we ship our own in-app
        // tab bar; the system "Show Tab Bar" menu item is confusing here.
        NSWindow.allowsAutomaticWindowTabbing = false

        buildMenu()
        registerAsServicesProvider()

        // CRITICAL: use NSHostingController.view (not a bare NSHostingView
        // set as contentView). The controller's view installs auto-layout
        // constraints that pin it to fill the window's contentView, so when
        // the window's frame is restored from autosave or the user resizes,
        // the SwiftUI content grows with it. The bare-NSHostingView pattern
        // froze the hosted view at the window's *initial* content size and
        // never resized it — that's the bug where opening any non-markdown
        // file revealed a sliver of UI (line numbers only) inside a vast
        // empty white background.
        let rootView = ContentView(model: model, sessionsApp: sessions)
        // Stash the walkthrough controller so the --walkthrough flag
        // handler below can call `start(_:)` on it without rebuilding
        // ContentView's body state.
        self.walkthroughController = rootView.walkthroughController
        let hostingController = NSHostingController(rootView: rootView)

        let minContentSize = NSSize(width: 600, height: 360)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = model.windowTitle
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // Hard minimum content size enforced by AppKit. SwiftUI's
        // `.frame(minWidth:minHeight:)` is a layout request to the parent,
        // not an OS-level floor.
        window.contentMinSize = minContentSize
        // B20: setFrameAutosaveName registers the autosave name AND restores
        // any saved frame for that name. Previously we called center()
        // *before* this, so the centered frame was immediately overwritten
        // by the autosaved frame, making the window appear to "jump" on
        // launch. Now we check UserDefaults (which is where AppKit persists
        // the frame, keyed `NSWindow Frame <name>`) and only center when
        // there's no saved frame yet.
        let autosaveName = "MainWindow"
        let savedFrameKey = "NSWindow Frame \(autosaveName)"
        _ = window.setFrameAutosaveName(autosaveName)
        if UserDefaults.standard.string(forKey: savedFrameKey) == nil {
            window.center()
        }
        // After restoring the autosaved frame, defend against two cases
        // where the user can be left with a useless window:
        //   1. The saved frame is below the minimum content size.
        //   2. The saved frame is on a screen that no longer exists
        //      (e.g. external display disconnected since last launch).
        // Either way: clamp to a sane size and re-center on a real screen.
        var frame = window.frame
        let minWindowSize = window.frameRect(forContentRect:
            NSRect(origin: .zero, size: minContentSize)).size
        var needsReposition = false
        if frame.size.width < minWindowSize.width || frame.size.height < minWindowSize.height {
            frame.size.width = max(frame.size.width, minWindowSize.width)
            frame.size.height = max(frame.size.height, minWindowSize.height)
            needsReposition = true
        }
        // If the saved frame doesn't overlap any visible screen at all
        // (a frame purely off-screen on a now-disconnected monitor),
        // recover. NSScreen.screens contains only screens currently
        // attached, so a missing one means we lost it.
        let onAScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
        if !onAScreen {
            needsReposition = true
        }
        if needsReposition {
            window.setFrame(frame, display: false)
            window.center()
        }
        showWindow(window)
        self.window = window

        // Write the WindowServer-assigned windowNumber so test runners
        // (and `scripts/visual-smoke.sh`) can invoke
        // `screencapture -l<id>` against our specific window instead of
        // having to enumerate via private APIs. NSWindow.windowNumber
        // is a public Int corresponding to the CGWindowID. The file
        // path is per-user tmp + bundle identifier so multiple users
        // / multiple Mac windows don't collide.
        if let identifier = Bundle.main.bundleIdentifier {
            let tmp = FileManager.default.temporaryDirectory
            let url = tmp.appendingPathComponent("\(identifier).windowid")
            try? "\(window.windowNumber)".write(
                to: url, atomically: true, encoding: .utf8
            )
        }

        // A5: keep window.title in sync with model.$windowTitle. Eliminates
        // the eight manual `window?.title = model.windowTitle` syncs that
        // were sprinkled across action handlers (and easy to forget on new
        // actions).
        model.$windowTitle
            .receive(on: DispatchQueue.main)
            .sink { [weak self] title in
                self?.window?.title = title
            }
            .store(in: &cancellables)

        // Plugins: bundled (Tier 0) register synchronously; on-disk
        // (Tier A/B) load via the registry. Anything awaiting a grant
        // bubbles up here and gets a one-shot first-install prompt.
        // We defer to the next runloop tick so the main window is on
        // screen before the modal appears.
        let pending = PluginsBootstrap.loadAtLaunch()
        if !pending.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard self != nil else { return }
                for p in pending {
                    PluginGrantPrompt.present(
                        manifest: p.manifest, folder: p.folder
                    ) { _ in
                        // Re-evaluate this plugin so its contributions
                        // register (or stay dropped) per the decision.
                        _ = PluginRegistry.shared.reloadOne(folder: p.folder)
                    }
                }
            }
        }

        // Phase 1 sessions: subsumes the old
        // `restorePreviousFolderIfAvailable()` +
        // `restoreWorkspaceAutoSlot()` pair — the sessions coordinator
        // reads `Sessions/index.json`, migrates from
        // `Workspaces/_last.json` on first launch of the new build,
        // and hydrates the shared `model` from the active session's
        // snapshot. See SESSIONS_DESIGN.md §8 for the migration
        // contract.
        if ProcessInfo.processInfo.environment["MDV_SKIP_WORKSPACE_RESTORE"] != "1" {
            sessions.bootstrap()
        }
        // One-way callback: folder context menus invoke this to spawn a
        // new session via the coordinator without DocumentModel needing
        // to import SessionsAppCoordinator.
        model.openFolderInNewSession = { [weak self] url in
            self?.sessions.openFolder(url, forceNew: true)
        }

        // Open file from argv if provided. Detects folder vs file.
        // B19: resolve relative to the process's cwd (which is the user's
        // shell cwd when launched from terminal; "/" when launched via
        // Launch Services). `expandingTildeInPath` handles ~/foo paths.
        // Flags accepted (parsed positionally for simplicity):
        //   --diagnose            Dump JSON view tree to stdout and exit.
        //   --source              Force source view mode (with --diagnose / --auto-snapshot).
        //   --auto-snapshot SECS  Wait SECS, write PNG+JSON to /tmp, exit. No external signaling.
        //                         Lets us snapshot without terminal stealing focus.
        let rawArgs = Array(CommandLine.arguments.dropFirst())
        let diagnoseMode = rawArgs.contains("--diagnose")
        let forceSource = rawArgs.contains("--source")
        var autoSnapshotDelay: Double = -1
        var scriptPath: String? = nil
        var walkthroughPath: String? = nil
        var skipNext = false
        var pathArgs: [String] = []
        for (i, a) in rawArgs.enumerated() {
            if skipNext { skipNext = false; continue }
            if a == "--auto-snapshot" {
                if i + 1 < rawArgs.count, let s = Double(rawArgs[i + 1]) {
                    autoSnapshotDelay = s
                    skipNext = true
                }
                continue
            }
            if a == "--script" {
                if i + 1 < rawArgs.count {
                    scriptPath = rawArgs[i + 1]
                    skipNext = true
                }
                continue
            }
            if a == "--walkthrough" {
                if i + 1 < rawArgs.count {
                    walkthroughPath = rawArgs[i + 1]
                    skipNext = true
                }
                continue
            }
            if a.hasPrefix("--") { continue }
            pathArgs.append(a)
        }
        if let path = pathArgs.first {
            let expanded = (path as NSString).expandingTildeInPath
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let url = URL(fileURLWithPath: expanded, relativeTo: cwd)
                .standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) {
                model.openPath(url)
            }
        }

        activateIfForeground()

        installDiagnosticSignalHandler()

        if diagnoseMode {
            runDiagnoseAndExit(forceSource: forceSource)
        }
        if autoSnapshotDelay >= 0 {
            scheduleAutoSnapshot(after: autoSnapshotDelay, forceSource: forceSource)
        }
        if let scriptPath {
            runScript(at: scriptPath)
        }
        if let walkthroughPath {
            startWalkthrough(at: walkthroughPath)
        }
    }

    /// Load a walkthrough JSON from disk and start playback. Used by
    /// `--walkthrough PATH` for local dev (bypasses the file-drop
    /// transport). Failures write to stderr and leave the player
    /// inactive — we don't exit the process because the rest of the
    /// session is still usable.
    private func startWalkthrough(at path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = URL(fileURLWithPath: expanded, relativeTo: cwd).standardizedFileURL
        switch WalkthroughLoader.load(fileAt: url) {
        case .success(let script):
            // Defer one runloop tick so the SwiftUI hosting controller
            // has wired the StateObject before we mutate it.
            DispatchQueue.main.async { [weak self] in
                self?.walkthroughController?.start(script)
            }
        case .failure(let err):
            FileHandle.standardError.write(
                Data("walkthrough: load failed: \(err)\n".utf8)
            )
        }
    }

    /// Reads a newline-separated command script and executes it
    /// step-by-step against the model. After each step, writes a JSON
    /// diagnostic + PNG snapshot to /tmp/mdv-step-NN.{json,png}. Exits
    /// 0 after the final step. Used by L4 / L5 interaction tests.
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
    private func runScript(at path: String) {
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

    private func runScriptStep(_ line: String) {
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
        case "toggle-format":   model.toggleFormat()
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
        case "resize":
            // "WxH" e.g. "1200x800"
            let dims = arg.split(separator: "x").compactMap { Int($0) }
            if dims.count == 2, let win = self.window {
                var frame = win.frame
                frame.size = NSSize(width: dims[0], height: dims[1])
                win.setFrame(frame, display: true, animate: false)
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

    private func captureStepArtifacts(step: Int, label: String) {
        guard let win = window else { return }
        let n = String(format: "%02d", step)
        // Per-user tmpdir at /var/folders/... is safe from the
        // symlink-hijack scenario possible in /tmp.
        let tmp = FileManager.default.temporaryDirectory
        let json = tmp.appendingPathComponent("mdv-step-\(n).json").path
        let png  = tmp.appendingPathComponent("mdv-step-\(n).png").path
        let dump = DiagnosticDump.dump(window: win)
        var enriched = dump
        enriched["step"] = step
        enriched["label"] = label
        // Expose model state so tests can verify zoom / mode / tab
        // count without scraping NSTextView fonts (which don't exist
        // in the pure-SwiftUI source view).
        enriched["model"] = [
            "zoom": model.zoom,
            "currentViewMode": model.currentViewMode.rawValue,
            "tabCount": model.tabs.tabs.count,
            "selectedTabIndex": model.tabs.selectedIndex ?? -1,
            "isCurrentTabFormatted": model.isCurrentTabFormatted,
            "isCurrentTabBookmarked": model.isCurrentTabBookmarked,
            "isPalettePresented": model.isPalettePresented,
            "isRenderedFindBarPresented": model.isRenderedFindBarPresented,
            "isCrossSearchPresented": model.isCrossSearchPresented,
            "sidebarVisible": model.sidebar.isVisible,
            "currentURL": model.currentURL?.path ?? "",
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: enriched,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: URL(fileURLWithPath: json))
        }
        _ = DiagnosticDump.captureWindowToPNG(win, path: png)
        FileHandle.standardError.write(
            Data("step \(n) [\(label)] → \(json) + \(png)\n".utf8))
    }

    /// Wait the given delay (during which we DON'T cede focus to a
    /// caller terminal), then dump JSON + PNG of our own window to
    /// /tmp/mdv-auto-{json,png}, then exit. Avoids the AppleScript /
    /// terminal-focus problems of SIGUSR1-driven snapshots.
    private func scheduleAutoSnapshot(after delay: Double, forceSource: Bool) {
        if forceSource, model.supportsViewModeToggle, model.currentViewMode != .source {
            DispatchQueue.main.async { self.model.toggleViewMode() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let win = self.window else {
                FileHandle.standardError.write(Data("auto-snapshot: no window\n".utf8))
                exit(2)
            }
            activateIfForeground()
            showWindow(win)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // Per-user tmpdir at /var/folders/... is safe from the
                // symlink-hijack scenario possible in /tmp.
                let tmp = FileManager.default.temporaryDirectory
                let json = tmp.appendingPathComponent("mdv-auto.json").path
                let png  = tmp.appendingPathComponent("mdv-auto.png").path
                let dump = DiagnosticDump.dump(window: win)
                let data = (try? JSONSerialization.data(
                    withJSONObject: dump,
                    options: [.prettyPrinted, .sortedKeys]
                )) ?? Data()
                try? data.write(to: URL(fileURLWithPath: json))
                let captured = DiagnosticDump.captureWindowToPNG(win, path: png)
                FileHandle.standardError.write(
                    Data("auto-snapshot → \(json) + \(captured ? png : "PNG-failed")\n".utf8))
                exit(captured ? 0 : 3)
            }
        }
    }

    /// Trap SIGUSR1 to dump the live NSView tree to
    /// /tmp/mdv-diagnostic-<pid>.json. Lets us inspect state DURING an
    /// interactive session that's exhibiting a visual bug, instead of
    /// only on headless launch (which may differ from real use).
    /// Usage: `kill -USR1 $(pgrep MarkdownViewer)`
    private func installDiagnosticSignalHandler() {
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, let win = self.window else { return }
            // FIRST: force window to front and key so AppKit's
            // occlusion-suspends-drawing optimization doesn't yield a
            // stale snapshot. We capture the realized-on-screen state,
            // so the window must actually be on-screen + drawing.
            activateIfForeground()
            showWindow(win)
            // Give the compositor one runloop tick to flush after
            // activation before we capture.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let pid = getpid()
                // Per-user tmpdir at /var/folders/... is safe from the
                // symlink-hijack scenario possible in /tmp.
                let tmp = FileManager.default.temporaryDirectory
                let jsonPath = tmp.appendingPathComponent("mdv-diagnostic-\(pid).json").path
                let pngPath  = tmp.appendingPathComponent("mdv-snapshot-\(pid).png").path
                let dump = DiagnosticDump.dump(window: win)
                do {
                    let data = try JSONSerialization.data(
                        withJSONObject: dump,
                        options: [.prettyPrinted, .sortedKeys]
                    )
                    try data.write(to: URL(fileURLWithPath: jsonPath))
                } catch {
                    FileHandle.standardError.write(
                        Data("diagnostic dump failed: \(error)\n".utf8))
                }
                let captured = DiagnosticDump.captureWindowToPNG(win, path: pngPath)
                FileHandle.standardError.write(
                    Data("diagnostic → \(jsonPath)\(captured ? " + \(pngPath)" : " (PNG capture failed)")\n".utf8))
            }
        }
        signal(SIGUSR1, SIG_IGN)   // Required so DispatchSource gets it
        src.resume()
        // Retain.
        self.diagnosticSignalSource = src
    }

    /// Runs after the window/AppDelegate have finished launching and the
    /// file is loaded. Waits a couple of run-loop ticks so SwiftUI has a
    /// chance to lay out and the WKWebView (if any) has had a beat to
    /// start loading. Then dumps the realized NSView tree as JSON to
    /// stdout and exits cleanly with code 0 (or 1 on failure).
    private func runDiagnoseAndExit(forceSource: Bool) {
        guard let win = window else {
            FileHandle.standardError.write(Data("diagnose: no window\n".utf8))
            exit(2)
        }
        if forceSource {
            // Programmatically flip to source view before measuring.
            // The model's toggleViewMode is the user-facing path.
            if model.supportsViewModeToggle && model.currentViewMode != .source {
                model.toggleViewMode()
            }
        }
        // Two run-loop ticks: one for SwiftUI to flush layout, one for
        // AppKit to perform display. We've already activated above.
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                let dump = DiagnosticDump.dump(window: win)
                do {
                    let data = try JSONSerialization.data(
                        withJSONObject: dump,
                        options: [.prettyPrinted, .sortedKeys]
                    )
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(
                        Data("diagnose: JSON encode failed: \(error)\n".utf8))
                    exit(1)
                }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "markdownviewer" {
                handleCustomURLScheme(url)
            } else if FileManager.default.fileExists(atPath: url.path) {
                model.openPath(url)
            }
        }
    }

    /// Handle `markdownviewer://` URLs. Supported forms:
    ///   - markdownviewer://open?path=/abs/path/to/file.md
    ///   - markdownviewer://open?path=~/notes/foo.md     (~ expanded)
    ///   - markdownviewer://search?root=/path&q=hello
    /// More verbs can be added as we go; each is a URL host.
    private func handleCustomURLScheme(_ url: URL) {
        guard let host = url.host else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        let q: (String) -> String? = { key in
            items.first(where: { $0.name == key })?.value
        }
        switch host {
        case "open":
            if let raw = q("path") {
                let expanded = (raw as NSString).expandingTildeInPath
                model.openPath(URL(fileURLWithPath: expanded))
            }
        case "search":
            if let root = q("root") {
                let expanded = (root as NSString).expandingTildeInPath
                model.sidebar.setRoot(URL(fileURLWithPath: expanded))
            }
            if let queryStr = q("q") {
                model.crossSearchQuery = queryStr
                model.showCrossSearch()
            }
        default:
            break
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Phase 1: drive a synchronous flush of the active session's
        // snapshot + index + legacy `_last.json` compat bridge.
        // `flushForTermination` drains the SessionStore's serial
        // write queue (design-doc gap #1) so the user's last state
        // is on disk before the process exits.
        sessions.flushForTermination()
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Open file"
        // U12 — narrow to the types we actually handle, with .text as a
        // catch-all umbrella. The user can still hit "All Files" if needed.
        if let markdown = UTType("net.daringfireball.markdown") {
            panel.allowedContentTypes = [markdown, .plainText, .text, .html, .sourceCode]
        } else {
            panel.allowedContentTypes = [.plainText, .text, .html, .sourceCode]
        }
        if panel.runModal() == .OK, let url = panel.url {
            model.open(url: url)
        }
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Open folder"
        if panel.runModal() == .OK, let url = panel.url {
            // Phase 1 routes folder-open through the sessions
            // coordinator: this either reveals an existing same-path
            // session or replaces the single Phase-1 slot. Either
            // way, the wrapped DocumentModel sees `openFolder(url)`
            // via the lifecycle bridge.
            sessions.openFolder(url)
        }
    }

    @objc func openFolderInNewSession(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Open folder in new session"
        if panel.runModal() == .OK, let url = panel.url {
            sessions.openFolder(url, forceNew: true)
        }
    }

    @objc func nextSession(_ sender: Any?)     { sessions.nextSession() }
    @objc func previousSession(_ sender: Any?) { sessions.previousSession() }
    @objc func closeSession(_ sender: Any?)    { sessions.closeActive() }

    /// Jump-to-session menu handler. The Nth item carries `tag = N`
    /// (1-indexed) so we can route ⌃1…⌃9 through one selector.
    @objc func jumpToSession(_ sender: NSMenuItem) {
        let index = sender.tag - 1
        sessions.activate(index: index)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        model.sidebar.toggleVisibility()
    }

    @objc func showPalette(_ sender: Any?) {
        model.showPalette()
    }

    @objc func reloadCurrentFile(_ sender: Any?) {
        model.reloadCurrentFile()
    }

    @objc func toggleViewMode(_ sender: Any?) {
        model.toggleViewMode()
    }

    @objc func newTab(_ sender: Any?) {
        model.newTab()
    }

    @objc func closeCurrentTab(_ sender: Any?) {
        guard model.tabs.selectedIndex != nil else {
            window?.performClose(nil)
            return
        }
        model.closeCurrentTab()
    }

    @objc func nextTab(_ sender: Any?) {
        model.selectNextTab()
    }

    @objc func previousTab(_ sender: Any?) {
        model.selectPreviousTab()
    }

    @objc func selectTabByNumber(_ sender: NSMenuItem) {
        let index = sender.tag - 1
        guard model.tabs.tabs.indices.contains(index) else { return }
        model.selectTab(at: index)
    }

    @objc func moveTabLeft(_ sender: Any?) {
        model.moveCurrentTabLeft()
    }

    @objc func moveTabRight(_ sender: Any?) {
        model.moveCurrentTabRight()
    }

    @objc func openRecentItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        model.openPath(url)  // recents may include folders
    }

    @objc func clearRecents(_ sender: Any?) {
        model.clearRecents()
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === openRecentMenu {
            rebuildRecentsMenu(menu)
        } else if menu === windowMenu {
            rebuildWindowMenu(menu)
        } else if menu === sessionJumpMenu {
            rebuildSessionJumpMenu(menu)
        }
    }

    /// Rebuild the "Jump to Session" submenu. Items 1…9 carry a
    /// ⌃N shortcut so users can jump without opening the menu;
    /// items 10+ have no shortcut but are still clickable. Empty
    /// state is a disabled placeholder so the user gets feedback.
    private func rebuildSessionJumpMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let entries = sessions.core.sessions
        if entries.isEmpty {
            let placeholder = NSMenuItem(
                title: "(no sessions)", action: nil, keyEquivalent: ""
            )
            placeholder.isEnabled = false
            menu.addItem(placeholder)
            return
        }
        for (i, snap) in entries.enumerated() {
            let key = (i < 9) ? "\(i + 1)" : ""
            let title = snap.displayName.isEmpty ? "Untitled" : snap.displayName
            let item = NSMenuItem(
                title: "\(i + 1). \(title)",
                action: #selector(jumpToSession(_:)),
                keyEquivalent: key
            )
            if !key.isEmpty {
                item.keyEquivalentModifierMask = [.control]
            }
            item.tag = i + 1
            item.target = self
            if sessions.core.activeID == snap.id {
                item.state = .on
            }
            menu.addItem(item)
        }
    }

    private func rebuildRecentsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let entries = model.recents.prefix(20)
        if entries.isEmpty {
            let placeholder = NSMenuItem(
                title: "(no recent files)", action: nil, keyEquivalent: ""
            )
            placeholder.isEnabled = false
            menu.addItem(placeholder)
        } else {
            for entry in entries {
                let item = NSMenuItem(
                    title: entry.displayName,
                    action: #selector(openRecentItem(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = entry.url
                item.toolTip = entry.url.path
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(
            title: "Clear Menu",
            action: #selector(clearRecents(_:)),
            keyEquivalent: ""
        )
        clear.target = self
        clear.isEnabled = !model.recents.isEmpty
        menu.addItem(clear)
    }

    private func rebuildWindowMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        // U7 — standard Window items the HIG expects.
        let minimizeItem = NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        menu.addItem(minimizeItem)
        let zoomWinItem = NSMenuItem(
            title: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        menu.addItem(zoomWinItem)
        menu.addItem(.separator())
        let bringAll = NSMenuItem(
            title: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        menu.addItem(bringAll)
        menu.addItem(.separator())

        let nextItem = NSMenuItem(
            title: "Next Tab",
            action: #selector(nextTab(_:)),
            keyEquivalent: "\u{2192}"
        )
        nextItem.keyEquivalentModifierMask = [.command, .option]
        nextItem.target = self
        menu.addItem(nextItem)

        let prevItem = NSMenuItem(
            title: "Previous Tab",
            action: #selector(previousTab(_:)),
            keyEquivalent: "\u{2190}"
        )
        prevItem.keyEquivalentModifierMask = [.command, .option]
        prevItem.target = self
        menu.addItem(prevItem)

        menu.addItem(.separator())
        let moveLeft = NSMenuItem(
            title: "Move Tab Left",
            action: #selector(moveTabLeft(_:)),
            keyEquivalent: "["
        )
        moveLeft.keyEquivalentModifierMask = [.command, .option]
        moveLeft.target = self
        menu.addItem(moveLeft)
        let moveRight = NSMenuItem(
            title: "Move Tab Right",
            action: #selector(moveTabRight(_:)),
            keyEquivalent: "]"
        )
        moveRight.keyEquivalentModifierMask = [.command, .option]
        moveRight.target = self
        menu.addItem(moveRight)

        if model.tabs.tabs.isEmpty {
            menu.addItem(.separator())
            let placeholder = NSMenuItem(title: "(no open tabs)", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
            return
        }

        menu.addItem(.separator())
        for (i, tab) in model.tabs.tabs.enumerated() {
            let key = i < 9 ? "\(i + 1)" : ""
            let item = NSMenuItem(
                title: tab.title.isEmpty ? "Untitled" : tab.title,
                action: #selector(selectTabByNumber(_:)),
                keyEquivalent: key
            )
            item.tag = i + 1
            item.target = self
            if model.tabs.selectedIndex == i {
                item.state = .on
            }
            menu.addItem(item)
        }
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "About TextView",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())
        // Settings… stub. There's no preferences UI yet; the item is
        // disabled but present so users with muscle-memory Cmd+, don't
        // get a beep, and macOS HIG expects this slot. When we add a
        // settings window, just wire the action.
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Hide TextView",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        ))
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(
            title: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Quit TextView",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let newTabItem = NSMenuItem(
            title: "New Tab",
            action: #selector(newTab(_:)),
            keyEquivalent: "t"
        )
        newTabItem.target = self
        fileMenu.addItem(newTabItem)

        let openItem = NSMenuItem(
            title: "Open…",
            action: #selector(openDocument(_:)),
            keyEquivalent: "o"
        )
        openItem.target = self
        fileMenu.addItem(openItem)

        let openFolderItem = NSMenuItem(
            title: "Open Folder…",
            action: #selector(openFolder(_:)),
            keyEquivalent: "o"
        )
        openFolderItem.keyEquivalentModifierMask = [.command, .shift]
        openFolderItem.target = self
        fileMenu.addItem(openFolderItem)

        let recentItem = NSMenuItem(
            title: "Open Recent", action: nil, keyEquivalent: ""
        )
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        recentMenu.autoenablesItems = false
        recentItem.submenu = recentMenu
        openRecentMenu = recentMenu
        fileMenu.addItem(recentItem)

        fileMenu.addItem(.separator())

        let closeTabItem = NSMenuItem(
            title: "Close Tab",
            action: #selector(closeCurrentTab(_:)),
            keyEquivalent: "w"
        )
        closeTabItem.target = self
        fileMenu.addItem(closeTabItem)
        fileMenuItem.submenu = fileMenu

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let toggleItem = NSMenuItem(
            title: "Toggle Rendered / Source",
            action: #selector(toggleViewMode(_:)),
            keyEquivalent: "r"
        )
        toggleItem.keyEquivalentModifierMask = [.command, .shift]
        toggleItem.target = self
        viewMenu.addItem(toggleItem)

        let sidebarItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(toggleSidebar(_:)),
            keyEquivalent: "s"
        )
        sidebarItem.keyEquivalentModifierMask = [.command, .control]
        sidebarItem.target = self
        viewMenu.addItem(sidebarItem)

        let wrapItem = NSMenuItem(
            title: "Wrap Long Lines",
            action: #selector(toggleSourceWordWrap(_:)),
            keyEquivalent: "w"
        )
        wrapItem.keyEquivalentModifierMask = [.command, .option]
        wrapItem.target = self
        viewMenu.addItem(wrapItem)

        viewMenu.addItem(.separator())
        let reloadItem = NSMenuItem(
            title: "Reload",
            action: #selector(reloadCurrentFile(_:)),
            keyEquivalent: "r"
        )
        reloadItem.target = self
        viewMenu.addItem(reloadItem)

        let paletteItem = NSMenuItem(
            title: "Quick Open…",
            action: #selector(showPalette(_:)),
            keyEquivalent: "k"
        )
        paletteItem.target = self
        viewMenu.addItem(paletteItem)

        // U7 — Zoom items for the rendered view.
        viewMenu.addItem(.separator())
        // HIG: Zoom In is Cmd+= (literal =, not shifted +). Using "+"
        // here was equivalent to Cmd+Shift+= on US keyboards, which is
        // the wrong default. Add a Cmd+Shift+= alias for compatibility
        // with apps that DO use "+" — it's the same physical keystroke
        // for the user but covered by both shortcut variants.
        // Cmd+= is the canonical zoom-in shortcut on macOS (matches
        // Safari, Xcode, etc.). The hidden Cmd+Shift+= alternate that
        // used to live here surfaced as a duplicate visible entry on
        // current macOS; dropped it. Users get Cmd++ for free because
        // = and + are the same physical key.
        let zoomIn = NSMenuItem(title: "Zoom In",
                                action: #selector(zoomIn(_:)),
                                keyEquivalent: "=")
        zoomIn.target = self
        viewMenu.addItem(zoomIn)
        let zoomOut = NSMenuItem(title: "Zoom Out",
                                 action: #selector(zoomOut(_:)),
                                 keyEquivalent: "-")
        zoomOut.target = self
        viewMenu.addItem(zoomOut)
        let zoomReset = NSMenuItem(title: "Actual Size",
                                   action: #selector(zoomReset(_:)),
                                   keyEquivalent: "0")
        zoomReset.target = self
        viewMenu.addItem(zoomReset)

        viewMenu.addItem(.separator())
        let formatItem = NSMenuItem(
            title: "Pretty-Print",
            action: #selector(toggleFormat(_:)),
            keyEquivalent: "f"
        )
        formatItem.keyEquivalentModifierMask = [.command, .option]
        formatItem.target = self
        viewMenu.addItem(formatItem)

        let jqItem = NSMenuItem(
            title: "Apply jq Filter…",
            action: #selector(applyJQFilter(_:)),
            keyEquivalent: "j"
        )
        jqItem.keyEquivalentModifierMask = [.command, .option]
        jqItem.target = self
        viewMenu.addItem(jqItem)

        let bookmarkItem = NSMenuItem(
            title: "Bookmark / Unbookmark Current",
            action: #selector(toggleBookmark(_:)),
            keyEquivalent: "d"
        )
        bookmarkItem.target = self
        viewMenu.addItem(bookmarkItem)

        let bookmarkLineItem = NSMenuItem(
            title: "Bookmark / Unbookmark Current Line",
            action: #selector(toggleLineBookmark(_:)),
            keyEquivalent: "d"
        )
        bookmarkLineItem.keyEquivalentModifierMask = [.command, .option]
        bookmarkLineItem.target = self
        viewMenu.addItem(bookmarkLineItem)

        // Split view (Phase 2.5).
        viewMenu.addItem(.separator())
        let splitItem = NSMenuItem(
            title: "Toggle Split",
            action: #selector(toggleSplit(_:)),
            keyEquivalent: "\\"
        )
        splitItem.target = self
        viewMenu.addItem(splitItem)

        let swapItem = NSMenuItem(
            title: "Swap Split Panes",
            action: #selector(swapSplit(_:)),
            keyEquivalent: "\\"
        )
        swapItem.keyEquivalentModifierMask = [.command, .shift]
        swapItem.target = self
        viewMenu.addItem(swapItem)

        viewMenu.addItem(.separator())
        // Git surface — these all focus the sidebar Git panel and
        // select the appropriate tab. Discoverable from the menu bar.
        let showGitPanelItem = NSMenuItem(
            title: "Show Git Panel",
            action: #selector(showGitPanel(_:)),
            keyEquivalent: "B"
        )
        showGitPanelItem.keyEquivalentModifierMask = [.command, .option]
        showGitPanelItem.target = self
        viewMenu.addItem(showGitPanelItem)

        let historyItem = NSMenuItem(
            title: "Show File History",
            action: #selector(showFileHistory(_:)),
            keyEquivalent: ""
        )
        historyItem.target = self
        viewMenu.addItem(historyItem)

        let repoHistoryItem = NSMenuItem(
            title: "Show Repository History",
            action: #selector(showRepoHistory(_:)),
            keyEquivalent: ""
        )
        repoHistoryItem.target = self
        viewMenu.addItem(repoHistoryItem)

        viewMenuItem.submenu = viewMenu

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.delegate = self
        windowMenu.autoenablesItems = false
        self.windowMenu = windowMenu
        // Items are populated lazily in rebuildWindowMenu() via menuNeedsUpdate.
        windowMenuItem.submenu = windowMenu

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Copy",
            action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Select All",
            action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())

        // U7 — Find / Find Next / Find Previous. The system routes these to
        // the first responder; NSTextView with usesFindBar=true handles them
        // natively in source mode. WKWebView (rendered mode) handling is the
        // unfinished Phase 4.5 UI.
        let findSubmenuItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findSubmenu = NSMenu(title: "Find")
        // Cmd+F: routes to NSTextView's find bar when source view is
        // first-responder; falls back to our SwiftUI find bar in
        // rendered (WKWebView) mode.
        let findItem = NSMenuItem(
            title: "Find…",
            action: #selector(findInPage(_:)),
            keyEquivalent: "f"
        )
        findItem.target = self
        findSubmenu.addItem(findItem)

        // Cmd+Shift+F: cross-file search across the open folder.
        let findInFolderItem = NSMenuItem(
            title: "Find in Folder…",
            action: #selector(showCrossSearch(_:)),
            keyEquivalent: "f"
        )
        findInFolderItem.keyEquivalentModifierMask = [.command, .shift]
        findInFolderItem.target = self
        findSubmenu.addItem(findInFolderItem)
        let findNext = NSMenuItem(
            title: "Find Next",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: "g"
        )
        findNext.tag = NSTextFinder.Action.nextMatch.rawValue
        findSubmenu.addItem(findNext)
        let findPrev = NSMenuItem(
            title: "Find Previous",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: "g"
        )
        findPrev.keyEquivalentModifierMask = [.command, .shift]
        findPrev.tag = NSTextFinder.Action.previousMatch.rawValue
        findSubmenu.addItem(findPrev)
        findSubmenuItem.submenu = findSubmenu
        editMenu.addItem(findSubmenuItem)
        editMenuItem.submenu = editMenu

        // U7 — Help menu (HIG: every Mac app should have one, with the
        // searchable Help item provided by AppKit).
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let helpItem = NSMenuItem(
            title: "TextView Help",
            action: #selector(NSApplication.showHelp(_:)),
            keyEquivalent: "?"
        )
        helpMenu.addItem(helpItem)
        helpMenuItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        // Session menu — Phase 1 ships a minimal version (New / Close
        // / Next / Previous / Jump-to-N). Per SESSIONS_DESIGN.md §7.2.
        let sessionMenuItem = buildSessionMenu()

        // HIG order: App, File, Edit, View, Session, Window, Help.
        // Session sits between View and Window so it's discoverable
        // next to "Tabs" mental model. (App was added at the top.)
        mainMenu.addItem(fileMenuItem)
        mainMenu.addItem(editMenuItem)
        mainMenu.addItem(viewMenuItem)
        mainMenu.addItem(sessionMenuItem)
        mainMenu.addItem(windowMenuItem)
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
    }

    /// Build the Session menu. The "Jump to Session" submenu is
    /// populated on demand via `menuNeedsUpdate` (NSMenuDelegate) so
    /// it reflects the current `sessions.core.sessions` ordering
    /// without us having to subscribe to coordinator changes.
    private func buildSessionMenu() -> NSMenuItem {
        let sessionMenuItem = NSMenuItem()
        let menu = NSMenu(title: "Session")

        let newItem = NSMenuItem(
            title: "New Session…",
            action: #selector(openFolderInNewSession(_:)),
            keyEquivalent: "n"
        )
        // ⇧⌘N — distinct from File→New Tab (⌘T) and from ⌘N which
        // is unbound today (would conflict if we ever add it for
        // "New Tab" the HIG-standard way).
        newItem.keyEquivalentModifierMask = [.command, .shift]
        newItem.target = self
        menu.addItem(newItem)

        menu.addItem(.separator())

        let nextItem = NSMenuItem(
            title: "Next Session",
            action: #selector(nextSession(_:)),
            // \u{0009} is TAB. Combined with .control this is ⌃⇥
            // (one of the two macOS-conventional next-pane combos —
            // VS Code uses it too).
            keyEquivalent: "\t"
        )
        nextItem.keyEquivalentModifierMask = [.control]
        nextItem.target = self
        menu.addItem(nextItem)

        let prevItem = NSMenuItem(
            title: "Previous Session",
            action: #selector(previousSession(_:)),
            keyEquivalent: "\t"
        )
        prevItem.keyEquivalentModifierMask = [.control, .shift]
        prevItem.target = self
        menu.addItem(prevItem)

        let jumpItem = NSMenuItem(
            title: "Jump to Session", action: nil, keyEquivalent: ""
        )
        let jumpMenu = NSMenu(title: "Jump to Session")
        jumpMenu.delegate = self
        jumpMenu.autoenablesItems = false
        jumpItem.submenu = jumpMenu
        self.sessionJumpMenu = jumpMenu
        // ⌃1…⌃9 hidden top-level shortcuts. Wire them on the parent
        // menu so the system honors the key equivalent even when
        // the Jump submenu isn't open. NSMenuItem.isAlternate=false
        // + isHidden=true keeps them out of the visible UI.
        for n in 1...9 {
            let hidden = NSMenuItem(
                title: "Jump to Session \(n)",
                action: #selector(jumpToSession(_:)),
                keyEquivalent: "\(n)"
            )
            hidden.keyEquivalentModifierMask = [.control]
            hidden.target = self
            hidden.tag = n
            hidden.isHidden = true
            menu.addItem(hidden)
        }
        menu.addItem(jumpItem)

        menu.addItem(.separator())

        let closeItem = NSMenuItem(
            title: "Close Session",
            action: #selector(closeSession(_:)),
            keyEquivalent: "w"
        )
        closeItem.keyEquivalentModifierMask = [.command, .shift]
        closeItem.target = self
        menu.addItem(closeItem)

        sessionMenuItem.submenu = menu
        return sessionMenuItem
    }

    @objc func zoomIn(_ sender: Any?) {
        model.zoomIn()
    }

    @objc func zoomOut(_ sender: Any?) {
        model.zoomOut()
    }

    @objc func zoomReset(_ sender: Any?) {
        model.zoomReset()
    }

    @objc func toggleFormat(_ sender: Any?) {
        model.toggleFormat()
    }

    /// Apply jq Filter… — prompts for a filter expression, runs jq
    /// over the current document, and opens the output as a new
    /// `.json` tab. Disabled when jq isn't on disk or the current
    /// file isn't a text file we can pipe in.
    @objc func applyJQFilter(_ sender: Any?) {
        guard JQRunner.isAvailable else {
            let alert = NSAlert()
            alert.messageText = "jq is not installed"
            alert.informativeText = "Install with `brew install jq` or upgrade macOS to 15.x (ships jq at /usr/bin/jq)."
            alert.runModal()
            return
        }
        guard case let .loaded(file) = model.currentState else { return }

        let prompt = NSAlert()
        prompt.messageText = "Apply jq filter"
        prompt.informativeText = "Pipes the current document through `jq <filter>` and opens the result in a new tab. Example: `.users[] | select(.active)`"
        let input = NSTextField(string: ".")
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 22)
        input.placeholderString = "."
        prompt.accessoryView = input
        prompt.addButton(withTitle: "Apply")
        prompt.addButton(withTitle: "Cancel")
        let resp = prompt.runModal()
        guard resp == .alertFirstButtonReturn else { return }
        let filter = input.stringValue.isEmpty ? "." : input.stringValue

        do {
            let out = try JQRunner.run(filter: filter, json: file.contents)
            // Write to caches dir and open as a new tab. Hashed name
            // so distinct filter results don't collide on disk.
            let cache = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let dir = cache.appendingPathComponent("MarkdownViewer/jq", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var hasher = Hasher()
            hasher.combine(file.url.path)
            hasher.combine(filter)
            let hashHex = String(UInt(bitPattern: hasher.finalize()), radix: 16)
                .padding(toLength: 8, withPad: "0", startingAt: 0)
                .prefix(8)
            let base = file.url.deletingPathExtension().lastPathComponent
            let outURL = dir.appendingPathComponent("\(base)-\(hashHex).json")
            try out.write(to: outURL, atomically: true, encoding: .utf8)
            model.openInNewTab(outURL)
        } catch let err as JQRunner.Error {
            let alert = NSAlert()
            alert.messageText = "jq filter failed"
            alert.informativeText = err.description
            alert.alertStyle = .warning
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "jq filter failed"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    @objc func toggleSourceWordWrap(_ sender: Any?) {
        model.toggleSourceWordWrap()
    }

    private let settingsWindowController = SettingsWindowController()
    @objc func showSettings(_ sender: Any?) {
        settingsWindowController.show(model: model)
    }

    /// Menu validation: gray-out items that don't apply to the current
    /// state. macOS calls this every time a menu opens (and for items
    /// with key equivalents, on the keystroke too).
    ///
    /// Convention: items whose action is on the AppDelegate go through
    /// here. System actions (NSApplication.hide:, NSWindow.miniaturize:)
    /// are handled by AppKit and don't route through us.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasFile = model.currentURL != nil
        let hasTab  = model.tabs.selected != nil
        switch item.action {
        case #selector(toggleViewMode(_:)):
            // Rendered/Source toggle only meaningful for markdown.
            item.title = (model.currentViewMode == .source) ? "Show Rendered" : "Show Source"
            return model.supportsViewModeToggle
        case #selector(toggleFormat(_:)):
            // Format only when the current file has a registered formatter.
            item.state = model.isCurrentTabFormatted ? .on : .off
            return model.supportsFormatToggle
        case #selector(toggleSourceWordWrap(_:)):
            item.state = model.sourceWordWrap ? .on : .off
            return hasFile
        case #selector(toggleBookmark(_:)):
            item.title = model.isCurrentTabBookmarked
                ? "Remove Bookmark"
                : "Bookmark This"
            return model.bookmarkTargetURL != nil
        case #selector(reloadCurrentFile(_:)),
             #selector(findInPage(_:)),
             #selector(closeCurrentTab(_:)),
             #selector(nextTab(_:)),
             #selector(previousTab(_:)),
             #selector(moveTabLeft(_:)),
             #selector(moveTabRight(_:)),
             #selector(zoomIn(_:)),
             #selector(zoomOut(_:)),
             #selector(zoomReset(_:)):
            // All of these need an active tab / file.
            return hasTab
        case #selector(toggleSidebar(_:)):
            item.state = model.sidebar.isVisible ? .on : .off
            return true
        default:
            return true
        }
    }

    @objc func toggleLineBookmark(_ sender: Any?) {
        model.toggleCurrentLineBookmark()
    }

    @objc func toggleSplit(_ sender: Any?) {
        model.toggleSplit()
    }

    @objc func swapSplit(_ sender: Any?) {
        model.swapSplit()
    }

    /// Show Git Panel — focuses the sidebar's GIT section (expanding
    /// it if collapsed) and selects the Status tab. The user can then
    /// click through to Log / Stash / Trees / Remotes.
    @objc func showGitPanel(_ sender: Any?) {
        model.showGitPanel(tab: .status)
    }

    /// Show File History — opens the Git panel on the Log tab.
    /// Per-file path scoping is a follow-up (the panel doesn't yet
    /// accept a path filter; today this shows full repo log).
    @objc func showFileHistory(_ sender: Any?) {
        model.showGitPanel(tab: .log)
    }

    /// Show Repository History — opens the Git panel on the Log tab.
    @objc func showRepoHistory(_ sender: Any?) {
        model.showGitPanel(tab: .log)
    }

    @objc func toggleBookmark(_ sender: Any?) {
        model.toggleCurrentTabBookmark()
    }

    @objc func showCrossSearch(_ sender: Any?) {
        model.showCrossSearch()
    }

    /// Cmd+F router. Picks the right find bar based on the current
    /// view mode. Both bars use our custom SwiftUI implementation —
    /// the source mode uses NSTextView for selection / scrolling but
    /// we still wrap our own bar around it so the UX matches.
    @objc func findInPage(_ sender: Any?) {
        // Rendered markdown — only meaningful when the file is markdown
        // and the user is viewing the rendered side.
        if model.supportsViewModeToggle, model.currentViewMode == .rendered {
            model.showRenderedFindBar()
            return
        }
        // Otherwise the user is on the source/text side: open the
        // source find bar (works for source view, plaintext, code, etc.).
        model.showSourceFindBar()
    }

    // MARK: - NSServices (Finder Quick Action equivalent)

    /// Hook the delegate up as the system services provider. With this
    /// + the NSServices declaration in Info.plist, macOS surfaces our
    /// "Open in TextView" entry in Finder's right-click → Services menu
    /// (and in the Services menu on every app). No bundled .workflow,
    /// no `pluginkit` dance.
    func registerAsServicesProvider() {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    /// Handler the system calls when the user picks "Open in TextView"
    /// for a file/folder selection. The pasteboard carries one or more
    /// file URLs; we open each as a tab/folder.
    @objc func openInTextView(_ pboard: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "No files in selection." as NSString
            return
        }
        // Filter to file URLs only — `NSURL` accepts http(s) etc. and we
        // don't want a service-router pivot to web content.
        let fileURLs = urls.filter { $0.isFileURL }
        for url in fileURLs {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    // Route folder opens through the sessions
                    // coordinator so the session identity updates.
                    sessions.openFolder(url)
                } else {
                    model.openPath(url)
                }
            }
        }
        // Window may not exist if the service fires before
        // applicationDidFinishLaunching settles — defer in that case
        // rather than crash. macOS will deliver the focus once the
        // window appears via the normal foreground activation path.
        if let w = window {
            showWindow(w)
        }
    }
}

extension AppDelegate {
    /// Spin up the MCP stdio server. Routes log lines to stderr (NEVER
    /// stdout — stdout is reserved for framed protocol bytes; any
    /// stray byte would desync the client's framing parser).
    @MainActor
    fileprivate func startMCPServer() {
        let server = MCPServer(
            host: model,
            input: .standardInput,
            output: .standardOutput,
            logger: { line in
                FileHandle.standardError.write(Data("mcp: \(line)\n".utf8))
            }
        )
        server.start()
        self.mcpServer = server
        // Tell stderr we're up so clients with a verbose mode can
        // confirm the server actually launched. Stdout stays silent
        // until a framed response.
        FileHandle.standardError.write(Data("mcp: server ready on stdio\n".utf8))
    }
}

/// Bring `window` to the front. In normal mode, also takes key/focus.
/// In MDV_BACKGROUND=1 mode, uses `orderFrontRegardless` so the window
/// appears but does NOT steal keyboard focus from whatever the user
/// has in front of them.
@MainActor
func showWindow(_ window: NSWindow) {
    if ProcessInfo.processInfo.environment["MDV_BACKGROUND"] == "1" {
        window.orderFrontRegardless()
    } else {
        window.makeKeyAndOrderFront(nil)
    }
}

/// Call `NSApp.activate(ignoringOtherApps: true)` only in normal mode.
/// In MDV_BACKGROUND=1 we skip activation entirely so the app stays in
/// the background and the user's foreground app retains focus.
@MainActor
func activateIfForeground() {
    guard ProcessInfo.processInfo.environment["MDV_BACKGROUND"] != "1" else { return }
    NSApp.activate(ignoringOtherApps: true)
}

let app = NSApplication.shared

/// `--mcp-stdio` puts the process in headless RPC mode: no Dock icon,
/// no menu bar, no windows. We still need to call `app.run()` because
/// `@MainActor`-isolated DocumentModel state can only be mutated from
/// the main thread's run loop, which `NSApp.run` services.
let mcpStdioMode = CommandLine.arguments.contains("--mcp-stdio")

/// `MDV_BACKGROUND=1` flips the app into accessory mode: window can
/// show but won't become key (no keyboard-focus theft) and the app
/// doesn't get a Dock tile. Used by the test harness so a suite running
/// in the background doesn't capture the user's keystrokes mid-typing.
/// In normal interactive launches this env var is unset → `.regular`
/// behavior unchanged.
let backgroundMode = ProcessInfo.processInfo.environment["MDV_BACKGROUND"] == "1"
let policy: NSApplication.ActivationPolicy = {
    if mcpStdioMode { return .prohibited }   // no Dock, no menu bar
    if backgroundMode { return .accessory }
    return .regular
}()
app.setActivationPolicy(policy)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
