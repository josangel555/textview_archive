import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import RustCore
import ViewerCore
import ViewerUI
import ViewerKit
import WebKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation, AppMenuActions {
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
    /// Auxiliary tool windows (WAVE 2b items 4 + 5). Retained so a second
    /// menu invocation re-focuses the existing window instead of spawning
    /// duplicates; `isReleasedWhenClosed = false` keeps them alive across
    /// close/reopen.
    private var diagnosticWindow: NSWindow?
    private var instrumentationWindow: NSWindow?
    /// The process-wide observability ring buffer (WAVE 2b item 5).
    /// Installed into `Obs` at launch so emitters across ViewerCore land
    /// in it; the same instance backs the instrumentation tool window's
    /// `ObservabilityProjection`, so the Logs/Metrics views show real
    /// events. Retained here for the projection's lifetime.
    private let observabilitySink = RingBufferSink()
    private var cancellables: Set<AnyCancellable> = []
    /// Retained DispatchSource for the SIGUSR1 diagnostic-dump trap.
    /// Set by `installDiagnosticSignalHandler` (Diagnostics.swift).
    /// `internal` (default) so the extension in Diagnostics.swift can
    /// write it; private here would scope it to this file only.
    var diagnosticSignalSource: DispatchSourceSignal?
    private var mcpServer: MCPServer?
    /// Captured at hosting-controller construction so the
    /// `--walkthrough PATH` flag can start playback against the
    /// SwiftUI-owned controller without rebuilding the view body.
    fileprivate var walkthroughController: WalkthroughPlayerController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // TSK-636: core-call auditing at the transport seam. FAILURES only —
        // successes are routine and high-volume (fuzzy ranks per palette
        // keystroke); a failing/panicking core is the security signal.
        CoreTransportRegistry.auditHook = { method, transport, ok in
            guard !ok else { return }
            AuditLog.shared.record(
                .coreCall, action: "error", target: method,
                meta: ["transport": transport])
        }
        // TSK-665: MDV_REMOTE_SOCKET attaches the remote core (ssh-forwarded
        // mdv-serve). Fail-safe — any failure stays in-process; a connection
        // lost later auto-reverts. Must run AFTER the audit hook (attach
        // outcomes are observable) and BEFORE any engine use.
        RemoteCoreAttach.attachIfConfigured()
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

        // `--claude-monitor`: open ONLY the standalone read-only Claude
        // session monitor PoC, hosted in its own window. Deliberately
        // bypasses the entire document UI (no ContentView, no menu wiring,
        // no sessions bootstrap) so the PoC is independently launchable and
        // screenshot-validatable, and so it can never perturb the main app
        // surface. Read-only over `~/.claude/projects/*/*.jsonl`.
        if claudeMonitorMode {
            openClaudeMonitorWindow()
            return
        }

        // Opt out of macOS's automatic window tabbing — we ship our own in-app
        // tab bar; the system "Show Tab Bar" menu item is confusing here.
        NSWindow.allowsAutomaticWindowTabbing = false

        // WAVE 2b item 5: install the process-wide observability ring
        // buffer so emitters across ViewerCore (LSP, grammar loader, MCP)
        // land in it and the instrumentation tool window has real data.
        // `installIfNeeded` won't clobber a test-installed capturing sink.
        Obs.installIfNeeded { self.observabilitySink }

        buildMenu()
        registerAsServicesProvider()

        // Wire LSP server-push notifications (publishDiagnostics →
        // sidebar Problems panel). Idempotent; safe to call multiple
        // times. Must run before any LSP client spawns so the callback
        // is in place when the first server reports diagnostics.
        model.bootstrapLSP()
        // CONC-001/CR-01/RC-2: start the pool's idle-reaper. Without this
        // spawned LSP servers were never reaped on idle, leaking server
        // subprocesses for the lifetime of the app. `start()` is an actor
        // method and idempotent; we fire-and-forget into the actor since
        // app launch must not block on it.
        Task { await model.lspPool.start() }

        // TSK-619: precompile TreeSitter highlight queries off-main.
        // The first tokenize of a language pays a multi-hundred-ms
        // Query compile, and the HTMLRenderer code-fence path runs it
        // SYNCHRONOUSLY on the main actor — an unwarmed first MD open
        // stalls main for the whole compile (measured ~400ms debug).
        // Warming every grammar at utility priority finishes well
        // before a human reaches their first file; a racing open only
        // waits out the remainder of the one compile it needs.
        Task.detached(priority: .utility) {
            TreeSitterEngine.shared.warm(HighlightLanguage.allCases)
        }

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
        // ContentView's body state. F-WCR-STRIP: read it off the MODEL,
        // not `rootView` — `rootView.walkthroughController` would touch a
        // `@StateObject` on a not-yet-installed view struct, which need
        // not return the instance SwiftUI later binds into `body`. The
        // model-owned singleton (which the `@StateObject` is seeded from)
        // IS that instance, so `start(_:)` flips `isActive` on the object
        // `body` observes and the docked transport strip mounts.
        self.walkthroughController = model.walkthroughController
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
        if PristineChrome.isActive {
            // TSK-618: harness spawns must get the deterministic default
            // frame — no restore from, and no save to, the shared
            // `NSWindow Frame MainWindow` key (AppKit persists frames to
            // .standard regardless of our own stores).
            window.center()
        } else {
            _ = window.setFrameAutosaveName(autosaveName)
            if UserDefaults.standard.string(forKey: savedFrameKey) == nil {
                window.center()
            }
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
        // path is the run-scoped artifact dir (#193: per-test when
        // `MDV_ARTIFACT_DIR` is set, else per-user tmp + bundle
        // identifier so multiple users / Mac windows don't collide).
        if let identifier = Bundle.main.bundleIdentifier {
            let url = ArtifactDir.url
                .appendingPathComponent("\(identifier).windowid")
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

        // Sessions: subsumes the old `restorePreviousFolderIfAvailable()`
        // + `restoreWorkspaceAutoSlot()` pair — the sessions coordinator
        // reads `Sessions/index.json` and hydrates the shared `model`
        // from the active session's snapshot. The legacy
        // `Workspaces/_last.json` migration path was retired in
        // decision G (2026-05-25); a downgrade now loses persisted
        // tabs.
        // SFB-10: wire the session lifecycle bridge UNCONDITIONALLY. The
        // bridge is what lets a later `session-open-new` / `activate` re-root
        // the live sidebar (via SessionState.hydrate → sidebar.setRoot). Only
        // the disk-restore step is gated by MDV_SKIP_WORKSPACE_RESTORE — we
        // skip rehydrating the user's last session for test/automation
        // launches, but the machinery for opening new sessions must stay live.
        sessions.wireLifecycle()
        if ProcessInfo.processInfo.environment["MDV_SKIP_WORKSPACE_RESTORE"] != "1" {
            sessions.bootstrap()
        }
        // One-way callback: folder context menus invoke this to spawn a
        // new session via the coordinator without DocumentModel needing
        // to import SessionsAppCoordinator.
        model.openFolderInNewSession = { [weak self] url in
            self?.sessions.openFolder(url, forceNew: true)
        }
        // UX-M (#232): give the model a weak handle to the sessions
        // coordinator so palette-invoked commands can dispatch the
        // session/sidebar verbs through `ScriptVerb.apply(verb:to:sessions:)`
        // — the same pure dispatch surface the --script runner uses. weak,
        // so no retain cycle (the coordinator owns the model). Warming
        // `commandRegistry` here also forces the one-time
        // `~/.textview/keybinding.json` load at launch (off the test path).
        model.sessionsCoordinator = sessions
        _ = model.commandRegistry

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
        // TSK-620: LaunchServices-launched harness runs (`open -a … --env`)
        // carry the script + file via ENVIRONMENT because LS drops
        // `--`-prefixed argv. An LS launch is the only way a harness app
        // can genuinely self-activate on macOS 14+ (fork/exec'd processes
        // are denied cooperative activation), and real activation is what
        // synthesized SwiftUI clicks require. argv wins when both are set.
        let environment = ProcessInfo.processInfo.environment
        if scriptPath == nil, let envScript = environment["MDV_SCRIPT_PATH"] {
            scriptPath = envScript
        }
        if pathArgs.isEmpty, let envFile = environment["MDV_OPEN_FILE"] {
            pathArgs.append(envFile)
        }
        // CORR-10: open EVERY positional path, not just the first. The
        // first opens via `openPath` (reuses/replaces the initial blank
        // tab and detects folder-vs-file); subsequent paths each get
        // their own tab via `openInNewTab` so multi-file launches
        // (`open -a TextView a.md b.md c.json`, drag-drop of several
        // files onto the Dock icon) land all of them. Each path is
        // guarded by `fileExists` independently so one bad path doesn't
        // skip the rest.
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var openedFirst = false
        for path in pathArgs {
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded, relativeTo: cwd)
                .standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if !openedFirst {
                model.openPath(url)   // handles folder vs file
                openedFirst = true
            } else {
                // `openInNewTab` is file-oriented; route directories
                // through `openPath` so a folder arg still opens its
                // sidebar instead of being treated as a file tab.
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                   isDir.boolValue {
                    model.openPath(url)
                } else {
                    model.openInNewTab(url)
                }
            }
        }

        activateIfForeground()

        installDiagnosticSignalHandler()

        // Deterministic UI-scene control for the visual-test harness (TSK-492).
        applyUISceneIfRequested()

        if diagnoseMode {
            // TSK-493: MDV_DIAGNOSE_DELAY sequences the dump AFTER an
            // MDV_UI_SCENE apply (scene delay default 0.6s) — without it
            // the dump fires two run-loop ticks after launch and can never
            // capture a scene-driven state.
            let delay = DiagnoseSchedule.delay(
                ProcessInfo.processInfo.environment["MDV_DIAGNOSE_DELAY"])
            if delay > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.runDiagnoseAndExit(forceSource: forceSource)
                }
            } else {
                runDiagnoseAndExit(forceSource: forceSource)
            }
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

    // runScript / runScriptStep / captureStepArtifacts → ScriptRunner.swift
    // installDiagnosticSignalHandler / scheduleAutoSnapshot /
    // runDiagnoseAndExit → Diagnostics.swift
    // (Both extracted in Quality #I, 2026-05-25. Pure code-motion.)

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "markdownviewer" {
                handleCustomURLScheme(url)
            } else if url.isFileURL,
                      FileManager.default.fileExists(atPath: url.path) {
                // S6.5 — only honor `file://` URLs from the fallthrough.
                // Without `isFileURL`, an `https://example.com/etc/passwd`
                // URL would land here, `url.path` would be `/etc/passwd`,
                // and `fileExists` would happily say "yes" if that
                // path happened to exist. Defense-in-depth even though
                // Launch Services normally only routes file URLs here.
                model.openPath(url)
            }
        }
    }

    /// Handle `markdownviewer://` URLs. Supported forms:
    ///   - markdownviewer://open?path=/abs/path/to/file.md
    ///   - markdownviewer://open?path=~/notes/foo.md     (~ expanded)
    ///   - markdownviewer://search?root=/path&q=hello
    ///   - markdownviewer://walkthrough?path=~/walks/demo.json  (TSK-317;
    ///     prompts before starting — a walkthrough drives UI automation)
    /// Parsing + the S1.1 containedPath hardening live in
    /// `URLSchemeRouter` (ViewerCore) so every verb is headless-tested;
    /// this delegate only dispatches the typed route.
    private func handleCustomURLScheme(_ url: URL) {
        switch URLSchemeRouter.route(url) {
        case .open(let safeURL):
            model.openPath(safeURL)
        case .search(let root, let query):
            if let root { model.sidebar.setRoot(root) }
            if let query {
                model.crossSearchQuery = query
                model.showCrossSearch()
            }
        case .walkthrough(let safeURL):
            // CONFIRMATION GATE (TSK-317): unlike open/search, a
            // walkthrough EXECUTES UI automation. A drive-by web link
            // must not auto-drive the app — the user approves first.
            // (The local --walkthrough CLI flag stays unprompted.)
            let alert = NSAlert()
            alert.messageText = "Start walkthrough?"
            alert.informativeText =
                "A link wants to run the walkthrough “\(safeURL.lastPathComponent)”. "
                + "Walkthroughs control the app's interface while they play."
            alert.addButton(withTitle: "Run Walkthrough")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            startWalkthrough(at: safeURL.path)
        case nil:
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

        // P2: drain the JSONFileStore write queue (history / bookmarks /
        // go-to-path). Those `save()`s now enqueue off-main + coalesced, so
        // the very last mutation before quit might still be in flight; this
        // blocks until it's on disk. Mirrors the SessionStore flush above.
        JSONFileStore.flushSync()

        // #226: hang up + reap the terminal shell so it doesn't get
        // reparented to launchd on quit. No-op if a terminal was never
        // opened (the shell spawns lazily on first open).
        model.terminalPane.shutdown()

        // RC-5: shut down every live LSP server before the process exits.
        // Without this, `terminate()` tore the host down while child LSP
        // servers (sourcekit-lsp, etc.) were still running — they'd be
        // reparented to launchd and linger until their own idle/exit
        // logic fired. `closeAll()` is async on the actor; we bridge it
        // to this synchronous AppKit callback with a bounded semaphore
        // wait so a wedged server can't block quit indefinitely.
        //
        // [S3 / TSK-485] `closeAll()` now shuts its live clients down
        // CONCURRENTLY (a `TaskGroup` inside ViewerCore), so total teardown
        // is ≈ the slowest single `LSPClient.shutdown()` (~2.4s: 2s request
        // timeout + 200ms grace + 200ms SIGTERM poll) regardless of how many
        // servers are live — not the old N×2.4s sequential cost that blew
        // past the budget once N≥2 and reparented un-shut clients to launchd.
        //
        // The wait is an UPPER BOUND, not a fixed sleep — `done.wait` returns
        // the instant `closeAll()` signals, so the common fast case still
        // quits promptly. The ceiling is now a pure safety net against a
        // pathologically wedged pool (a server trapping SIGTERM), comfortably
        // above one parallel teardown. On timeout we log a warning and let
        // the OS reap the children at process exit rather than silently
        // leaking — the finding's explicit ask.
        let pool = model.lspPool
        // A few multiples of a single ~2.4s parallel teardown — generous
        // headroom for a wedged server while still bounding quit latency.
        let shutdownDeadline = 8.0
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await pool.closeAll()
            done.signal()
        }
        if done.wait(timeout: .now() + shutdownDeadline) == .timedOut {
            let warning = "lsp: closeAll() exceeded \(shutdownDeadline)s quit "
                + "budget — proceeding to exit; OS will reap any un-shut LSP children\n"
            FileHandle.standardError.write(Data(warning.utf8))
        }
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

    // MARK: - File → Reset (recoverable cache / stuck-state invalidation)

    /// Per-domain reset. The menu item's `tag` indexes `CacheDomain.allCases`.
    @objc func resetCacheDomain(_ sender: NSMenuItem) {
        let domains = CacheDomain.allCases
        guard domains.indices.contains(sender.tag) else { return }
        let d = domains[sender.tag]
        performReset([d],
                     label: d.title.replacingOccurrences(of: "…", with: ""),
                     detail: d.detail,
                     includePreferences: false)
    }

    @objc func resetPreferences(_ sender: Any?) {
        performReset([],
                     label: "Reset Preferences",
                     detail: "Resets zoom, theme, word-wrap, window size and other preferences to their defaults.",
                     includePreferences: true)
    }

    @objc func resetEverything(_ sender: Any?) {
        performReset(CacheDomain.allCases,
                     label: "Reset Everything",
                     detail: "Clears ALL saved sessions, window layout, bookmarks, recent files, language-server cache, and preferences.",
                     includePreferences: true)
    }

    /// Confirm, move the selected stores into a recoverable backup, optionally
    /// reset UserDefaults, then relaunch. See `AppCacheReset`.
    private func performReset(_ domains: [CacheDomain],
                              label: String,
                              detail: String,
                              includePreferences: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(label)?"
        alert.informativeText = detail
            + "\n\nYour data is moved to a recoverable backup under "
            + "Application Support/MarkdownViewer/_reset-backups/, then the app relaunches."
        alert.addButton(withTitle: "Reset & Relaunch")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let mv = AppCacheReset.markdownViewerSupportDir()
        let bundle = AppCacheReset.bundleIDSupportDir()
        // Filesystem-safe timestamp (no ':').
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        if !domains.isEmpty {
            AppCacheReset.reset(
                domains,
                markdownViewerBase: mv,
                bundleIDBase: bundle,
                backupRoot: AppCacheReset.defaultBackupRoot(markdownViewerBase: mv),
                timestamp: stamp)
        }
        if includePreferences, let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            UserDefaults.standard.synchronize()
        }
        relaunchAndExit()
    }

    /// Spawn a fresh instance and HARD-exit. `exit(0)` (not `NSApp.terminate`)
    /// deliberately bypasses `applicationWillTerminate` — its `flushSync()`
    /// would re-persist the in-memory session/layout state we just cleared,
    /// resurrecting exactly what the reset removed.
    private func relaunchAndExit() -> Never {
        let appURL = Bundle.main.bundleURL
        if appURL.pathExtension == "app" {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-n", appURL.path]
            try? p.run()
        }
        exit(0)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        model.sidebar.toggleVisibility()
    }

    @objc func toggleTerminal(_ sender: Any?) {
        model.terminalPane.toggle()
    }

    @objc func showPalette(_ sender: Any?) {
        model.showPalette()
    }

    @objc func showGoToPath(_ sender: Any?) {
        model.showGoToPath()
    }

    @objc func reloadCurrentFile(_ sender: Any?) {
        model.reloadCurrentFile()
    }

    /// File → Save (⌘S). Active when the focused tab is in `.editor` view
    /// mode OR is a dirty editable HEX tab (gated by `validateMenuItem`).
    /// The model surfaces any I/O failure via its own NSAlert; we just
    /// relay the call. HEX takes precedence when its buffer is dirty.
    @objc func saveActiveEditor(_ sender: Any?) {
        if let i = model.tabs.selectedIndex, model.isHexDirtyTab(at: i) {
            _ = model.saveHexEdits(forTabID: model.tabs.tabs[i].id)
            return
        }
        _ = model.saveActiveEditor()
    }

    /// File → Save a Copy… (⇧⌘S, TSK-300). Opens an NSSavePanel pre-filled
    /// with the current tab's name and writes a COPY of its effective content
    /// to the chosen path via `model.saveCopyOfCurrentTab` — the open document
    /// is left untouched (no retarget, no dirty change). The engine + its
    /// behavior are host-tested (SaveCopyTests); this is the AppKit surface.
    @objc func saveCopyAs(_ sender: Any?) {
        guard model.canSaveCopyOfCurrentTab else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.title = "Save a Copy"
        panel.nameFieldStringValue = model.saveCopySuggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try model.saveCopyOfCurrentTab(to: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t Save a Copy"
            alert.informativeText = String(describing: error)
            alert.runModal()
        }
    }

    /// Edit → Undo (⌘Z). Routes to the active CodeMirror webview's JS
    /// undo when an editor is on screen. Otherwise (TSK-330) falls back
    /// to the APP-LEVEL undo: restoring the last removed bookmark — the
    /// store has carried this stack since the Delete-to-remove ask, but
    /// nothing ever consumed it (the dead-channel class). Text-field
    /// undo is protected by validateMenuItem: the item disables while a
    /// text input is focused, releasing ⌘Z down the responder chain.
    @objc func editorUndo(_ sender: Any?) {
        if let webView = CodeMirrorEditorRegistry.shared.current(),
           model.currentViewMode == .editor {
            webView.evaluateJavaScript("undo()", completionHandler: nil)
            return
        }
        _ = model.undoLastBookmarkRemoval()
    }

    /// Edit → Redo (⇧⌘Z). Mirror of `editorUndo`.
    @objc func editorRedo(_ sender: Any?) {
        guard let webView = CodeMirrorEditorRegistry.shared.current() else { return }
        webView.evaluateJavaScript("redo()", completionHandler: nil)
    }

    /// Edit → Insert Date and Time (⌥F5-style; TSK-299). Routes to the
    /// model, which formats the current time + inserts it at the active
    /// editor's caret. validateMenuItem gates it to editor mode.
    @objc func insertDateTime(_ sender: Any?) {
        model.insertDateAndTime()
    }

    @objc func toggleViewMode(_ sender: Any?) {
        model.toggleViewMode()
    }

    @objc func newTab(_ sender: Any?) {
        model.newTab()
    }

    /// File → New File (⌘N, TSK-329). Creates an untitled file in the
    /// selected folder (or the sidebar root) via the atomic NewFileCreator
    /// and opens it. validateMenuItem disables it when no folder is open.
    @objc func newFile(_ sender: Any?) {
        guard let dir = model.newFileTargetDirectory else { return }
        model.createNewFile(in: dir)
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
        // UX-10: "Clear Menu" wipes the recents history irreversibly.
        // Confirm first so an accidental click (it sits right below the
        // recent entries) doesn't silently discard it. No-op if already
        // empty — validateMenuItem disables the item then, but guard
        // anyway for the keyboard/scripted path.
        guard !model.recents.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Clear recent files?"
        alert.informativeText = "This removes all entries from the Open Recent menu. It can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
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

        // Natural macOS tab-switch shortcuts (⌘⇧] / ⌘⇧[) — matches Safari,
        // Terminal, Notes (TSK-328). Kept in sync with the registry defaults
        // for tabs.next / tabs.previous. The bracket combos differ from the
        // ⌘⌥[ / ⌘⌥] Move-Tab items below (shift vs option), so AppKit routes
        // each unambiguously.
        let nextItem = NSMenuItem(
            title: "Next Tab",
            action: #selector(nextTab(_:)),
            keyEquivalent: "]"
        )
        nextItem.keyEquivalentModifierMask = [.command, .shift]
        nextItem.target = self
        menu.addItem(nextItem)

        let prevItem = NSMenuItem(
            title: "Previous Tab",
            action: #selector(previousTab(_:)),
            keyEquivalent: "["
        )
        prevItem.keyEquivalentModifierMask = [.command, .shift]
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

    /// Apply the effective shortcut for command `id` (built-in default ∪
    /// user `~/.textview/keybinding.json` override) from the registry onto
    /// a menu item. UX-M (#232): the registry is the single source of
    /// truth for shortcuts. If the command has no shortcut (or the id is
    /// unknown — shouldn't happen for built-ins), the item keeps whatever
    /// key equivalent it was constructed with. Returns the item for
    /// chaining.
    @discardableResult
    private func applyShortcut(_ id: String, to item: NSMenuItem) -> NSMenuItem {
        guard let cmd = model.commandRegistry.command(id: id),
              let sc = cmd.defaultShortcut else { return item }
        item.keyEquivalent = AppDelegate.appKitKeyEquivalent(for: sc.key)
        item.keyEquivalentModifierMask = AppDelegate.appKitModifiers(for: sc.modifiers)
        return item
    }

    /// Translate a `Shortcut.key` (single char or symbolic name) into the
    /// `NSMenuItem.keyEquivalent` string AppKit expects. Symbolic names
    /// map to the AppKit unicode constants; ordinary keys pass through.
    static func appKitKeyEquivalent(for key: String) -> String {
        switch key {
        case "left":      return "\u{2190}"  // NSLeftArrowFunctionKey glyph
        case "right":     return "\u{2192}"
        case "up":        return "\u{2191}"
        case "down":      return "\u{2193}"
        case "tab":       return "\t"
        case "space":     return " "
        case "escape":    return "\u{1b}"
        case "return":    return "\r"
        case "delete":    return "\u{8}"
        case "backslash": return "\\"
        default:          return key
        }
    }

    /// Translate `KeyModifiers` into `NSEvent.ModifierFlags`.
    static func appKitModifiers(for mods: KeyModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods.contains(.command) { flags.insert(.command) }
        if mods.contains(.shift)   { flags.insert(.shift) }
        if mods.contains(.option)  { flags.insert(.option) }
        if mods.contains(.control) { flags.insert(.control) }
        return flags
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
        applyShortcut("file.newTab", to: newTabItem)
        fileMenu.addItem(newTabItem)

        // TSK-329: File → New File (⌘N). Creates an untitled file in the
        // selected folder (or the sidebar root) and opens it. Disabled when
        // no folder is open (validateMenuItem).
        let newFileItem = NSMenuItem(
            title: "New File",
            action: #selector(newFile(_:)),
            keyEquivalent: "n"
        )
        newFileItem.target = self
        fileMenu.addItem(newFileItem)

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

        // ⇧⌘G — Finder-style "Go to the folder…". Opens the
        // GoToPathPrompt overlay. Note that this collides with the
        // legacy macOS shortcut for "Find Previous"; we move that to
        // ⌥⌘G in the Edit → Find submenu below.
        let goToPathItem = NSMenuItem(
            title: "Go to File or Folder…",
            action: #selector(showGoToPath(_:)),
            keyEquivalent: "g"
        )
        goToPathItem.target = self
        applyShortcut("file.goToPath", to: goToPathItem)
        fileMenu.addItem(goToPathItem)

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
        applyShortcut("file.closeTab", to: closeTabItem)
        fileMenu.addItem(closeTabItem)

        // Save (⌘S). Only active when the focused tab is in `.editor`
        // mode — `validateMenuItem` enforces that. Routes to the
        // model's saveActiveEditor() which handles encoding, atomic
        // write, fingerprint update, and dirty-dot clear.
        fileMenu.addItem(.separator())
        let saveItem = NSMenuItem(
            title: "Save",
            action: #selector(saveActiveEditor(_:)),
            keyEquivalent: "s"
        )
        saveItem.target = self
        applyShortcut("file.save", to: saveItem)
        fileMenu.addItem(saveItem)

        // Save a Copy… (⇧⌘S, TSK-300). Writes the current tab's effective
        // content (HEX-dirty bytes → else dirty editor text → else the
        // on-disk file) to a chosen path WITHOUT retargeting or dirtying
        // the open doc. validateMenuItem gates on model.canSaveCopyOfCurrentTab.
        let saveCopyItem = NSMenuItem(
            title: "Save a Copy…",
            action: #selector(saveCopyAs(_:)),
            keyEquivalent: "S"   // capital S → ⇧⌘S
        )
        saveCopyItem.target = self
        fileMenu.addItem(saveCopyItem)

        // Print + Export as PDF (TSK-638 phase 1): rendered pages only —
        // validateMenuItem gates on model.canPrintRenderedPage.
        fileMenu.addItem(.separator())
        let printItem = NSMenuItem(
            title: "Print…",
            action: #selector(printRenderedPage(_:)),
            keyEquivalent: "p"
        )
        printItem.target = self
        applyShortcut("file.print", to: printItem)
        fileMenu.addItem(printItem)
        let exportPDFItem = NSMenuItem(
            title: "Export as PDF…",
            action: #selector(exportRenderedPDF(_:)),
            keyEquivalent: ""
        )
        exportPDFItem.target = self
        fileMenu.addItem(exportPDFItem)

        // File → Reset — granular "invalidate the things that get stuck".
        // Each item moves its on-disk store into a recoverable backup and
        // relaunches. Motivated by the empty-session-index failure (session
        // tabs vanish with no in-app recovery). See `AppCacheReset`.
        fileMenu.addItem(.separator())
        let resetItem = NSMenuItem(title: "Reset", action: nil, keyEquivalent: "")
        let resetMenu = NSMenu(title: "Reset")
        resetMenu.autoenablesItems = false
        for (i, domain) in CacheDomain.allCases.enumerated() {
            let it = NSMenuItem(title: domain.title,
                                action: #selector(resetCacheDomain(_:)),
                                keyEquivalent: "")
            it.tag = i
            it.target = self
            resetMenu.addItem(it)
        }
        resetMenu.addItem(.separator())
        let prefsResetItem = NSMenuItem(
            title: "Reset Preferences (zoom, theme, window)…",
            action: #selector(resetPreferences(_:)), keyEquivalent: "")
        prefsResetItem.target = self
        resetMenu.addItem(prefsResetItem)
        let everythingItem = NSMenuItem(
            title: "Reset Everything…",
            action: #selector(resetEverything(_:)), keyEquivalent: "")
        everythingItem.target = self
        resetMenu.addItem(everythingItem)
        resetItem.submenu = resetMenu
        fileMenu.addItem(resetItem)

        fileMenuItem.submenu = fileMenu

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        // UX-M (#232): shortcuts for these items are resolved from the
        // CommandRegistry (built-in default ∪ user keybinding override)
        // via `applyShortcut(_:to:)`. The `keyEquivalent:` passed to the
        // initializer is the fallback used only if the registry has no
        // shortcut for the id.
        let toggleItem = NSMenuItem(
            title: "Toggle Rendered / Source",
            action: #selector(toggleViewMode(_:)),
            keyEquivalent: "r"
        )
        toggleItem.target = self
        applyShortcut("view.toggleRenderedSource", to: toggleItem)
        viewMenu.addItem(toggleItem)

        let sidebarItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(toggleSidebar(_:)),
            keyEquivalent: "s"
        )
        sidebarItem.target = self
        applyShortcut("view.toggleSidebar", to: sidebarItem)
        viewMenu.addItem(sidebarItem)

        // #226 (UX-D): the bottom terminal pane. Also reachable from the
        // left-shoulder bottom-aligned toggle button; the menu item gives
        // a keyboard path that works even when the sidebar (and thus the
        // left rail) is collapsed. ⌃` mirrors the common editor binding.
        let terminalItem = NSMenuItem(
            title: "Toggle Terminal",
            action: #selector(toggleTerminal(_:)),
            keyEquivalent: "`"
        )
        terminalItem.keyEquivalentModifierMask = [.control]
        terminalItem.target = self
        viewMenu.addItem(terminalItem)

        let wrapItem = NSMenuItem(
            title: "Wrap Long Lines",
            action: #selector(toggleSourceWordWrap(_:)),
            keyEquivalent: "w"
        )
        wrapItem.target = self
        applyShortcut("view.toggleWordWrap", to: wrapItem)
        viewMenu.addItem(wrapItem)

        // Show Invisibles — applies to source view AND CM6 editor.
        let invisItem = NSMenuItem(
            title: "Show Invisibles",
            action: #selector(toggleShowInvisibleChars(_:)),
            keyEquivalent: "i"
        )
        invisItem.target = self
        applyShortcut("view.toggleInvisibles", to: invisItem)
        viewMenu.addItem(invisItem)

        // Editor (CM6) — code folding + go to line. Validated to
        // only enable when an editor tab is on screen.
        let foldAllItem = NSMenuItem(
            title: "Fold All",
            action: #selector(cmFoldAll(_:)),
            keyEquivalent: "["
        )
        foldAllItem.target = self
        applyShortcut("view.foldAll", to: foldAllItem)
        viewMenu.addItem(foldAllItem)

        let unfoldAllItem = NSMenuItem(
            title: "Unfold All",
            action: #selector(cmUnfoldAll(_:)),
            keyEquivalent: "]"
        )
        unfoldAllItem.target = self
        applyShortcut("view.unfoldAll", to: unfoldAllItem)
        viewMenu.addItem(unfoldAllItem)

        let gotoLineItem = NSMenuItem(
            title: "Go to Line…",
            action: #selector(cmGotoLine(_:)),
            keyEquivalent: "l"
        )
        gotoLineItem.target = self
        applyShortcut("view.goToLine", to: gotoLineItem)
        viewMenu.addItem(gotoLineItem)

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
        applyShortcut("view.quickOpen", to: paletteItem)
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
        applyShortcut("view.zoomIn", to: zoomIn)
        viewMenu.addItem(zoomIn)
        let zoomOut = NSMenuItem(title: "Zoom Out",
                                 action: #selector(zoomOut(_:)),
                                 keyEquivalent: "-")
        zoomOut.target = self
        applyShortcut("view.zoomOut", to: zoomOut)
        viewMenu.addItem(zoomOut)
        let zoomReset = NSMenuItem(title: "Actual Size",
                                   action: #selector(zoomReset(_:)),
                                   keyEquivalent: "0")
        zoomReset.target = self
        applyShortcut("view.actualSize", to: zoomReset)
        viewMenu.addItem(zoomReset)

        viewMenu.addItem(.separator())
        let formatItem = NSMenuItem(
            title: "Pretty-Print",
            action: #selector(toggleFormat(_:)),
            keyEquivalent: "f"
        )
        formatItem.target = self
        applyShortcut("view.prettyPrint", to: formatItem)
        viewMenu.addItem(formatItem)

        let jqItem = NSMenuItem(
            title: "Apply jq Filter…",
            action: #selector(applyJQFilter(_:)),
            keyEquivalent: "j"
        )
        jqItem.target = self
        applyShortcut("view.applyJQ", to: jqItem)
        viewMenu.addItem(jqItem)

        let bookmarkItem = NSMenuItem(
            title: "Bookmark / Unbookmark Current",
            action: #selector(toggleBookmark(_:)),
            keyEquivalent: "d"
        )
        bookmarkItem.target = self
        applyShortcut("view.toggleBookmark", to: bookmarkItem)
        viewMenu.addItem(bookmarkItem)

        let bookmarkLineItem = NSMenuItem(
            title: "Bookmark / Unbookmark Current Line",
            action: #selector(toggleLineBookmark(_:)),
            keyEquivalent: "d"
        )
        bookmarkLineItem.target = self
        applyShortcut("view.toggleLineBookmark", to: bookmarkLineItem)
        viewMenu.addItem(bookmarkLineItem)

        // Split view (Phase 2.5).
        viewMenu.addItem(.separator())
        let splitItem = NSMenuItem(
            title: "Toggle Split",
            action: #selector(toggleSplit(_:)),
            keyEquivalent: "\\"
        )
        splitItem.target = self
        applyShortcut("view.toggleSplit", to: splitItem)
        viewMenu.addItem(splitItem)

        let swapItem = NSMenuItem(
            title: "Swap Split Panes",
            action: #selector(swapSplit(_:)),
            keyEquivalent: "\\"
        )
        swapItem.target = self
        applyShortcut("view.swapSplit", to: swapItem)
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
        applyShortcut("git.showPanel", to: showGitPanelItem)
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
        // Undo / Redo. CodeMirror 6 owns its own history stack and is
        // NOT wired through NSUndoManager, so the system's auto-routing
        // of ⌘Z to first-responder doesn't work for the editor. We
        // install explicit items that target this AppDelegate:
        //   - validateMenuItem (below) enables them whenever a CM6
        //     editor is mounted and the active tab is in `.editor` mode.
        //   - When neither holds, they're disabled and AppKit's
        //     responder chain delivers ⌘Z to whatever NSTextField is
        //     first responder (Go-to prompt, search field, etc.).
        let undoItem = NSMenuItem(
            title: "Undo",
            action: #selector(editorUndo(_:)),
            keyEquivalent: "z"
        )
        undoItem.target = self
        editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(
            title: "Redo",
            action: #selector(editorRedo(_:)),
            keyEquivalent: "z"
        )
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.target = self
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        // Cut / Copy / Paste must all exist in the Edit menu for AppKit
        // to route the standard ⌘X / ⌘C / ⌘V keystrokes via the
        // responder chain. Without Paste here, NSTextField doesn't
        // receive ⌘V (the keystroke is swallowed by NSApp) — visible
        // as "can't paste into the Go-to-file/folder prompt".
        editMenu.addItem(NSMenuItem(title: "Cut",
            action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",
            action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",
            action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All",
            action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())

        // Insert Date & Time (TSK-299, Notepad's F5). Only enabled in
        // editor mode (validateMenuItem); inserts a locale-formatted
        // stamp at the caret via the CM6 `insertAtCursor` bridge.
        let insertDateItem = NSMenuItem(
            title: "Insert Date and Time",
            action: #selector(insertDateTime(_:)),
            keyEquivalent: ""
        )
        insertDateItem.target = self
        editMenu.addItem(insertDateItem)
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

        // Cmd+Option+F: Find & Replace (the macOS-standard shortcut for
        // the find-bar's replace row). Only the editor (CM6) surface is
        // editable, so the action no-ops elsewhere — see `replaceInPage`.
        let replaceItem = NSMenuItem(
            title: "Find and Replace…",
            action: #selector(replaceInPage(_:)),
            keyEquivalent: "f"
        )
        replaceItem.keyEquivalentModifierMask = [.command, .option]
        replaceItem.target = self
        findSubmenu.addItem(replaceItem)

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
        // Note: ⇧⌘G is reserved for "Go to file or folder" (Finder
        // convention) — see File → Go to… below. Find Previous moves
        // to ⌥⌘G to avoid the collision. Power users tend to hit "g"
        // repeatedly with Cmd to step forward and Cmd+Shift to step
        // back; the Option alternative keeps that muscle memory close.
        let findPrev = NSMenuItem(
            title: "Find Previous",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: "g"
        )
        findPrev.keyEquivalentModifierMask = [.command, .option]
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
        // WAVE 2b items 4 + 5: the Debug menu (Diagnostics +
        // Instrumentation tool windows) is built ONLY when the diagnostic
        // gate is on (DEBUG build OR `MDV_ENABLE_DIAGNOSTICS=1`). A stock
        // release binary with the env var unset never grows this menu.
        // These windows are never exposed via the MCP tool catalog.
        if DiagnosticGate.isEnabled, let debugMenuItem = buildDebugMenu() {
            mainMenu.addItem(debugMenuItem)
        }
        mainMenu.addItem(windowMenuItem)
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
    }

    /// Build the gated Debug menu (WAVE 2b items 4 + 5). Returns `nil`
    /// when the diagnostic gate is off so callers can skip adding it
    /// entirely. Items target this AppDelegate's window openers.
    private func buildDebugMenu() -> NSMenuItem? {
        guard DiagnosticGate.isEnabled else { return nil }
        let debugMenuItem = NSMenuItem()
        let debugMenu = NSMenu(title: "Debug")

        let diagItem = NSMenuItem(
            title: "Diagnostic Window",
            action: #selector(showDiagnosticWindow(_:)),
            keyEquivalent: ""
        )
        diagItem.target = self
        debugMenu.addItem(diagItem)

        let instrItem = NSMenuItem(
            title: "Instrumentation",
            action: #selector(showInstrumentationWindow(_:)),
            keyEquivalent: ""
        )
        instrItem.target = self
        debugMenu.addItem(instrItem)

        debugMenuItem.submenu = debugMenu
        return debugMenuItem
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
            // UX-08: drop the "upgrade macOS" advice — it's stale (the app
            // already targets 15+) and reads as off-topic OS nagging in a
            // filter dialog. Keep the actionable install hint only.
            alert.informativeText = "Install jq (e.g. `brew install jq`) and try again."
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
    /// `⌘P` (TSK-638): print the selected rendered page. The model nonce
    /// asks the live rendered view (the WKWebView owner) to run the
    /// AppKit print operation.
    @objc func printRenderedPage(_ sender: Any?) {
        if !model.printRenderedPage() { NSSound.beep() }
    }

    /// File → Export as PDF… (TSK-638): save-panel → model request → the
    /// rendered view answers with createPDF and reports the outcome.
    @objc func exportRenderedPDF(_ sender: Any?) {
        guard model.canPrintRenderedPage, let window = NSApp.keyWindow else {
            NSSound.beep()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        let stem = model.currentURL?.deletingPathExtension().lastPathComponent ?? "Document"
        panel.nameFieldStringValue = stem + ".pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.model.exportRenderedPDF(to: url)
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let hasFile = model.currentURL != nil
        let hasTab  = model.tabs.selected != nil
        switch item.action {
        case #selector(newFile(_:)):
            // TSK-329: needs a folder to create into (selected dir or root).
            return model.newFileTargetDirectory != nil
        case #selector(printRenderedPage(_:)), #selector(exportRenderedPDF(_:)):
            return model.canPrintRenderedPage
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
        case #selector(toggleShowInvisibleChars(_:)):
            item.state = model.showInvisibleChars ? .on : .off
            return hasFile
        case #selector(cmFoldAll(_:)), #selector(cmUnfoldAll(_:)),
             #selector(cmGotoLine(_:)):
            return hasTab && model.currentViewMode == .editor
                && CodeMirrorEditorRegistry.shared.current() != nil
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
        case #selector(saveActiveEditor(_:)):
            // Save only enables when the focused tab is editing AND
            // has unsaved edits. Greys the menu (and disables the ⌘S
            // accelerator) otherwise — matches Xcode / VS Code. #234: a
            // dirty editable HEX tab also enables Save (binary write-back).
            guard hasTab else { return false }
            if let i = model.tabs.selectedIndex, model.isHexDirtyTab(at: i) { return true }
            guard model.currentViewMode == .editor else { return false }
            return model.tabs.selected?.isDirty == true
        case #selector(saveCopyAs(_:)):
            // Save a Copy enables whenever the current tab has content to
            // copy (on-disk file, non-empty editor buffer, or HEX-dirty
            // bytes) — unlike Save, it works on any view mode, not just editor.
            return model.canSaveCopyOfCurrentTab
        case #selector(insertDateTime(_:)):
            // Only meaningful when an editor is on screen to receive it.
            return hasTab && model.currentViewMode == .editor
                && CodeMirrorEditorRegistry.shared.current() != nil
        case #selector(editorUndo(_:)):
            // Editor on screen → editor undo (optimistic; JS undo() is a
            // no-op on empty history). Otherwise (TSK-330) enable for the
            // app-level bookmark-removal undo — but NEVER while a text
            // input is focused (field editors are NSText): returning
            // false releases ⌘Z down the responder chain so
            // NSTextField / NSTextView undo keeps working in prompts and
            // search fields.
            if hasTab && model.currentViewMode == .editor
                && CodeMirrorEditorRegistry.shared.current() != nil {
                return true
            }
            if NSApp.keyWindow?.firstResponder is NSText { return false }
            return model.canUndoBookmarkRemoval
        case #selector(editorRedo(_:)):
            // Redo stays editor-only (the bookmark stack is undo-only).
            return hasTab && model.currentViewMode == .editor
                && CodeMirrorEditorRegistry.shared.current() != nil
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

    /// Show File History — opens the in-app FileHistoryView for the
    /// current tab's file when it's a tracked file in a repo (WAVE 2b
    /// item 2). Falls back to the Git panel's Log tab otherwise (no
    /// current file, or it isn't tracked).
    @objc func showFileHistory(_ sender: Any?) {
        if let url = model.currentURL, model.canShowFileHistory(for: url) {
            model.openFileHistory(for: url)
        } else {
            model.showGitPanel(tab: .log)
        }
    }

    /// Show Repository History — opens the Git panel on the Log tab.
    @objc func showRepoHistory(_ sender: Any?) {
        model.showGitPanel(tab: .log)
    }

    // MARK: - Debug tool windows (WAVE 2b items 4 + 5)

    /// Open (or re-focus) the diagnostic window. DEBUG / opt-in only —
    /// the menu item is only built when `DiagnosticGate.isEnabled`, and we
    /// re-check here as defence in depth (the view itself also no-ops its
    /// content when the gate is off). Never reachable via the MCP catalog.
    @objc func showDiagnosticWindow(_ sender: Any?) {
        guard DiagnosticGate.isEnabled else { return }
        if let win = diagnosticWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: DiagnosticWindowView(model: model))
        let win = makeToolWindow(
            title: "Diagnostics", contentSize: NSSize(width: 720, height: 560),
            autosave: "DiagnosticWindow", controller: host
        )
        diagnosticWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open (or re-focus) the instrumentation tool window — the
    /// Logs / Metrics / Memory views over the live `RingBufferSink`
    /// installed at launch. Gated identically to the diagnostic window.
    @objc func showInstrumentationWindow(_ sender: Any?) {
        guard DiagnosticGate.isEnabled else { return }
        if let win = instrumentationWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(
            rootView: InstrumentationWindowView(model: model, sink: observabilitySink)
        )
        let win = makeToolWindow(
            title: "Instrumentation", contentSize: NSSize(width: 760, height: 540),
            autosave: "InstrumentationWindow", controller: host
        )
        instrumentationWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Shared builder for the auxiliary tool windows. `isReleasedWhenClosed
    /// = false` so the retained reference stays valid across close/reopen
    /// (re-focus rather than rebuild).
    private func makeToolWindow(
        title: String, contentSize: NSSize, autosave: String,
        controller: NSViewController
    ) -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = title
        win.contentViewController = controller
        win.isReleasedWhenClosed = false
        win.tabbingMode = .disallowed
        win.contentMinSize = NSSize(width: 360, height: 280)
        _ = win.setFrameAutosaveName(autosave)
        if UserDefaults.standard.string(forKey: "NSWindow Frame \(autosave)") == nil {
            win.center()
        }
        return win
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
        // Cmd+F TOGGLES the find bar for the active surface (TSK-739): a second
        // press closes it. Each branch routes to the matching bar's toggle.
        // Rendered markdown — only meaningful when the file is markdown
        // and the user is viewing the rendered side.
        if model.supportsViewModeToggle, model.currentViewMode == .rendered {
            model.toggleRenderedFindBar()
            return
        }
        // Editor mode (CM6) — route to the new editor find bar that
        // drives CodeMirror via the v1 bridge.
        if model.currentViewMode == .editor {
            model.toggleEditorFindBar()
            return
        }
        // Otherwise the user is on the source/text side: open the
        // source find bar (works for source view, plaintext, code, etc.).
        model.toggleSourceFindBar()
    }

    /// Cmd+Option+F router — Find & Replace. Replace is only meaningful
    /// on the editable CM6 editor surface; the rendered and source views
    /// are read-only, so there we fall back to plain Find rather than
    /// showing an inert replace row.
    @objc func replaceInPage(_ sender: Any?) {
        if model.currentViewMode == .editor {
            model.showEditorReplaceBar()
            return
        }
        findInPage(sender)
    }

    // MARK: - Editor-mode menu items (CM6 Phase 2)

    @objc func toggleShowInvisibleChars(_ sender: Any?) {
        model.toggleShowInvisibleChars()
    }

    @objc func cmFoldAll(_ sender: Any?) {
        guard let wv = CodeMirrorEditorRegistry.shared.current() else { return }
        let json = CMBridgeCodec.encodeOutboundJSON(.foldAll)
        wv.evaluateJavaScript("window.cmDispatch(\(json));", completionHandler: nil)
    }

    @objc func cmUnfoldAll(_ sender: Any?) {
        guard let wv = CodeMirrorEditorRegistry.shared.current() else { return }
        let json = CMBridgeCodec.encodeOutboundJSON(.unfoldAll)
        wv.evaluateJavaScript("window.cmDispatch(\(json));", completionHandler: nil)
    }

    /// Go to Line… prompt — uses a tiny inline NSAlert. Lighter than a
    /// dedicated SwiftUI sheet for the PoC; can promote later.
    @objc func cmGotoLine(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Enter a 1-based line number."
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        // UX-09/10: give the field a placeholder so the expected input is
        // obvious, and make it the alert's initial first responder so the
        // user can type the number immediately without clicking in.
        field.placeholderString = "Line number"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let n = Int(trimmed), n > 0 else {
            // UX-09: invalid / empty input gets an audible beep instead of
            // silently dismissing, so a fat-fingered entry is noticed.
            NSSound.beep()
            return
        }
        model.editorGotoLine = CMGotoLineRequest(line: n)
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
            },
            onExit: {
                // The read loop ended (stdin EOF, framing error, or a
                // `shutdown`/`stop()`). In `--mcp-stdio` mode there is no
                // UI to keep the process around, so terminate `NSApp`;
                // otherwise the headless server orphans — `NSApp.run`
                // would block forever with the loop already gone.
                //
                // `onExit` fires on the background read thread, so hop to
                // the main actor for AppKit. `terminate(nil)` runs
                // `applicationWillTerminate` (session/JSON flush, LSP
                // teardown) and then calls `exit()` itself — it does not
                // return when termination proceeds, so we deliberately do
                // NOT append a manual `exit(0)`: that would race the
                // async teardown and short-circuit the flush.
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
            }
        )
        server.start()
        self.mcpServer = server
        // Tell stderr we're up so clients with a verbose mode can
        // confirm the server actually launched. Stdout stays silent
        // until a framed response.
        FileHandle.standardError.write(Data("mcp: server ready on stdio\n".utf8))
    }

    /// Open the standalone Claude session monitor window (the
    /// `--claude-monitor` PoC). No menu, no document model wiring — just a
    /// single `NSHostingController(rootView: ClaudeMonitorView())`. Retained
    /// on the delegate so a second invocation could re-focus it; today the
    /// flag opens exactly one window at launch.
    @MainActor
    fileprivate func openClaudeMonitorWindow() {
        NSWindow.allowsAutomaticWindowTabbing = false
        let host = NSHostingController(rootView: ClaudeMonitorView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Claude Session Monitor"
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = NSSize(width: 760, height: 460)
        let autosaveName = "ClaudeMonitorWindow"
        _ = window.setFrameAutosaveName(autosaveName)
        if UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)") == nil {
            window.center()
        }
        showWindow(window)
        self.window = window
        // Publish the WindowServer windowNumber (same contract as the main
        // document window) so the T5 pixel lane can `screencapture -l<id>`
        // this monitor window — see ClaudeMonitorVisualRegressionTests.
        if let identifier = Bundle.main.bundleIdentifier {
            let url = ArtifactDir.url
                .appendingPathComponent("\(identifier).windowid")
            try? "\(window.windowNumber)".write(
                to: url, atomically: true, encoding: .utf8)
        }
        activateIfForeground()
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

/// `--claude-monitor` opens ONLY the standalone read-only Claude session
/// monitor PoC window (no document UI). Stays `.regular` so the window is
/// interactive and screenshot-validatable.
let claudeMonitorMode = CommandLine.arguments.contains("--claude-monitor")

/// Run-scoped artifact directory for the L4/L5 script runner's per-step
/// dumps (`mdv-step-NN.{json,png}`) and the WindowServer `.windowid`
/// file.
///
/// #193: parallel live-app tests used to share ONE per-user tmpdir
/// (`FileManager.default.temporaryDirectory`), so concurrently-running
/// scenarios overwrote each other's `mdv-step-NN.json` — producing flaky
/// `dumps.count` / empty-state asserts. The harness now threads a unique
/// directory per test via the `MDV_ARTIFACT_DIR` launch env var; the app
/// writes all artifacts there. When unset (normal interactive launches +
/// `scripts/visual-smoke.sh`), we fall back to the per-user tmpdir so
/// behaviour is unchanged. Threading the dir also fixes the visual-smoke
/// windowid mismatch (harness + app now agree on the path).
enum ArtifactDir {
    static let url: URL = {
        let env = ProcessInfo.processInfo.environment["MDV_ARTIFACT_DIR"]
        guard let path = env, !path.isEmpty else {
            return FileManager.default.temporaryDirectory
        }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        // Best-effort create; if it fails the writes below just no-op
        // via `try?`, same as the pre-#193 behaviour on an unwritable tmp.
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }()
}

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
