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
    /// TSK-1571: the menu-opened Claude Session Monitor window, held SEPARATELY
    /// from `window` (the main doc window) so opening the monitor from the Tools
    /// menu doesn't clobber the main-window reference. In `--claude-monitor`
    /// launch mode the monitor IS the only window and stays on `window`.
    private var monitorWindow: NSWindow?
    private var openRecentMenu: NSMenu?
    private var recentlyClosedMenu: NSMenu?
    private var sessionJumpMenu: NSMenu?
    private var languageMenu: NSMenu?
    private var windowMenu: NSMenu?
    private var terminalFavoritesMenu: NSMenu?   // TSK-769
    // TSK-1480: the Convert submenus + the Indent submenu's current-value header,
    // retained so `menuNeedsUpdate` can mark the active file's current format.
    private var convertEncodingMenu: NSMenu?
    private var convertLineEndingMenu: NSMenu?
    private var convertIndentMenu: NSMenu?
    private var convertIndentHeaderItem: NSMenuItem?
    /// TSK-754: plugin-contributed menu items, keyed by their menu-item
    /// tag, so the single `invokePluginMenuItem` selector can dispatch to
    /// the right `Entry.invoke` closure. Rebuilt whenever the Plugins
    /// menu is (re)constructed.
    private var pluginMenuInvocations: [Int: (@MainActor () -> Void)] = [:]
    /// Auxiliary tool windows (WAVE 2b items 4 + 5). Retained so a second
    /// menu invocation re-focuses the existing window instead of spawning
    /// duplicates; `isReleasedWhenClosed = false` keeps them alive across
    /// close/reopen.
    private var diagnosticWindow: NSWindow?
    private var instrumentationWindow: NSWindow?
    /// The Keyboard Shortcuts help window (TSK-678). Retained like the tool
    /// windows above so Help → Keyboard Shortcuts re-focuses rather than
    /// spawning a duplicate.
    private var keyboardShortcutsWindow: NSWindow?
    /// The Manage Snippets window (TSK-705). Retained like the tool windows
    /// above so Edit → Manage Snippets re-focuses rather than spawning a dup.
    private var snippetManagerWindow: NSWindow?
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
    // TSK-1544: the GUI instance's own MCP endpoint — `--mcp-connect`
    // bridges dial this so agents drive the RUNNING app, not a clone.
    private var mcpSocketListener: MCPSocketListener?
    /// Captured at hosting-controller construction so the
    /// `--walkthrough PATH` flag can start playback against the
    /// SwiftUI-owned controller without rebuilding the view body.
    fileprivate var walkthroughController: WalkthroughPlayerController?

    /// TSK-1243/1247: env-independent launch-config delivery for the VM GUI lane.
    /// LaunchServices `open --env` does NOT deliver env vars to the app under
    /// `sudo -u <consoleUser>`, so a viaOpen test launch silently drops
    /// MDV_SCRIPT_PATH / MDV_ARTIFACT_DIR / MDV_SKIP_WORKSPACE_RESTORE / … — the
    /// app then runs workspace-restore (polluted layout, blank preview) and never
    /// runs the script. The harness instead writes those knobs to a deterministic
    /// HOME-relative file (`~/.mdv-launch-config.env`, KEY=VALUE per line); read it
    /// and `setenv` each so every downstream `ProcessInfo.environment` read works
    /// unchanged. One-shot (deleted after read); absent in prod ⇒ no-op.
    /// TSK-1243: read an env var from the LIVE C environ (getenv), NOT
    /// `ProcessInfo.processInfo.environment` — which on Darwin caches a snapshot of
    /// environ at first access. The viaOpen launch config is delivered by
    /// `applyLaunchConfigFileIfPresent` via `setenv()` at module scope; if anything
    /// snapshotted environ before that, ProcessInfo wouldn't reflect the setenv'd
    /// values (→ the script-runner / skip-restore silently saw nothing). getenv
    /// always reflects the live environ, so the config-delivered launch knobs are
    /// read through this. (Matches the getenv idiom in LocalHistoryPolicy /
    /// RustCoreGates.) Direct-spawn UATs are unaffected — their env is in environ
    /// from process start, so getenv and ProcessInfo agree.
    nonisolated static func mdvLiveEnv(_ key: String) -> String? {
        guard let c = getenv(key) else { return nil }
        return String(cString: c)
    }

    /// TSK-1243: true when the viaOpen test launch-config file was found+consumed at
    /// module scope (prod / direct-spawn never have it). Gates the didFinishLaunching
    /// fallback below (and, temporarily, the diag markers).
    nonisolated(unsafe) static var launchConfigPresent = false
    /// TSK-1243: idempotency latch so the normal auto-fired didFinishLaunching and the
    /// viaOpen force-call fallback never run the launch sequence twice.
    nonisolated(unsafe) static var launchSequenceRan = false

    static func applyLaunchConfigFileIfPresent() {
        // FIXED ABSOLUTE path (not HOME-relative): a LaunchServices-launched app
        // does NOT inherit the `open` process's HOME (`sudo -H` sets it only for
        // `open` itself), so NSHomeDirectory() is unpredictable under the VM GUI
        // lane — a HOME-relative path is unfindable. /tmp (/private/tmp, 1777) is
        // visible to both the root harness writer and the console-user app.
        let path = "/tmp/mdv-launch-config.env"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        launchConfigPresent = true
        for line in content.split(separator: "\n", omittingEmptySubsequences: true) {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, !kv[0].isEmpty else { continue }
            setenv(kv[0], kv[1], 1)
        }
        try? FileManager.default.removeItem(atPath: path)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // TSK-1243: idempotent. Under the viaOpen VM launch AppKit doesn't post this
        // (no launch Apple Event under sudo-u LS), so a module-scope fallback force-
        // calls it; the latch ensures the normal auto-fire + the fallback never run
        // the launch sequence twice.
        if Self.launchSequenceRan { return }
        Self.launchSequenceRan = true
        // TSK-1129 (owner-resolved: prompt-first-then-block): the one-time
        // confirm for untrusted workspace-local LSP server binaries — the
        // RCE-on-browse guard. Without this handler the guard FAILS CLOSED
        // (headless/automation never silently runs a repo-shipped binary).
        // The pool spawns off-main, so hop to main for the modal.
        LSPTrustPrompt.confirmHandler = { binary, _ in
            let run: () -> Bool = {
                let alert = NSAlert()
                alert.messageText = "Run this folder's language server?"
                alert.informativeText =
                    "This folder ships its own language-server binary:\n\n"
                    + binary.path
                    + "\n\nRunning it executes code from the folder. "
                    + "Trust it only if you trust this folder."
                alert.addButton(withTitle: "Trust and Run")
                alert.addButton(withTitle: "Block")
                return alert.runModal() == .alertFirstButtonReturn
            }
            return Thread.isMainThread ? run() : DispatchQueue.main.sync(execute: run)
        }
        // TSK-1247 diagnostic (env-gated, MDV_WINDOW_DIAG=1): dump the
        // NSApplication window list ~3s after launch to root the spawned-app
        // "no visible window" issue on the launchctl-asuser-root VM GUI lane —
        // distinguishes exists-off-Space/occluded from never-created. An
        // off-Space/occluded window makes the rendered-preview WKWebView suspend
        // rendering → the script-bus scroll probe reads -1 (TSK-1247 + the
        // downstream TSK-1200 / ScrollRestore UAT failures). No-op in production.
        if ProcessInfo.processInfo.environment["MDV_WINDOW_DIAG"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                let wins = NSApplication.shared.windows
                var out = "MDV_WINDOW_DIAG: \(wins.count) window(s); appActive=\(NSApp.isActive)\n"
                // TSK-1576: also dump every screen's full + visible frame, so a
                // footer-clipping capture can be rooted in geometry (window bottom
                // vs visibleFrame minY) rather than inferred.
                for (i, s) in NSScreen.screens.enumerated() {
                    out += "MDV_WINDOW_DIAG screen[\(i)] frame=\(NSStringFromRect(s.frame))"
                        + " visibleFrame=\(NSStringFromRect(s.visibleFrame))\n"
                }
                for (i, w) in wins.enumerated() {
                    let title = w.title.isEmpty ? "<none>" : w.title
                    out += "MDV_WINDOW_DIAG[\(i)] title=\(title)"
                        + " frame=\(NSStringFromRect(w.frame)) visible=\(w.isVisible)"
                        + " onActiveSpace=\(w.isOnActiveSpace)"
                        + " occluded=\(!w.occlusionState.contains(.visible))"
                        + " miniaturized=\(w.isMiniaturized) level=\(w.level.rawValue)\n"
                }
                FileHandle.standardError.write(Data(out.utf8))
            }
        }
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

        // TSK-1544: serve MCP from THIS running instance on a per-user unix
        // socket (same framing + tool catalog as --mcp-stdio), so a
        // `--mcp-connect` bridge (e.g. Claude Code's server config) drives
        // the LIVE app — open documents, live canvas co-editing — instead of
        // spawning a second headless instance. Failure is non-fatal: the app
        // runs fine without the endpoint; bridges fall back to headless.
        startMCPSocketListener()

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

        // No-clobber save guard (TSK-768): when ⌘S detects the file changed on
        // disk under a dirty buffer, the conflict prompt offers "Save as Copy".
        // Wire that to the same NSSavePanel the File ▸ Save a Copy menu uses, so
        // the user can keep BOTH the external change and their edits. Presenting
        // a panel is AppKit / window work, so it lives in the AppDelegate (not
        // DocumentModel). Returns true when a copy was written.
        model.editor.onSaveAsCopy = { [weak self] tabID in
            guard let self,
                  let index = self.model.tabs.tabs.firstIndex(where: { $0.id == tabID })
            else { return false }
            let panel = NSSavePanel()
            panel.title = "Save a Copy"
            panel.nameFieldStringValue =
                self.model.tabs.tabs[index].url?.lastPathComponent ?? "Untitled.txt"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            do {
                return try self.model.saveCopy(ofTabAt: index, to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t Save a Copy"
                alert.informativeText = String(describing: error)
                alert.runModal()
                return false
            }
        }

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
        // TSK-840: warm markdown FIRST (the rendered-MD fence path
        // tokenizes it synchronously on the main actor), then the rest
        // CONCURRENTLY across cores instead of serially on one thread.
        // TSK-853/TSK-854: warm via the ADAPTER, which heats the Rust
        // core's per-language config_cache — the only highlighter now (the
        // Swift twin was deleted in TSK-854).
        Task.detached(priority: .utility) {
            RustHighlightAdapter.warm(HighlightLanguage.allCases,
                                      prioritizing: [.markdown])
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
        // TSK-264: gate the session tab strip on the persisted
        // `sessionsEnabled` flag (default true). Read once at launch — the
        // providers aren't hot-swappable mid-run in this foundation slice.
        let rootView = ContentView(
            model: model,
            sessionsApp: sessions,
            sessionsUIEnabled: PreferencesStore().sessionsEnabled
        )
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
        // Session strip lives IN the title bar (owner 2026-08-05, Safari-style):
        // full-size content + transparent titlebar; the strip band draws its own
        // background, insets past the traffic lights, and carries a
        // WindowDragGesture so the window stays movable from the empty band.
        // The title stays SET (hidden on the bar) for Mission Control/Dock.
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
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
        // where the user can be left with a useless window (frame below the
        // minimum content size; frame on a now-disconnected display). The
        // clamp/restore-vs-default DECISION lives in the host-tested
        // `WindowGeometry` model (TSK-358); here we just feed it the restored
        // frame + the live screen layout and apply the result.
        let frame = window.frame
        let minWindowSize = window.frameRect(forContentRect:
            NSRect(origin: .zero, size: minContentSize)).size
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let resolution = WindowGeometry.resolve(
            requested: WindowGeometry.Frame(frame),
            visibleFrames: visibleFrames,
            minSize: minWindowSize
        )
        switch resolution {
        case .restore:
            break  // keep the AppKit-restored frame as-is
        case let .clamped(clamped):
            window.setFrame(clamped, display: false)
        case .centerDefault:
            let primary = visibleFrames.first
                ?? NSScreen.main?.visibleFrame
                ?? NSRect(origin: .zero, size: WindowGeometry.defaultContentSize)
            window.setFrame(resolution.frame(primaryVisible: primary), display: false)
        }
        // TSK-1576: in UAT SCENE mode only, force a deterministic, generous
        // window size so the WHOLE app chrome — including the status-bar FOOTER
        // (the app's bottom row) — renders and is captured. Scene spawns restore
        // whatever frame the VM last saved, which can be the 600×360 MINIMUM; at
        // that height the footer is squeezed out of the window-id capture
        // entirely (so every footer chip — git/LSP/memory/vim — was
        // un-capturable). Gated on MDV_UI_SCENE → zero production impact.
        if ProcessInfo.processInfo.environment["MDV_UI_SCENE"] != nil,
           let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            window.setFrame(WindowGeometry.sceneCaptureFrame(in: vf), display: false)
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

        // Plugins (Tier U / TSK-782): install the AppKit seams that the
        // pure-logic registry can't own. The opener hands a host-
        // validated https/http URL to the system browser; the context
        // provider supplies the focused document so `{path}`/`{filename}`
        // templates resolve against the live tab when the user selects an
        // "open in Docs/Wiki/Code Review/CodeSearch" menu item. Wired
        // BEFORE loadAtLaunch so a Tier U item is live the moment it
        // registers. Selection/query/line stay nil for now (the editor
        // selection lives in the WebView, not the model) — they're
        // forward-compat fields a richer host context can fill later.
        PluginRegistry.shared.setURLOpener { url in
            NSWorkspace.shared.open(url)
        }
        PluginRegistry.shared.setURLContextProvider { [weak model] in
            let url = model?.currentURL
            return PluginURLTemplate.Context(
                path: url?.path,
                filename: url?.lastPathComponent
            )
        }

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
        // Silent-persistence-failure fix (audit THEME 1): every store writes
        // through JSONFileStore and every caller discards the Bool, so a full
        // disk lost sessions/bookmarks/history with no signal. One hook at the
        // choke point; the reporter coalesces (a full disk fails EVERY write —
        // first failure reports immediately, then at most one per minute).
        let persistenceReporter = PersistenceFailureReporter()
        JSONFileStore.onWriteFailure = { url in
            guard let report = persistenceReporter.record(url: url) else { return }
            DispatchQueue.main.async {
                ToastCenter.shared.post(.error, report.message)
            }
        }

        sessions.wireLifecycle()
        if Self.mdvLiveEnv("MDV_SKIP_WORKSPACE_RESTORE") != "1" {
            // Crash-loop breaker: restore is unconditional, so a document that
            // crashes the app DURING restore gets reopened by the next launch
            // and crashes again — the app becomes permanently unstartable with
            // no way to reach a menu and undo it. The guard drops a marker
            // before restoring and clears it after; two consecutive unfinished
            // attempts mean restore is what's killing us, so skip it once.
            let guardMarker = RestoreCrashGuard(
                markerURL: RestoreCrashGuard.defaultMarkerURL())
            switch guardMarker.beginAttempt() {
            case .restore:
                sessions.bootstrap()
                guardMarker.markSucceeded()
            case .skipRestore(let failures):
                // I-18 (owner 2026-08-01): the recovery used to be an
                // undiscoverable quit-and-relaunch. "Restore Now" re-runs the
                // SAME guarded restore: the skip cleared the marker, so this
                // attempt is protected exactly like a fresh launch — a crash
                // mid-restore re-trips the breaker next time.
                ToastCenter.shared.post(
                    .error,
                    "Couldn't restore your last session — it crashed on the last "
                    + "\(failures) launches. Starting fresh; your sessions are still saved.",
                    actionLabel: "Restore Now",
                    action: { [weak self] in
                        guard let self else { return }
                        let retryGuard = RestoreCrashGuard(
                            markerURL: RestoreCrashGuard.defaultMarkerURL())
                        if case .restore = retryGuard.beginAttempt() {
                            self.sessions.bootstrap()
                            retryGuard.markSucceeded()
                        }
                    },
                    ttl: 30)
            }
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
        // TSK-926/927: argv parsing extracted to the host-tested
        // `LaunchArgs.parse` (ViewerCore). The `--script`/path values below stay
        // mutable so the LaunchServices ENV fallback can fill them in.
        let launch = LaunchArgs.parse(Array(CommandLine.arguments.dropFirst()))
        let diagnoseMode = launch.diagnose
        let forceSource = launch.forceSource
        let autoSnapshotDelay = launch.autoSnapshotDelay
        var scriptPath: String? = launch.scriptPath
        let walkthroughPath = launch.walkthroughPath
        var pathArgs: [String] = launch.paths
        // TSK-620: LaunchServices-launched harness runs (`open -a … --env`)
        // carry the script + file via ENVIRONMENT because LS drops
        // `--`-prefixed argv. An LS launch is the only way a harness app
        // can genuinely self-activate on macOS 14+ (fork/exec'd processes
        // are denied cooperative activation), and real activation is what
        // synthesized SwiftUI clicks require. argv wins when both are set.
        if scriptPath == nil, let envScript = Self.mdvLiveEnv("MDV_SCRIPT_PATH") {
            scriptPath = envScript
        }
        if pathArgs.isEmpty, let envFile = Self.mdvLiveEnv("MDV_OPEN_FILE") {
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

        // TSK-1448 — first-run tour: on a fresh profile that opened NO file at
        // launch, open the self-demonstrating sample once (one-shot latch). Only
        // in a real user launch — skipped for the UI-scene harness, diagnose
        // dumps, and tagged test instances so they never consume the owner's
        // shared latch. The auto-open decision is host-tested (FirstRunExperience).
        let env = ProcessInfo.processInfo.environment
        if !openedFirst, !diagnoseMode,
           env["MDV_UI_SCENE"] == nil, env["MDV_TEST_INSTANCE"] != "1",
           FirstRunExperience.shouldOffer() {
            if model.openFirstRunSample() != nil {
                FirstRunExperience.markShown()
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
            if let scheme = url.scheme, URLSchemeRouter.schemes.contains(scheme) {
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
        case .session(let name):
            // TSK-1536: `mdv session <name>` → textview://session?name=…
            // A miss is a silent no-op (session switching is reversible; the
            // CLI echoed the name it sent).
            _ = sessions.activate(named: name)
        case nil:
            break
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // TSK-1544: close the MCP socket + unlink its node first — after
        // this point the model is tearing down, so no new automation
        // session may attach mid-flush.
        mcpSocketListener?.stop()
        mcpSocketListener = nil

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

    // TSK-698 — View ▸ Script Console: open the JQ-style query/transform console over the
    // active buffer (seeded from its content; output applies to a new tab).
    @objc func openScriptConsole(_ sender: Any?) {
        model.openScriptConsole()
    }

    // TSK-1161 — View ▸ Structural Search: AST/structural query over the active buffer.
    @objc func openStructuralSearch(_ sender: Any?) {
        model.openStructuralSearch()
    }

    // TSK-1160 — View ▸ Task Runner: discover + run project tasks with captured output.
    @objc func openTaskRunner(_ sender: Any?) {
        model.openTaskRunner()
    }

    // TSK-1176 — View ▸ Terminal Command Palette: search history + favorites, insert at prompt.
    @objc func openTerminalCommandPalette(_ sender: Any?) {
        model.openTerminalCommandPalette()
    }

    // TSK-1325 — View ▸ Convert Image: format/quality conversion of the active image → new tab.
    @objc func openConvertImage(_ sender: Any?) {
        model.openConvertImage()
    }

    // TSK-1323 — View ▸ Extract Audio from Video; TSK-1324 — View ▸ Convert Audio.
    @objc func openExtractAudio(_ sender: Any?) {
        model.openExtractAudio()
    }
    @objc func openConvertAudio(_ sender: Any?) {
        model.openConvertAudio()
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

    /// TSK-373: File → New Session ▸ Kind. The menu item's `tag` indexes
    /// into the shared `NewSessionMenuItems.all` source of truth, so the
    /// AppKit menu, the SwiftUI session-tab `+` menu, and any palette row
    /// can never drift on which kinds are offered. Creates a new session of
    /// the chosen kind (rooted at home), seeding that kind's panel layout.
    @objc func newSessionOfKind(_ sender: Any?) {
        let items = NewSessionMenuItems.all
        guard let item = sender as? NSMenuItem,
              items.indices.contains(item.tag) else { return }
        sessions.openNewSession(kind: items[item.tag].kind)
    }

    @objc func nextSession(_ sender: Any?)     { sessions.nextSession() }
    @objc func previousSession(_ sender: Any?) { sessions.previousSession() }
    @objc func closeSession(_ sender: Any?)    { sessions.closeActive() }

    /// TSK-931: rename the active session from the menu bar. Prompts with the
    /// current name prefilled; routes to the SAME `sessions.rename` the inline
    /// session-tab editor uses (which trims + ignores empty/no-op).
    @objc func renameSession(_ sender: Any?) {
        guard let active = sessions.active else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Session"
        alert.informativeText = "Enter a new name for this session."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = active.displayName
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            sessions.rename(id: active.id, to: field.stringValue)
        }
    }

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

    /// TSK-1163 — Edit ▸ Paste as New Document (⇧⌘V): Universal Paste. Opens the
    /// clipboard's best representation (file / image / table / rich / plain) in a
    /// new tab via `DocumentModel.universalPaste`. Treats the clipboard as data.
    @objc func universalPasteAsDocument(_ sender: Any?) {
        model.universalPaste()
    }

    /// TSK-899: ⌘N → select the Nth available view mode (tag = 0-based slot).
    @objc func selectViewModeSlot(_ sender: Any?) {
        let slot = (sender as? NSMenuItem)?.tag ?? 0
        model.selectViewMode(at: slot)
    }

    @objc func toggleViewMode(_ sender: Any?) {
        model.toggleViewMode()
    }

    /// TSK-936 — View ▸ Toggle View Only (⇧⌘L): flip the read-only lock on the
    /// active tab's editable lens.
    @objc func toggleViewOnlyMode(_ sender: Any?) {
        model.toggleViewOnly()
    }

    /// TSK-1116 — View ▸ Focus Mode ▸ <mode>. `tag` indexes
    /// `FocusWorkMode.allCases` (the menu is built from the same array).
    @objc func applyFocusModeMenu(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? 0
        let modes = FocusWorkMode.allCases
        guard modes.indices.contains(tag) else { return }
        model.applyFocusMode(modes[tag])
    }

    @objc func newTab(_ sender: Any?) {
        model.newTab()
    }

    /// File → New File (⌘N, TSK-329). Creates an untitled file in the
    /// selected folder (or the sidebar root) via the atomic NewFileCreator
    /// and opens it. validateMenuItem disables it when no folder is open.
    @objc func newFile(_ sender: Any?) {
        guard let dir = model.newFileTargetDirectory else { return }
        // TSK-1605: ask for the name FIRST (no Untitled.txt-then-rename).
        model.promptForNewFile(in: dir)
    }

    /// File → New File ▸ {Markdown,CSV,JSON} (TSK-747). The menu item's `tag`
    /// indexes `NewFileType.allCases`; falls back to `.text` if a tag is ever
    /// out of range. Same target-folder + disable semantics as `newFile`.
    @objc func newFileOfType(_ sender: Any?) {
        guard let dir = model.newFileTargetDirectory else { return }
        let cases = NewFileType.allCases
        let tag = (sender as? NSMenuItem)?.tag ?? 0
        let type = cases.indices.contains(tag) ? cases[tag] : .text
        model.promptForNewFile(in: dir, type: type)   // TSK-1605: name first
    }

    /// File → New Tab from Clipboard (TSK-935). Scratch tab seeded with the
    /// clipboard text; extension content-detected. No-op when the clipboard
    /// has no text (validateMenuItem also disables it).
    @objc func newTabFromClipboard(_ sender: Any?) {
        _ = model.newScratchTabFromClipboard()
    }

    /// TSK-721 — File → New HTTP Request: open the in-app HTTP request tool.
    @objc func newHTTPRequest(_ sender: Any?) {
        model.openHTTPClient()
    }

    /// TSK-1417 — File → Feed Reader: open the RSS/feed reader (was fully built
    /// + host-tested but orphaned; owner chose FINISH → wire the entry point).
    @objc func openFeedReader(_ sender: Any?) {
        model.openFeedReader()
    }

    /// TSK-1100 — open the project's import dependency graph in a hosted tab.
    @objc func showDependencyGraph(_ sender: Any?) {
        model.showDependencyGraph()
    }

    /// TSK-506 — open the project folder's size treemap in a hosted tab.
    @objc func showFolderTreemap(_ sender: Any?) {
        model.showFolderTreemap()
    }

    /// TSK-1500 — File ▸ Recover Deleted File…: present the picker of deleted
    /// files that still have Local History (recreate-from-version).
    @objc func recoverDeletedFile(_ sender: Any?) {
        model.showRecoverDeletedFile = true
    }

    /// TSK-1107 — File ▸ Walkthroughs: open the saved-walkthroughs browser.
    @objc func showWalkthroughsBrowser(_ sender: Any?) {
        model.showWalkthroughsBrowser()
    }

    /// TSK-1121 — File ▸ Annotations: a jump-list of the active file's TODO/FIXME/… markers.
    @objc func showAnnotations(_ sender: Any?) {
        model.showAnnotations()
    }

    /// TSK-1153 — File ▸ Log Patterns: a frequency summary of the active log's repeated lines.
    @objc func showLogPatterns(_ sender: Any?) {
        model.showLogPatterns()
    }

    /// TSK-1109 — File ▸ Package Dependencies: the active manifest's declared deps.
    @objc func showPackageExplorer(_ sender: Any?) {
        model.showPackageExplorer()
    }

    /// TSK-1103 — File ▸ Local History: the active file's save-time version snapshots.
    @objc func showLocalHistory(_ sender: Any?) {
        model.showLocalHistory()
    }

    /// TSK-1144 — File ▸ Export as Word: write the active document (as Markdown) to .docx.
    @objc func exportActiveAsDocx(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "export.docx"
        if let docx = UTType(filenameExtension: "docx") { panel.allowedContentTypes = [docx] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !model.exportActiveAsDocx(to: url) {
            let alert = NSAlert()
            alert.messageText = "Couldn't export"
            alert.informativeText = "There's no active text document to export, or the file couldn't be written."
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// TSK-1144 — File ▸ Export as RTF: write the active document (as Markdown) to .rtf.
    @objc func exportActiveAsRTF(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "export.rtf"
        if let rtf = UTType(filenameExtension: "rtf") { panel.allowedContentTypes = [rtf] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !model.exportActiveAsRTF(to: url) {
            let alert = NSAlert()
            alert.messageText = "Couldn't export"
            alert.informativeText = "There's no active text document to export, or the file couldn't be written."
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// TSK-1144 — Copy as RTF: put the active document (as Markdown → RTF) on the clipboard.
    @objc func copyActiveAsRTF(_ sender: Any?) {
        _ = model.copyActiveAsRTF()
    }

    /// TSK-1144 — File ▸ Export as RTFD: write the active document to an .rtfd package.
    @objc func exportActiveAsRTFD(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "export.rtfd"
        if let rtfd = UTType(filenameExtension: "rtfd") { panel.allowedContentTypes = [rtfd] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !model.exportActiveAsRTFD(to: url) {
            let alert = NSAlert()
            alert.messageText = "Couldn't export"
            alert.informativeText = "There's no active text document to export, or the file couldn't be written."
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// TSK-1054 / TSK-1208 — File ▸ New Image: prompt for size + background
    /// color, then create + open a blank image. Defaults are pre-filled so a
    /// quick Return makes an 800×600 white canvas.
    @objc func newImage(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "New Image"
        alert.informativeText = "Size (pixels) and background color."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 84))
        func label(_ s: String, _ y: CGFloat) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.frame = NSRect(x: 0, y: y, width: 60, height: 18)
            return l
        }
        let widthField = NSTextField(string: String(BlankImageCreator.defaultWidth))
        widthField.frame = NSRect(x: 64, y: 58, width: 90, height: 22)
        let heightField = NSTextField(string: String(BlankImageCreator.defaultHeight))
        heightField.frame = NSRect(x: 64, y: 30, width: 90, height: 22)
        let colorWell = NSColorWell(frame: NSRect(x: 64, y: 0, width: 44, height: 24))
        colorWell.color = .white
        accessory.addSubview(label("Width:", 60));  accessory.addSubview(widthField)
        accessory.addSubview(label("Height:", 32)); accessory.addSubview(heightField)
        accessory.addSubview(label("Color:", 4));   accessory.addSubview(colorWell)
        alert.accessoryView = accessory

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let w = max(1, widthField.integerValue)
        let h = max(1, heightField.integerValue)
        let c = colorWell.color.usingColorSpace(.sRGB) ?? .white
        let color = RGBAColor(
            r: UInt8(max(0, min(255, c.redComponent * 255))),
            g: UInt8(max(0, min(255, c.greenComponent * 255))),
            b: UInt8(max(0, min(255, c.blueComponent * 255))),
            a: UInt8(max(0, min(255, c.alphaComponent * 255))))
        model.newBlankImageForLanding(width: w, height: h, color: color)
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

    /// ⇧⌘T. Repeatable — each press walks one step further back through the
    /// close history. Beeps when there is nothing left rather than failing
    /// silently (the menu item is also disabled in that state).
    @objc func reopenClosedTab(_ sender: Any?) {
        if !model.reopenLastClosedTab() { NSSound.beep() }
    }

    @objc func reopenClosedItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        model.reopenClosedTab(url: url)
    }

    @objc func clearRecentlyClosed(_ sender: Any?) {
        model.recentlyClosed.clear()
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
        } else if menu === recentlyClosedMenu {
            rebuildRecentlyClosedMenu(menu)
        } else if menu === windowMenu {
            rebuildWindowMenu(menu)
        } else if menu === sessionJumpMenu {
            rebuildSessionJumpMenu(menu)
        } else if menu === languageMenu {
            rebuildLanguageMenu(menu)
        } else if menu === terminalFavoritesMenu {
            rebuildTerminalFavoritesMenu(menu)
        } else if menu === convertEncodingMenu || menu === convertLineEndingMenu
                    || menu === convertIndentMenu {
            markCurrentFileFormat()
        }
    }

    /// TSK-1480: on Convert-submenu open, mark the active file's CURRENT format
    /// so the user sees what the file IS before converting blind — a check-mark
    /// on the current encoding + line-ending choice, and a "Current: <indent>"
    /// header on the direction-based Indent submenu. Reads the detected facets
    /// off the active tab (cold menu-open path). Pure resolution is host-tested
    /// (FileFormatMenuStateTests); this applies it to the NSMenuItems.
    private func markCurrentFileFormat() {
        let facets = model.activeFileFormatFacets
        let resolution = facets.map {
            FileFormatMenuState.resolve(
                encoding: $0.encoding,
                lineEnding: $0.lineEnding,
                indent: $0.indent,
                encodingChoices: AppDelegate.encodingChoices.map(\.encoding),
                lineEndingChoices: AppDelegate.lineEndingChoices.map(\.ending))
        }
        if let menu = convertEncodingMenu {
            for item in menu.items { item.state = .off }
            if let i = resolution?.checkedEncodingIndex, menu.items.indices.contains(i) {
                menu.items[i].state = .on
            }
        }
        if let menu = convertLineEndingMenu {
            for item in menu.items { item.state = .off }
            if let i = resolution?.checkedLineEndingIndex, menu.items.indices.contains(i) {
                menu.items[i].state = .on
            }
        }
        convertIndentHeaderItem?.title = resolution?.indentHeader ?? "Current: —"
    }

    /// Rebuild the "Terminal Favorites" submenu (TSK-769) from the user's store.
    /// Each favorite inserts its command at the terminal prompt; the footer items
    /// open the hand-editable JSON and reload it.
    private func rebuildTerminalFavoritesMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let favorites = model.terminalFavorites.all
        if favorites.isEmpty {
            let none = NSMenuItem(title: "(no favorites)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for fav in favorites {
                let item = NSMenuItem(
                    title: fav.displayLabel,
                    action: #selector(insertTerminalFavoriteItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = fav.command
                item.toolTip = fav.command
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let edit = NSMenuItem(
            title: "Manage Favorites…", action: #selector(editTerminalFavorites(_:)), keyEquivalent: "")
        edit.target = self
        menu.addItem(edit)
        let reload = NSMenuItem(
            title: "Reload Favorites", action: #selector(reloadTerminalFavorites(_:)), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)
    }

    @objc func insertTerminalFavoriteItem(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        _ = model.insertTerminalFavorite(command)
    }

    @objc func editTerminalFavorites(_ sender: Any?) {
        // TSK-1475: open the GUI management editor (rename / reorder / delete)
        // instead of the old raw-JSON-file edit path.
        model.openTerminalFavoritesEditor()
    }

    @objc func reloadTerminalFavorites(_ sender: Any?) {
        model.terminalFavorites.reload()
    }

    /// Rebuild the "Language Mode" submenu (TSK-753): every highlightable
    /// language, sorted by display name, with a checkmark on the current tab's
    /// effective language. Picking one sets the per-tab override; picking the
    /// auto-detected language clears it (model.setCurrentLanguage's contract).
    /// Disabled placeholder when no file tab is open.
    private func rebuildLanguageMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let current = model.currentEffectiveLanguage else {
            let none = NSMenuItem(title: "No file open", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        for lang in HighlightLanguage.supportedForDisplay {
            let item = NSMenuItem(
                title: lang.displayName,
                action: #selector(setLanguageMode(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = lang.rawValue
            item.state = (lang == current) ? .on : .off
            menu.addItem(item)
        }
    }

    @objc func setLanguageMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let lang = HighlightLanguage(rawValue: raw) else { return }
        model.setCurrentLanguage(lang)
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
        let entries = model.recents.prefix(40)   // doubled 2026-08-01 (I-17)
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

    /// File ▸ Recently Closed. Mirrors `rebuildRecentsMenu`: newest first,
    /// full path in the tooltip so same-named files are distinguishable.
    private func rebuildRecentlyClosedMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let entries = model.recentlyClosed.entries
        if entries.isEmpty {
            let placeholder = NSMenuItem(
                title: "(no recently closed tabs)", action: nil, keyEquivalent: ""
            )
            placeholder.isEnabled = false
            menu.addItem(placeholder)
        } else {
            for entry in entries {
                let item = NSMenuItem(
                    title: entry.displayName,
                    action: #selector(reopenClosedItem(_:)),
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
            action: #selector(clearRecentlyClosed(_:)),
            keyEquivalent: ""
        )
        clear.target = self
        clear.isEnabled = !entries.isEmpty
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
        // TSK-681 — export / import the user preferences as a portable JSON file.
        let exportItem = NSMenuItem(
            title: "Export Settings…", action: #selector(exportSettings(_:)), keyEquivalent: "")
        exportItem.target = self
        appMenu.addItem(exportItem)
        let importItem = NSMenuItem(
            title: "Import Settings…", action: #selector(importSettings(_:)), keyEquivalent: "")
        importItem.target = self
        appMenu.addItem(importItem)
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

        // TSK-329/747: File → New File submenu. Creates an untitled file in the
        // selected folder (or the sidebar root) and opens it. "Text File" keeps
        // ⌘N; the other types (Markdown/CSV/JSON) create an `Untitled.<ext>` so
        // the editor picks the right language. Disabled when no folder is open
        // (validateMenuItem).
        let newFileItem = NSMenuItem(title: "New File", action: nil, keyEquivalent: "")
        let newFileSubmenu = NSMenu(title: "New File")
        for (i, type) in NewFileType.allCases.enumerated() {
            let isText = (type == .text)
            let item = NSMenuItem(
                title: type.title,
                // Text File reuses the existing ⌘N path; the rest route through
                // the typed handler (tag = index into NewFileType.allCases).
                action: isText ? #selector(newFile(_:)) : #selector(newFileOfType(_:)),
                keyEquivalent: isText ? "n" : ""
            )
            item.target = self
            item.tag = i
            newFileSubmenu.addItem(item)
        }
        // TSK-1167: Image is binary (not a text NewFileType), so add it
        // explicitly — it routes to the New Image size/color dialog.
        let newImageSubItem = NSMenuItem(
            title: "Image…", action: #selector(newImage(_:)), keyEquivalent: "")
        newImageSubItem.target = self
        newFileSubmenu.addItem(newImageSubItem)
        newFileItem.submenu = newFileSubmenu
        fileMenu.addItem(newFileItem)

        // TSK-373: File → New Session ▸ Kind. Creates a new session of the
        // chosen kind (Project / Code Review / Agent Session / CI-CD /
        // Metrics), seeding that kind's panel layout. The rows mirror the
        // SwiftUI session-tab `+` menu — both iterate the shared
        // `NewSessionMenuItems.all` source of truth (tag = index into it).
        let newSessionItem = NSMenuItem(title: "New Session", action: nil, keyEquivalent: "")
        let newSessionSubmenu = NSMenu(title: "New Session")
        for (i, entry) in NewSessionMenuItems.all.enumerated() {
            let item = NSMenuItem(
                title: entry.title,
                action: #selector(newSessionOfKind(_:)),
                keyEquivalent: "")
            item.target = self
            item.tag = i
            item.image = NSImage(systemSymbolName: entry.symbolName,
                                 accessibilityDescription: entry.title)
            newSessionSubmenu.addItem(item)
        }
        newSessionItem.submenu = newSessionSubmenu
        fileMenu.addItem(newSessionItem)

        // TSK-935: New Tab from Clipboard — a scratch tab seeded with the
        // clipboard (extension content-detected: JSON → .json, else .txt).
        let newFromClipItem = NSMenuItem(
            title: "New Tab from Clipboard",
            action: #selector(newTabFromClipboard(_:)), keyEquivalent: "")
        newFromClipItem.target = self
        fileMenu.addItem(newFromClipItem)

        // TSK-721: File → New HTTP Request — opens the in-app HTTP request tool
        // (method/URL/headers/body form + response view) in a hosted tab.
        let newHTTPItem = NSMenuItem(
            title: "New HTTP Request",
            action: #selector(newHTTPRequest(_:)), keyEquivalent: "")
        newHTTPItem.target = self
        fileMenu.addItem(newHTTPItem)

        // TSK-1417: File → Feed Reader — opens the RSS/feed reader (subscriptions
        // + OPML import + refresh) in a hosted tab. Was built + host-tested but
        // orphaned (nothing instantiated it); owner chose FINISH → wired here.
        let feedReaderItem = NSMenuItem(
            title: "Feed Reader",
            action: #selector(openFeedReader(_:)), keyEquivalent: "")
        feedReaderItem.target = self
        fileMenu.addItem(feedReaderItem)

        // TSK-1100: File → Dependency Graph — the project's import graph in a
        // hosted tab (surfaces the built-but-unreachable DependencyGraphView).
        let depGraphItem = NSMenuItem(
            title: "Dependency Graph",
            action: #selector(showDependencyGraph(_:)), keyEquivalent: "")
        depGraphItem.target = self
        fileMenu.addItem(depGraphItem)

        // TSK-506: File → Folder Sizes — a size-proportional treemap of the
        // project folder in a hosted tab (surfaces the built-but-unreachable
        // FolderTreemapView).
        let treemapItem = NSMenuItem(
            title: "Folder Sizes (Treemap)",
            action: #selector(showFolderTreemap(_:)), keyEquivalent: "")
        treemapItem.target = self
        fileMenu.addItem(treemapItem)

        // TSK-1500: File → Recover Deleted File… — a picker of recently-opened
        // files that were deleted but still have Local History, each recreated
        // from its latest version (atomic, never-overwrite).
        let recoverItem = NSMenuItem(
            title: "Recover Deleted File…",
            action: #selector(recoverDeletedFile(_:)), keyEquivalent: "")
        recoverItem.target = self
        fileMenu.addItem(recoverItem)

        // TSK-1054: File → New Image — create + open a blank PNG canvas.
        let newImageItem = NSMenuItem(
            title: "New Image", action: #selector(newImage(_:)), keyEquivalent: "")
        newImageItem.target = self
        fileMenu.addItem(newImageItem)

        // TSK-1107: File → Walkthroughs — browse + run saved walkthroughs.
        let walkthroughsItem = NSMenuItem(
            title: "Walkthroughs",
            action: #selector(showWalkthroughsBrowser(_:)), keyEquivalent: "")
        walkthroughsItem.target = self
        fileMenu.addItem(walkthroughsItem)

        // TSK-1121: File → Annotations — a jump-list of the active file's
        // TODO/FIXME/HACK/XXX/NOTE/BUG markers (SourceAnnotationScanner).
        let annotationsItem = NSMenuItem(
            title: "Annotations",
            action: #selector(showAnnotations(_:)), keyEquivalent: "")
        annotationsItem.target = self
        fileMenu.addItem(annotationsItem)

        // TSK-1153: File → Log Patterns — frequency-ranked repeated-line patterns
        // of the active log/text file (LogPatternClusterer).
        let logPatternsItem = NSMenuItem(
            title: "Log Patterns",
            action: #selector(showLogPatterns(_:)), keyEquivalent: "")
        logPatternsItem.target = self
        fileMenu.addItem(logPatternsItem)

        // TSK-1109: File → Package Dependencies — declared deps of the active
        // package.json / Cargo.toml (PackageManifestParser).
        let pkgDepsItem = NSMenuItem(
            title: "Package Dependencies",
            action: #selector(showPackageExplorer(_:)), keyEquivalent: "")
        pkgDepsItem.target = self
        fileMenu.addItem(pkgDepsItem)

        // TSK-1103: File → Local History — save-time version snapshots of the
        // active file (LocalHistoryStore), each viewable read-only.
        let localHistItem = NSMenuItem(
            title: "Local History",
            action: #selector(showLocalHistory(_:)), keyEquivalent: "")
        localHistItem.target = self
        fileMenu.addItem(localHistItem)

        // TSK-1144: File → Export as Word — the active doc (as Markdown) → .docx.
        let exportDocxItem = NSMenuItem(
            title: "Export as Word…",
            action: #selector(exportActiveAsDocx(_:)), keyEquivalent: "")
        exportDocxItem.target = self
        fileMenu.addItem(exportDocxItem)

        let exportRtfItem = NSMenuItem(
            title: "Export as RTF…",
            action: #selector(exportActiveAsRTF(_:)), keyEquivalent: "")
        exportRtfItem.target = self
        fileMenu.addItem(exportRtfItem)

        let exportRtfdItem = NSMenuItem(
            title: "Export as RTFD…",
            action: #selector(exportActiveAsRTFD(_:)), keyEquivalent: "")
        exportRtfdItem.target = self
        fileMenu.addItem(exportRtfdItem)

        let copyRtfItem = NSMenuItem(
            title: "Copy as RTF",
            action: #selector(copyActiveAsRTF(_:)), keyEquivalent: "")
        copyRtfItem.target = self
        fileMenu.addItem(copyRtfItem)

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

        // Recently Closed — the counterpart to Open Recent. ⇧⌘T reopens the
        // most recent (browser chord, repeatable); the submenu lists the rest.
        let reopenItem = NSMenuItem(
            title: "Reopen Closed Tab",
            action: #selector(reopenClosedTab(_:)),
            keyEquivalent: "t"
        )
        reopenItem.target = self
        applyShortcut("file.reopenClosedTab", to: reopenItem)
        fileMenu.addItem(reopenItem)

        let closedItem = NSMenuItem(
            title: "Recently Closed", action: nil, keyEquivalent: ""
        )
        let closedMenu = NSMenu(title: "Recently Closed")
        closedMenu.delegate = self
        closedMenu.autoenablesItems = false
        closedItem.submenu = closedMenu
        recentlyClosedMenu = closedMenu
        fileMenu.addItem(closedItem)

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

        // TSK-936 — Toggle View Only (read-only lock). ⇧⌘L fallback; the
        // CommandRegistry descriptor carries the same default + a checkmark
        // reflects the live lock state (validateMenuItem).
        let viewOnlyItem = NSMenuItem(
            title: "View Only",
            action: #selector(toggleViewOnlyMode(_:)),
            keyEquivalent: "l"
        )
        viewOnlyItem.keyEquivalentModifierMask = [.command, .shift]
        viewOnlyItem.target = self
        applyShortcut("view.toggleViewOnly", to: viewOnlyItem)
        viewMenu.addItem(viewOnlyItem)

        // TSK-698 — View ▸ Script Console: a JQ-style query/transform console over the active
        // buffer (filter/transform a log / JSON / CSV; apply the output to a new tab).
        let scriptConsoleItem = NSMenuItem(
            title: "Script Console…",
            action: #selector(openScriptConsole(_:)),
            keyEquivalent: "")
        scriptConsoleItem.target = self
        viewMenu.addItem(scriptConsoleItem)

        // TSK-1161 — View ▸ Structural Search: AST/structural query over the active buffer.
        let structSearchItem = NSMenuItem(
            title: "Structural Search…",
            action: #selector(openStructuralSearch(_:)),
            keyEquivalent: "")
        structSearchItem.target = self
        viewMenu.addItem(structSearchItem)

        // TSK-1160 — View ▸ Task Runner: discover + run project tasks with captured output.
        let taskRunnerItem = NSMenuItem(
            title: "Task Runner…",
            action: #selector(openTaskRunner(_:)),
            keyEquivalent: "")
        taskRunnerItem.target = self
        viewMenu.addItem(taskRunnerItem)

        // TSK-1176 — View ▸ Terminal Command Palette: search history + favorites, insert at prompt.
        let termPaletteItem = NSMenuItem(
            title: "Terminal Command Palette…",
            action: #selector(openTerminalCommandPalette(_:)),
            keyEquivalent: "")
        termPaletteItem.target = self
        viewMenu.addItem(termPaletteItem)

        // TSK-1325 — View ▸ Convert Image: format/quality conversion of the active image → new tab.
        let convertImageItem = NSMenuItem(
            title: "Convert Image…",
            action: #selector(openConvertImage(_:)),
            keyEquivalent: "")
        convertImageItem.target = self
        viewMenu.addItem(convertImageItem)

        // TSK-1323/1324 — View ▸ Extract Audio from Video / Convert Audio.
        let extractAudioItem = NSMenuItem(
            title: "Extract Audio from Video…",
            action: #selector(openExtractAudio(_:)),
            keyEquivalent: "")
        extractAudioItem.target = self
        viewMenu.addItem(extractAudioItem)
        let convertAudioItem = NSMenuItem(
            title: "Convert Audio…",
            action: #selector(openConvertAudio(_:)),
            keyEquivalent: "")
        convertAudioItem.target = self
        viewMenu.addItem(convertAudioItem)

        // TSK-1116 — View ▸ Focus Mode: one-click workspace presets that pin the
        // sidebar to an activity's panel set + preferred lens (FocusWorkMode).
        let focusItem = NSMenuItem(title: "Focus Mode", action: nil, keyEquivalent: "")
        let focusMenu = NSMenu(title: "Focus Mode")
        for (i, mode) in FocusWorkMode.allCases.enumerated() {
            let mi = NSMenuItem(title: mode.displayName,
                                action: #selector(applyFocusModeMenu(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.image = NSImage(systemSymbolName: mode.systemImage, accessibilityDescription: nil)
            focusMenu.addItem(mi)
        }
        focusItem.submenu = focusMenu
        viewMenu.addItem(focusItem)

        // TSK-899: ⌘1/⌘2/⌘3 select the 1st/2nd/3rd view mode in the current
        // file's mode bar (positional — Rendered/Source/HEX for markdown,
        // Table/Source/HEX for CSV, etc.). Title + enabled state are refreshed
        // per file in validateMenuItem; the slot is a no-op when absent.
        for slot in 0..<3 {
            let item = NSMenuItem(
                title: "View Mode \(slot + 1)",
                action: #selector(selectViewModeSlot(_:)),
                keyEquivalent: "\(slot + 1)")
            item.keyEquivalentModifierMask = [.command]
            item.target = self
            item.tag = slot
            viewMenu.addItem(item)
        }

        let sidebarItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(toggleSidebar(_:)),
            keyEquivalent: "s"
        )
        sidebarItem.target = self
        applyShortcut("view.toggleSidebar", to: sidebarItem)
        viewMenu.addItem(sidebarItem)

        // TSK-753: Language Mode — a dynamic submenu showing the current file's
        // highlight language (checkmark) with every language to override to.
        // Populated on demand via menuNeedsUpdate so it always reflects the
        // focused tab. Items dispatch setLanguageMode → model.setCurrentLanguage.
        viewMenu.addItem(.separator())
        let languageItem = NSMenuItem(title: "Language Mode", action: nil, keyEquivalent: "")
        let langMenu = NSMenu(title: "Language Mode")
        langMenu.delegate = self
        langMenu.autoenablesItems = false
        languageItem.submenu = langMenu
        self.languageMenu = langMenu
        viewMenu.addItem(languageItem)

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

        // Vim Mode — modal editing in the CM6 editor (opt-in; owner-approved
        // 2026-06-15). Checkable, persisted. No default key equivalent — vim
        // owns single-key bindings, so a global shortcut would invite clashes;
        // the toggle lives in the menu only.
        let vimItem = NSMenuItem(
            title: "Vim Mode",
            action: #selector(toggleVimMode(_:)),
            keyEquivalent: ""
        )
        vimItem.target = self
        viewMenu.addItem(vimItem)

        // TSK-936 — Toggle Read-Only: lock the CM6 editor against edits
        // (readOnly facet). Checkable; session-level, not persisted.
        let readOnlyItem = NSMenuItem(
            title: "Toggle Read-Only",
            action: #selector(toggleEditorReadOnly(_:)),
            keyEquivalent: ""
        )
        readOnlyItem.target = self
        viewMenu.addItem(readOnlyItem)

        // Markdown Overview — the scaled document minimap drawn top-right in
        // the source view for markdown files (TSK-305). Checkable, persisted,
        // on by default. No default key equivalent.
        let overviewItem = NSMenuItem(
            title: "Markdown Overview",
            action: #selector(toggleMarkdownOverview(_:)),
            keyEquivalent: ""
        )
        overviewItem.target = self
        viewMenu.addItem(overviewItem)

        // Code folding (Fold All / Unfold All) — enabled in any FOLDABLE lens:
        // the CM6 editor AND the read-only Source view (TSK-948). Greyed in
        // render / preview / hex (`canFoldActiveDocument`). Go to Line is
        // editor-only and validated separately below.
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

        // TSK-769: Terminal Favorites — a dynamic submenu of the user's curated
        // commands, rebuilt on open (menuNeedsUpdate) from the host-tested store.
        // Picking one inserts it at the in-app terminal prompt.
        viewMenu.addItem(.separator())
        let favItem = NSMenuItem(title: "Terminal Favorites", action: nil, keyEquivalent: "")
        let favMenu = NSMenu(title: "Terminal Favorites")
        favMenu.delegate = self
        favItem.submenu = favMenu
        terminalFavoritesMenu = favMenu
        viewMenu.addItem(favItem)

        let paletteItem = NSMenuItem(
            title: "Quick Open…",
            action: #selector(showPalette(_:)),
            keyEquivalent: ""  // TSK-709: ⌘K freed for the terminal; palette = ⇧⌘P + double-Shift
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

        // (Document Statistics / Check Links / Lint Markdown / CSV Summary moved
        // to the Tools menu, and the Copy-as/Export/Open-in-Browser actions to the
        // File ▸ Export/Share submenu — TSK-1413 reorg. View keeps see-the-doc
        // actions only.)

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

        // Focus shortcuts (TSK-937): move keyboard focus to a specific
        // surface. No default key-equivalents — the obvious keys clash with
        // existing bindings (the TSK-936 concern), so these ship as
        // discoverable menu items (+ palette entries) and the user can bind
        // keys via keybinding.json. Each is gated in `validateMenuItem`.
        viewMenu.addItem(.separator())
        let focusTerminalItem = NSMenuItem(
            title: "Focus Terminal",
            action: #selector(focusTerminal(_:)),
            keyEquivalent: ""
        )
        focusTerminalItem.target = self
        applyShortcut("view.focusTerminal", to: focusTerminalItem)
        viewMenu.addItem(focusTerminalItem)

        let focusFileNavItem = NSMenuItem(
            title: "Focus File Navigator",
            action: #selector(focusFileNav(_:)),
            keyEquivalent: ""
        )
        focusFileNavItem.target = self
        applyShortcut("view.focusFileNav", to: focusFileNavItem)
        viewMenu.addItem(focusFileNavItem)

        let focusGitItem = NSMenuItem(
            title: "Focus Git Panel",
            action: #selector(focusGitPanel(_:)),
            keyEquivalent: ""
        )
        focusGitItem.target = self
        applyShortcut("view.focusGit", to: focusGitItem)
        viewMenu.addItem(focusGitItem)

        let focusDocumentItem = NSMenuItem(
            title: "Focus Active File",
            action: #selector(focusActiveDocument(_:)),
            keyEquivalent: ""
        )
        focusDocumentItem.target = self
        applyShortcut("view.focusDocument", to: focusDocumentItem)
        viewMenu.addItem(focusDocumentItem)

        viewMenuItem.submenu = viewMenu

        // TSK-1413 (owner-approved full menu reorg): a dedicated TOOLS menu for
        // document-analysis actions that were cluttering View (which should be
        // about how you SEE the doc). Selectors/targets are unchanged — only the
        // host menu moves — so AppMenuActionsTests still guards that the actions
        // fire. (Export/Share submenu + a Format menu are the follow-on slices.)
        let toolsMenuItem = NSMenuItem()
        let toolsMenu = NSMenu(title: "Tools")
        let docStatsItem = NSMenuItem(
            title: "Document Statistics",
            action: #selector(showDocumentStatistics(_:)), keyEquivalent: "")
        docStatsItem.target = self
        toolsMenu.addItem(docStatsItem)
        let checkLinksItem = NSMenuItem(title: "Check Links",
                                        action: #selector(checkLinks(_:)), keyEquivalent: "k")
        // TSK-1437: ⇧⌘K — matches the registry's file.checkLinks defaultShortcut.
        checkLinksItem.keyEquivalentModifierMask = [.command, .shift]
        checkLinksItem.target = self
        toolsMenu.addItem(checkLinksItem)
        let lintItem = NSMenuItem(title: "Lint Markdown",
                                  action: #selector(lintMarkdown(_:)), keyEquivalent: "")
        lintItem.target = self
        toolsMenu.addItem(lintItem)
        let csvSummaryItem = NSMenuItem(title: "CSV Summary",
                                        action: #selector(showCSVSummary(_:)), keyEquivalent: "")
        csvSummaryItem.target = self
        toolsMenu.addItem(csvSummaryItem)
        // TSK-1571: mount the Claude Session Monitor (a standalone read-only
        // window) as a menu item — it was `--claude-monitor` CLI-flag-only before.
        toolsMenu.addItem(.separator())
        let claudeMonitorItem = NSMenuItem(
            title: "Claude Session Monitor",
            action: #selector(openClaudeMonitor(_:)), keyEquivalent: "")
        claudeMonitorItem.target = self
        toolsMenu.addItem(claudeMonitorItem)
        toolsMenuItem.submenu = toolsMenu
        // (added to mainMenu in the ordered block below, after View)

        // TSK-1413 reorg slice 2: Export/Share actions (rendered-doc export +
        // clipboard conversions) grouped under File ▸ Export / Share, moved OUT of
        // View. `fileMenu` is still in scope from the File section above; selectors
        // are unchanged (AppMenuActionsTests guards them).
        let exportShareItem = NSMenuItem(title: "Export / Share", action: nil, keyEquivalent: "")
        let exportShareMenu = NSMenu(title: "Export / Share")
        // TSK-675: rendered Markdown → standalone HTML (CSP-free, browser-openable).
        let copyHTMLItem = NSMenuItem(title: "Copy as HTML",
                                      action: #selector(copyAsHTML(_:)), keyEquivalent: "")
        copyHTMLItem.target = self
        exportShareMenu.addItem(copyHTMLItem)
        let exportHTMLItem = NSMenuItem(title: "Export as HTML…",
                                        action: #selector(exportAsHTML(_:)), keyEquivalent: "")
        exportHTMLItem.target = self
        exportShareMenu.addItem(exportHTMLItem)
        let openBrowserItem = NSMenuItem(title: "Open in Browser",
                                         action: #selector(openInBrowser(_:)), keyEquivalent: "")
        openBrowserItem.target = self
        exportShareMenu.addItem(openBrowserItem)
        exportShareMenu.addItem(.separator())
        // CSV → clipboard conversions (active .csv/.tsv only).
        let csvMDItem = NSMenuItem(title: "Copy as Markdown Table",
                                   action: #selector(copyCSVAsMarkdownTable(_:)), keyEquivalent: "")
        csvMDItem.target = self
        exportShareMenu.addItem(csvMDItem)
        let csvJSONItem = NSMenuItem(title: "Copy as JSON",
                                     action: #selector(copyCSVAsJSON(_:)), keyEquivalent: "")
        csvJSONItem.target = self
        exportShareMenu.addItem(csvJSONItem)
        // JSON → CSV (active .json whose top level is an array of objects).
        let jsonCSVItem = NSMenuItem(title: "Copy as CSV",
                                     action: #selector(copyJSONAsCSV(_:)), keyEquivalent: "")
        jsonCSVItem.target = self
        exportShareMenu.addItem(jsonCSVItem)
        exportShareItem.submenu = exportShareMenu
        fileMenu.addItem(.separator())
        fileMenu.addItem(exportShareItem)

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
        // TSK-1163 — Universal Paste: open the clipboard's best representation
        // (image/table/rich/plain/file) in a new tab. ⇧⌘V.
        let pasteAsDocItem = NSMenuItem(
            title: "Paste as New Document",
            action: #selector(universalPasteAsDocument(_:)),
            keyEquivalent: "v")
        pasteAsDocItem.keyEquivalentModifierMask = [.command, .shift]
        pasteAsDocItem.target = self
        editMenu.addItem(pasteAsDocItem)
        editMenu.addItem(NSMenuItem(title: "Select All",
            action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())

        // TSK-942/1256: copy an mdv:// reference to the current editor line — or a
        // line-RANGE reference when text is selected — for pasting into an agent
        // chat / comment. Mirrors the `copy-reference` script verb + the ⌘K palette
        // command; ⌘⌥⇧C binding comes from the registry via applyShortcut.
        let copyRefItem = NSMenuItem(
            title: "Copy Reference",
            action: #selector(copyReference(_:)), keyEquivalent: "")
        copyRefItem.target = self
        editMenu.addItem(applyShortcut("edit.copyReference", to: copyRefItem))
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
        // TSK-946: drive the active CUSTOM find bar's next/prev. The old
        // NSTextFinder action (`performFindPanelAction` + a tag) was inert —
        // no surface sets `usesFindBar`, our bars are custom — so ⌘G/⌥⌘G did
        // nothing. Route through DocumentModel to whichever bar is open.
        let findNext = NSMenuItem(
            title: "Find Next",
            action: #selector(findNextInPage(_:)),
            keyEquivalent: "g"
        )
        findNext.target = self
        findSubmenu.addItem(findNext)
        // Note: ⇧⌘G is reserved for "Go to file or folder" (Finder
        // convention) — see File → Go to… below. Find Previous moves
        // to ⌥⌘G to avoid the collision. Power users tend to hit "g"
        // repeatedly with Cmd to step forward and Cmd+Shift to step
        // back; the Option alternative keeps that muscle memory close.
        let findPrev = NSMenuItem(
            title: "Find Previous",
            action: #selector(findPrevInPage(_:)),
            keyEquivalent: "g"
        )
        findPrev.keyEquivalentModifierMask = [.command, .option]
        findPrev.target = self
        findSubmenu.addItem(findPrev)
        findSubmenuItem.submenu = findSubmenu
        // TSK-823 follow-up — LSP editor commands (Format / Rename / Code
        // Actions), editor-mode-gated by validateMenuItem; applyShortcut picks
        // up any user keybinding.
        editMenu.addItem(.separator())
        let lspLangItems: [(String, Selector, String)] = [
            ("Format Document", #selector(lspFormatDocument(_:)), "lsp.format"),
            ("Rename Symbol…", #selector(lspRenameSymbol(_:)), "lsp.rename"),
            ("Code Actions…", #selector(lspCodeActions(_:)), "lsp.codeActions"),
        ]
        for (title, action, id) in lspLangItems {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            editMenu.addItem(applyShortcut(id, to: mi))
        }
        // TSK-1413 reorg slice 3: content-TRANSFORM actions move to a dedicated
        // top-level FORMAT menu (they were cluttering Edit, which is about the
        // clipboard/selection). Selectors unchanged (AppMenuActionsTests guards).
        let formatMenuItem = NSMenuItem()
        let formatMenu = NSMenu(title: "Format")
        // TSK-350: align markdown pipe tables in the active editor (in place —
        // markdown has no format VIEW lens by design). Enabled only for a
        // markdown tab with an editor buffer (validateMenuItem).
        let alignTablesItem = NSMenuItem(
            title: "Align Markdown Tables",
            action: #selector(alignMarkdownTables(_:)), keyEquivalent: "a")
        // TSK-1437: ⌥⌘A — matches the registry's edit.alignTables defaultShortcut
        // (palette/menu parity; pinned by CommandRegistryTests).
        alignTablesItem.keyEquivalentModifierMask = [.command, .option]
        alignTablesItem.target = self
        formatMenu.addItem(alignTablesItem)
        // TSK-352: re-save the active file in a chosen text encoding. Tag =
        // index into `encodingChoices`. Enabled for any active text file.
        let convertItem = NSMenuItem(title: "Convert Encoding", action: nil, keyEquivalent: "")
        let convertMenu = NSMenu(title: "Convert Encoding")
        for (i, choice) in AppDelegate.encodingChoices.enumerated() {
            let mi = NSMenuItem(title: choice.title,
                                action: #selector(convertFileEncoding(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            convertMenu.addItem(mi)
        }
        // TSK-1480: mark the active file's CURRENT encoding on open (check-mark).
        convertMenu.delegate = self
        convertEncodingMenu = convertMenu
        convertItem.submenu = convertMenu
        formatMenu.addItem(convertItem)
        // TSK-675: normalize the active file's line endings (LF/CRLF/CR). Tag =
        // index into `lineEndingChoices`. Enabled for any active text file.
        let eolItem = NSMenuItem(title: "Convert Line Endings", action: nil, keyEquivalent: "")
        let eolMenu = NSMenu(title: "Convert Line Endings")
        for (i, choice) in AppDelegate.lineEndingChoices.enumerated() {
            let mi = NSMenuItem(title: choice.title,
                                action: #selector(convertFileLineEnding(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            eolMenu.addItem(mi)
        }
        // TSK-1480: mark the active file's CURRENT line ending on open.
        eolMenu.delegate = self
        convertLineEndingMenu = eolMenu
        eolItem.submenu = eolMenu
        formatMenu.addItem(eolItem)
        // TSK-675: whitespace cleanup on the active file (line endings preserved).
        let trimWSItem = NSMenuItem(title: "Trim Trailing Whitespace",
                                    action: #selector(trimTrailingWhitespace(_:)), keyEquivalent: "")
        trimWSItem.target = self
        formatMenu.addItem(trimWSItem)
        let finalNLItem = NSMenuItem(title: "Ensure Final Newline",
                                     action: #selector(ensureFinalNewline(_:)), keyEquivalent: "")
        finalNLItem.target = self
        formatMenu.addItem(finalNLItem)
        // TSK-675: convert leading indentation between tabs and spaces (using the
        // editor's indent width). Enabled for any active text file.
        let indentItem = NSMenuItem(title: "Convert Indentation", action: nil, keyEquivalent: "")
        let indentMenu = NSMenu(title: "Convert Indentation")
        // TSK-1480: the Indent submenu offers DIRECTIONS (not values), so a
        // check-mark can't express "current" — instead a disabled header row
        // shows the current indent (updated on open) so the user isn't blind.
        let indentHeader = NSMenuItem(title: "Current: —", action: nil, keyEquivalent: "")
        indentHeader.isEnabled = false
        indentMenu.addItem(indentHeader)
        indentMenu.addItem(.separator())
        convertIndentHeaderItem = indentHeader
        let toSpacesItem = NSMenuItem(title: "Tabs → Spaces",
                                      action: #selector(convertIndentToSpaces(_:)), keyEquivalent: "")
        toSpacesItem.target = self
        indentMenu.addItem(toSpacesItem)
        let toTabsItem = NSMenuItem(title: "Spaces → Tabs",
                                    action: #selector(convertIndentToTabs(_:)), keyEquivalent: "")
        toTabsItem.target = self
        indentMenu.addItem(toTabsItem)
        indentMenu.delegate = self
        convertIndentMenu = indentMenu
        indentItem.submenu = indentMenu
        formatMenu.addItem(indentItem)
        // TSK-675: insert/refresh a Markdown table of contents from the file's
        // headings (idempotent via <!-- toc --> markers). Markdown files only.
        let tocItem = NSMenuItem(title: "Insert Table of Contents",
                                 action: #selector(insertTableOfContents(_:)), keyEquivalent: "o")
        // TSK-1437: ⌥⌘O — matches the registry's edit.insertTOC defaultShortcut.
        tocItem.keyEquivalentModifierMask = [.command, .option]
        tocItem.target = self
        formatMenu.addItem(tocItem)
        // Shift all ATX heading levels (restructure a Markdown doc). Markdown only.
        let promoteItem = NSMenuItem(title: "Promote Headings",
                                     action: #selector(promoteHeadings(_:)), keyEquivalent: "")
        promoteItem.target = self
        formatMenu.addItem(promoteItem)
        let demoteItem = NSMenuItem(title: "Demote Headings",
                                    action: #selector(demoteHeadings(_:)), keyEquivalent: "")
        demoteItem.target = self
        formatMenu.addItem(demoteItem)
        formatMenuItem.submenu = formatMenu
        // (added to mainMenu in the ordered block below, after Edit)
        // Whole-file line operations on the active text file (in place).
        let linesItem = NSMenuItem(title: "Lines", action: nil, keyEquivalent: "")
        let linesMenu = NSMenu(title: "Lines")
        let lineActions: [(String, Selector)?] = [
            ("Sort Ascending (A→Z)", #selector(sortLinesAsc(_:))),
            ("Sort Descending (Z→A)", #selector(sortLinesDesc(_:))),
            ("Reverse", #selector(reverseLines(_:))),
            ("Remove Duplicates", #selector(removeDuplicateLines(_:))),
            nil,
            ("Remove Empty Lines", #selector(removeEmptyLines(_:))),
            ("Collapse Blank Lines", #selector(collapseBlankLines(_:))),
        ]
        for entry in lineActions {
            guard let (title, action) = entry else {
                linesMenu.addItem(.separator()); continue
            }
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            linesMenu.addItem(mi)
        }
        linesItem.submenu = linesMenu
        editMenu.addItem(linesItem)
        // Edit ▸ Transformations (TSK-1113) — TextEdit-parity case transforms.
        let transformItem = NSMenuItem(title: "Transformations", action: nil, keyEquivalent: "")
        let transformMenu = NSMenu(title: "Transformations")
        let transformActions: [(String, Selector)] = [
            ("Make Upper Case", #selector(makeUpperCase(_:))),
            ("Make Lower Case", #selector(makeLowerCase(_:))),
            ("Capitalize", #selector(capitalizeText(_:))),
        ]
        for (title, action) in transformActions {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            transformMenu.addItem(mi)
        }
        transformItem.submenu = transformMenu
        editMenu.addItem(transformItem)
        // Minify the active JSON file (compact; key order + values preserved).
        let minifyJSONItem = NSMenuItem(title: "Minify JSON",
                                        action: #selector(minifyJSON(_:)), keyEquivalent: "")
        minifyJSONItem.target = self
        editMenu.addItem(minifyJSONItem)
        // TSK-705: insert a built-in snippet at the caret. Tag = index into
        // SnippetLibrary.builtIns. Editor-mode only (validateMenuItem).
        let snippetItem = NSMenuItem(title: "Insert Snippet", action: nil, keyEquivalent: "")
        let snippetMenu = NSMenu(title: "Insert Snippet")
        for (i, snip) in model.snippetStore.all.enumerated() {
            let mi = NSMenuItem(title: snip.name,
                                action: #selector(insertSnippet(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            snippetMenu.addItem(mi)
        }
        snippetMenu.addItem(.separator())
        // TSK-705: manage user snippets (list / add / edit / delete).
        let manageSnippetsItem = NSMenuItem(
            title: "Manage Snippets…",
            action: #selector(showSnippetManager(_:)), keyEquivalent: "")
        manageSnippetsItem.target = self
        snippetMenu.addItem(manageSnippetsItem)
        snippetItem.submenu = snippetMenu
        editMenu.addItem(snippetItem)
        editMenu.addItem(.separator())
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
        // TSK-678 — Keyboard Shortcuts reference page (every bound shortcut,
        // grouped + searchable). No key equivalent of its own (kept out of the
        // registry's binding space); reachable from the Help menu.
        helpMenu.addItem(NSMenuItem.separator())
        helpMenu.addItem(NSMenuItem(
            title: "Keyboard Shortcuts",
            action: #selector(showKeyboardShortcuts(_:)),
            keyEquivalent: ""))
        // TSK-1448 — reopen the first-run sample tour any time (collision-safe:
        // a user's own "Welcome to TextView.md" is never overwritten).
        helpMenu.addItem(NSMenuItem(
            title: "Open Sample Document",
            action: #selector(openSampleDocument(_:)),
            keyEquivalent: ""))
        // TSK-1575 — the full capabilities guide, rendered (docs/CAPABILITIES.md).
        helpMenu.addItem(NSMenuItem(
            title: "Capabilities",
            action: #selector(openCapabilities(_:)),
            keyEquivalent: ""))
        // TSK-696 — install the `textview` command-line launcher on PATH.
        helpMenu.addItem(NSMenuItem(
            title: "Install '\(CLILauncher.commandName)' Command…",
            action: #selector(installCLITool(_:)),
            keyEquivalent: ""))
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
        mainMenu.addItem(formatMenuItem)   // TSK-1413: standard App/File/Edit/Format/View order
        mainMenu.addItem(viewMenuItem)
        mainMenu.addItem(toolsMenuItem)    // TSK-1413: app-specific, after View
        // Navigate menu — surfaces the LSP go-to commands (TSK-464 follow-up).
        // Each dispatches the verified-working `navigateViaLSPAtCursor`;
        // `applyShortcut` picks up any user keybinding (none by default —
        // rebind in ~/.textview/keybinding.json).
        let navigateMenuItem = NSMenuItem()
        let navigateMenu = NSMenu(title: "Navigate")
        let navItems: [(String, Selector, String)] = [
            ("Go to Definition", #selector(lspGotoDefinition(_:)), "lsp.gotoDefinition"),
            ("Go to Declaration", #selector(lspGotoDeclaration(_:)), "lsp.gotoDeclaration"),
            ("Go to Type Definition", #selector(lspGotoTypeDefinition(_:)), "lsp.gotoTypeDefinition"),
            ("Go to Implementation", #selector(lspGotoImplementation(_:)), "lsp.gotoImplementation"),
        ]
        for (title, action, id) in navItems {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
            mi.target = self
            navigateMenu.addItem(applyShortcut(id, to: mi))
        }
        // TSK-950: "Find References" was source-view right-click only. Surface it
        // in the Navigate menu (+ palette via lsp.findReferences) — it lists all
        // references in the LSP navigation panel (multi-result, not go-to-first).
        navigateMenu.addItem(.separator())
        let findRefsItem = NSMenuItem(
            title: "Find References",
            action: #selector(lspFindReferences(_:)), keyEquivalent: "")
        findRefsItem.target = self
        navigateMenu.addItem(applyShortcut("lsp.findReferences", to: findRefsItem))
        navigateMenuItem.submenu = navigateMenu
        mainMenu.addItem(navigateMenuItem)
        mainMenu.addItem(sessionMenuItem)
        // WAVE 2b items 4 + 5: the Debug menu (Diagnostics +
        // Instrumentation tool windows) is built ONLY when the diagnostic
        // gate is on (DEBUG build OR `MDV_ENABLE_DIAGNOSTICS=1`). A stock
        // release binary with the env var unset never grows this menu.
        // These windows are never exposed via the MCP tool catalog.
        if DiagnosticGate.isEnabled, let debugMenuItem = buildDebugMenu() {
            mainMenu.addItem(debugMenuItem)
        }
        // TSK-754: a "Plugins" top-level menu materialised from plugin
        // menu-item contributions. Added only when at least one plugin
        // contributed an item (the builder returns nil otherwise), so a
        // host with no menu-contributing plugins shows no empty menu.
        if let pluginMenuItem = buildPluginsMenu() {
            mainMenu.addItem(pluginMenuItem)
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

    /// Build the "Plugins" top-level menu (TSK-754) from the menu-item
    /// contributions registered in `PluginRegistry.shared.menuItems`.
    /// Returns `nil` when no plugin contributed a menu item so callers
    /// skip adding an empty menu. Top-level items come first, then named
    /// submenus (both ordered by the registry's stable ordering).
    ///
    /// Tier B items dispatch through the registry's `invoke` closure (a
    /// `PluginSubprocessHost` call); Tier A items have no `invoke` and are
    /// rendered disabled. Each enabled item gets a unique tag so the
    /// shared `invokePluginMenuItem` selector can route to the right
    /// closure.
    private func buildPluginsMenu() -> NSMenuItem? {
        let model = PluginRegistry.shared.menuItems.menuModel()
        guard !model.isEmpty else { return nil }

        // Rebuild the tag → invoke map from scratch each time the menu is
        // constructed so stale closures from a prior build don't linger.
        pluginMenuInvocations.removeAll()
        var nextTag = 1

        func makeItem(_ item: MenuContributionRegistry.Item) -> NSMenuItem {
            let mi = NSMenuItem(
                title: item.title,
                action: item.enabled ? #selector(invokePluginMenuItem(_:)) : nil,
                keyEquivalent: ""
            )
            if item.enabled,
               let entry = PluginRegistry.shared.menuItems.all.first(where: {
                   $0.pluginID == item.pluginID && $0.itemID == item.itemID
               }),
               let invoke = entry.invoke {
                mi.target = self
                mi.tag = nextTag
                pluginMenuInvocations[nextTag] = invoke
                nextTag += 1
            } else {
                // Tier A (noop) item: no target/action ⇒ disabled.
                mi.isEnabled = false
            }
            return mi
        }

        let pluginsMenuItem = NSMenuItem()
        let pluginsMenu = NSMenu(title: "Plugins")

        for item in model.topLevel {
            pluginsMenu.addItem(makeItem(item))
        }
        if !model.topLevel.isEmpty && !model.submenus.isEmpty {
            pluginsMenu.addItem(.separator())
        }
        for submenu in model.submenus {
            let subItem = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: submenu.title)
            for item in submenu.items {
                sub.addItem(makeItem(item))
            }
            subItem.submenu = sub
            pluginsMenu.addItem(subItem)
        }

        pluginsMenuItem.submenu = pluginsMenu
        return pluginsMenuItem
    }

    /// Dispatch a selected plugin menu item to its contributed `invoke`
    /// closure (TSK-754). The item's `tag` keys into `pluginMenuInvocations`.
    @objc func invokePluginMenuItem(_ sender: NSMenuItem) {
        guard let invoke = pluginMenuInvocations[sender.tag] else { return }
        invoke()
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

        // TSK-931: rename the active session from the menu bar (the session-tab
        // right-click already offers inline rename; this is the menu surface the
        // owner also asked for).
        let renameItem = NSMenuItem(
            title: "Rename Session…",
            action: #selector(renameSession(_:)), keyEquivalent: "")
        renameItem.target = self
        menu.addItem(renameItem)

        // TSK-755: Tab operations — a discoverability section grouping the
        // open-file tab commands in the Session menu. The keyboard shortcuts
        // live on File (New/Close Tab) and Window (Next/Previous/Move Tab);
        // these entries carry NO key equivalents so they never collide, and
        // dispatch the SAME `@objc` actions via the responder chain (each
        // `#selector` is compile-checked against this AppDelegate's methods).
        menu.addItem(.separator())
        let tabHeader = NSMenuItem(title: "Tab Operations", action: nil, keyEquivalent: "")
        tabHeader.isEnabled = false
        menu.addItem(tabHeader)
        let tabItems: [(String, Selector)] = [
            ("New Tab", #selector(newTab(_:))),
            ("Close Tab", #selector(closeCurrentTab(_:))),
            ("Next Tab", #selector(nextTab(_:))),
            ("Previous Tab", #selector(previousTab(_:))),
            ("Move Tab Left", #selector(moveTabLeft(_:))),
            ("Move Tab Right", #selector(moveTabRight(_:))),
        ]
        for (title, selector) in tabItems {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

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

    /// TSK-681 — export the user preferences to a portable JSON file.
    @objc func exportSettings(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "Export Settings"
        panel.nameFieldStringValue = "TextView Settings.json"
        panel.allowedContentTypes = [.json]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(model.preferencesStore.exportSettings())
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t Export Settings"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// TSK-681 — import preferences from a previously-exported JSON file.
    @objc func importSettings(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Import Settings"
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        do {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(SettingsSnapshot.self, from: data)
            model.preferencesStore.applySettings(snapshot)
            alert.messageText = "Settings Imported"
            alert.informativeText = "Your preferences were imported. Some changes take "
                + "effect the next time you open a file or relaunch TextView."
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t Import Settings"
            alert.informativeText = "This file isn’t a valid TextView settings export.\n\n"
                + error.localizedDescription
        }
        alert.runModal()
    }

    // TSK-464 follow-up — surface the LSP navigation commands (which already
    // dispatch to `navigateViaLSPAtCursor`, palette/keybinding-only until now)
    // as a discoverable Navigate menu. Each is a safe no-op (returns false)
    // when there's no editor cursor / language server.
    @objc func lspGotoDefinition(_ sender: Any?) {
        _ = model.navigateViaLSPAtCursor(kind: .definition)
    }
    @objc func lspGotoDeclaration(_ sender: Any?) {
        _ = model.navigateViaLSPAtCursor(kind: .declaration)
    }
    @objc func lspGotoTypeDefinition(_ sender: Any?) {
        _ = model.navigateViaLSPAtCursor(kind: .typeDefinition)
    }
    @objc func lspGotoImplementation(_ sender: Any?) {
        _ = model.navigateViaLSPAtCursor(kind: .implementation)
    }
    /// TSK-950 — "Find References" at the active editor cursor → LSP navigation
    /// panel. Safe no-op (returns false) without an editor cursor / language server.
    @objc func lspFindReferences(_ sender: Any?) {
        _ = model.findReferencesAtCursor()
    }

    // TSK-823 follow-up — the remaining LSP editor commands (format/rename/
    // code-actions, TSK-627/640) worked via palette/keybinding but had no menu.
    // Each guards internally (safe no-op without an editor / language server).
    @objc func lspFormatDocument(_ sender: Any?) {
        _ = model.formatActiveEditorViaLSP()
    }
    @objc func lspRenameSymbol(_ sender: Any?) {
        model.showLSPRenamePrompt()
    }
    @objc func lspCodeActions(_ sender: Any?) {
        model.showCodeActionPicker()
    }
    /// TSK-350 — align markdown pipe tables in the active editor (in place).
    @objc func alignMarkdownTables(_ sender: Any?) {
        _ = model.formatMarkdownTablesInActiveEditor()
    }

    /// TSK-942/1256 — copy an `mdv://` reference for the current editor line, or a
    /// line-RANGE reference when text is selected, to the clipboard (for pasting
    /// into an agent chat / comment). Mirrors the `copy-reference` script verb.
    @objc func copyReference(_ sender: Any?) {
        guard let ref = model.currentSelectionReference() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ref, forType: .string)
    }

    /// TSK-352 — the "Convert Encoding" submenu choices (title + target
    /// encoding). Menu-item `tag` indexes this array. UTF-16 is the BOM-ful
    /// variant so a reopen re-detects it (the explicit-endian forms are
    /// BOM-less — see TSK-861).
    static let encodingChoices: [(title: String, encoding: String.Encoding)] = [
        ("UTF-8", .utf8),
        ("UTF-16", .utf16),
        ("Western (Windows-1252)", .windowsCP1252),
        ("Western (ISO Latin-1)", .isoLatin1),
    ]
    /// TSK-352 — re-save the active file in the chosen encoding.
    @objc func convertFileEncoding(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? 0
        let choices = AppDelegate.encodingChoices
        guard choices.indices.contains(tag) else { return }
        _ = model.convertActiveFileEncoding(to: choices[tag].encoding)
    }

    /// TSK-675 — line-ending convention choices for the Convert Line Endings menu.
    static let lineEndingChoices: [(title: String, ending: LineEnding)] = [
        ("LF (Unix / macOS)", .lf),
        ("CRLF (Windows)", .crlf),
        ("CR (Classic Mac OS)", .cr),
    ]
    /// TSK-675 — normalize the active file's line endings to the chosen convention.
    @objc func convertFileLineEnding(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? 0
        let choices = AppDelegate.lineEndingChoices
        guard choices.indices.contains(tag) else { return }
        _ = model.convertActiveFileLineEnding(to: choices[tag].ending)
    }

    /// TSK-675 — strip trailing spaces/tabs from every line of the active file.
    @objc func trimTrailingWhitespace(_ sender: Any?) {
        _ = model.trimTrailingWhitespaceInActiveFile()
    }
    /// TSK-675 — ensure the active file ends with a final newline.
    @objc func ensureFinalNewline(_ sender: Any?) {
        _ = model.ensureFinalNewlineInActiveFile()
    }
    /// TSK-675 — convert the active file's leading indentation to spaces / tabs.
    @objc func convertIndentToSpaces(_ sender: Any?) {
        _ = model.convertActiveFileIndentation(toSpaces: true)
    }
    @objc func convertIndentToTabs(_ sender: Any?) {
        _ = model.convertActiveFileIndentation(toSpaces: false)
    }

    /// TSK-675 — insert/refresh a Markdown table of contents in the active file.
    @objc func insertTableOfContents(_ sender: Any?) {
        _ = model.insertTableOfContents()
    }

    /// Compact the active JSON file (whitespace-strip; order + values preserved).
    @objc func minifyJSON(_ sender: Any?) {
        _ = model.minifyActiveJSON()
    }

    /// Promote (fewer #) / demote (more #) all ATX headings in the active Markdown.
    @objc func promoteHeadings(_ sender: Any?) { _ = model.shiftActiveMarkdownHeadings(by: -1) }
    @objc func demoteHeadings(_ sender: Any?) { _ = model.shiftActiveMarkdownHeadings(by: 1) }

    /// Edit ▸ Transformations (TSK-1113) — TextEdit-parity case transforms over the active file.
    @objc func makeUpperCase(_ sender: Any?) { _ = model.makeActiveFileUpperCase() }
    @objc func makeLowerCase(_ sender: Any?) { _ = model.makeActiveFileLowerCase() }
    @objc func capitalizeText(_ sender: Any?) { _ = model.capitalizeActiveFile() }

    /// Edit ▸ Lines — whole-file line operations on the active text file.
    @objc func sortLinesAsc(_ sender: Any?) { _ = model.sortActiveFileLines(ascending: true) }
    @objc func sortLinesDesc(_ sender: Any?) { _ = model.sortActiveFileLines(ascending: false) }
    @objc func reverseLines(_ sender: Any?) { _ = model.reverseActiveFileLines() }
    @objc func removeDuplicateLines(_ sender: Any?) { _ = model.removeDuplicateActiveFileLines() }
    @objc func removeEmptyLines(_ sender: Any?) { _ = model.removeEmptyActiveFileLines() }
    @objc func collapseBlankLines(_ sender: Any?) { _ = model.collapseBlankActiveFileLines() }

    /// TSK-675 — report broken local links/images in the active Markdown file.
    @objc func checkLinks(_ sender: Any?) {
        // TSK-1434: results go to the shared non-modal panel (click-to-line).
        _ = model.runCheckLinksToPanel()
    }

    /// Copy the active CSV as a Markdown pipe table.
    @objc func copyCSVAsMarkdownTable(_ sender: Any?) {
        guard let md = model.activeCSVAsMarkdownTable() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
    }

    /// Copy the active CSV as a JSON array of objects.
    @objc func copyCSVAsJSON(_ sender: Any?) {
        guard let json = model.activeCSVAsJSON() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
    }

    /// Copy the active JSON (array of objects) as CSV.
    @objc func copyJSONAsCSV(_ sender: Any?) {
        guard model.canMinifyActiveJSON else { return }
        guard let csv = model.activeJSONAsCSV() else {
            let alert = NSAlert()
            alert.messageText = "Can't convert to CSV"
            alert.informativeText = "Copy as CSV needs a JSON file whose top level is an array of objects, e.g. [{\"a\":1},{\"a\":2}]."
            alert.alertStyle = .warning
            alert.runModal()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(csv, forType: .string)
    }

    /// Show a profile of the active CSV (row/column counts + per-column stats).
    @objc func showCSVSummary(_ sender: Any?) {
        // TSK-1434: results go to the shared non-modal panel.
        _ = model.runCSVSummaryToPanel()
    }

    /// Lint the active Markdown for common doc-quality issues.
    @objc func lintMarkdown(_ sender: Any?) {
        // TSK-1434: results go to the shared non-modal panel (click-to-line).
        _ = model.runLintToPanel()
    }

    /// TSK-675 — copy the active Markdown rendered as standalone HTML to the clipboard.
    @objc func copyAsHTML(_ sender: Any?) {
        guard let html = model.htmlExportForActiveMarkdown() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(html, forType: .string)
    }

    /// Open the rendered Markdown (self-contained) in the default browser.
    @objc func openInBrowser(_ sender: Any?) {
        guard let url = model.writeActiveMarkdownPreviewHTML() else { return }
        NSWorkspace.shared.open(url)
    }

    /// TSK-675 — export the active Markdown as a standalone .html file
    /// (self-contained: local images inlined so the file stays portable).
    @objc func exportAsHTML(_ sender: Any?) {
        guard let html = model.htmlExportForActiveMarkdown(inlineImages: true) else { return }
        let panel = NSSavePanel()
        panel.title = "Export as HTML"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = model.htmlExportFilename
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try Data(html.utf8).write(to: dest, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't export HTML"
            alert.informativeText = String(describing: error)
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// TSK-675 — show word/character/line counts for the active file.
    @objc func showDocumentStatistics(_ sender: Any?) {
        // TSK-1434: results go to the shared non-modal panel.
        _ = model.runDocStatsToPanel()
    }

    /// TSK-705 — insert the snippet (built-in or user-defined) at the menu
    /// item's tag (index into `snippetStore.all`).
    @objc func insertSnippet(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? -1
        let snips = model.snippetStore.all
        guard snips.indices.contains(tag) else { return }
        _ = model.insertSnippet(snips[tag])
    }

    /// Edit → Manage Snippets… (TSK-705) — open (or re-focus) the snippet
    /// management window: list / add / edit / delete user snippets. Mirrors the
    /// other retained tool windows. Newly-added user snippets join the Insert
    /// Snippet submenu on next launch (the submenu is built once at startup).
    @objc func showSnippetManager(_ sender: Any?) {
        if let win = snippetManagerWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let managerModel = SnippetManagerModel(store: model.snippetStore)
        let host = NSHostingController(rootView: SnippetManagerView(
            model: managerModel,
            onInsert: { [weak self] snippet in
                // TSK-1461 — one-keystroke insert from the manager. Routed
                // through the SAME command path as the Insert Snippet menu
                // (stamped one-shot + tab-stop session, TSK-1483); outcome is
                // surfaced via the standard toast feedback lane.
                guard let self else { return }
                if self.model.insertSnippet(snippet) {
                    ToastCenter.shared.post(
                        .success, "Inserted \u{201C}\(snippet.name)\u{201D}")
                } else {
                    ToastCenter.shared.postError(
                        "Couldn\u{2019}t insert \u{201C}\(snippet.name)\u{201D}",
                        reason: "Open a file in Editor mode first.")
                }
            },
            onDismiss: { [weak self] in self?.snippetManagerWindow?.close() }
        ))
        let win = makeToolWindow(
            title: "Manage Snippets", contentSize: NSSize(width: 680, height: 540),
            autosave: "SnippetManagerWindow", controller: host
        )
        snippetManagerWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        case #selector(newFile(_:)), #selector(newFileOfType(_:)):
            // TSK-329/747: needs a folder to create into (selected dir or root).
            return model.newFileTargetDirectory != nil
        case #selector(renameSession(_:)):
            // TSK-931: only when there's an active session to rename.
            return sessions.active != nil
        case #selector(newTabFromClipboard(_:)):
            // TSK-935: only when the clipboard has text.
            return model.canNewTabFromClipboard
        case #selector(reopenClosedTab(_:)):
            // Nothing closed yet this run → nothing to bring back.
            return !model.recentlyClosed.isEmpty
        case #selector(selectViewModeSlot(_:)):
            // TSK-899: name the slot after the current file's Nth mode + enable
            // only when that slot exists. Keeps ⌘1/⌘2/⌘3 mapped to the bar.
            let modes = model.availableViewModes
            let slot = item.tag
            if modes.indices.contains(slot) {
                item.title = "Show \(modes[slot].displayName)"
                return true
            }
            item.title = "View Mode \(slot + 1)"
            return false
        case #selector(printRenderedPage(_:)), #selector(exportRenderedPDF(_:)):
            return model.canPrintRenderedPage
        case #selector(toggleViewMode(_:)):
            // Rendered/Source toggle only meaningful for markdown.
            item.title = (model.currentViewMode == .source) ? "Show Rendered" : "Show Source"
            return model.supportsViewModeToggle
        case #selector(toggleViewOnlyMode(_:)):
            // TSK-936: checkmark reflects the live read-only lock; enabled
            // whenever a tab is selected (no-op on always-read-only Render).
            item.state = model.viewModePresentation.viewOnly ? .on : .off
            return model.tabs.selected != nil
        case #selector(toggleFormat(_:)):
            // Format only when the current file has a registered formatter.
            // TSK-904: name the concrete format ("Pretty-Print JSON") so it's
            // discoverable when scanning the menu for "JSON" / "XML".
            item.title = model.formatToggleMenuTitle
            item.state = model.isCurrentTabFormatted ? .on : .off
            return model.supportsFormatToggle
        case #selector(toggleSourceWordWrap(_:)):
            item.state = model.sourceWordWrap ? .on : .off
            return hasFile
        case #selector(toggleShowInvisibleChars(_:)):
            item.state = model.showInvisibleChars ? .on : .off
            return hasFile
        case #selector(toggleVimMode(_:)):
            item.state = model.vimModeEnabled ? .on : .off
            return true   // a global editor preference — settable anytime
        case #selector(toggleEditorReadOnly(_:)):
            item.state = model.isEditorReadOnly ? .on : .off
            return hasFile   // TSK-936: only meaningful with an open editable file
        case #selector(toggleMarkdownOverview(_:)):
            item.state = model.showMarkdownOverview ? .on : .off
            return true   // a global view preference — settable anytime
        case #selector(cmFoldAll(_:)), #selector(cmUnfoldAll(_:)):
            // TSK-948: Fold All / Unfold All work in any FOLDABLE lens — the
            // editable CM6 editor AND the read-only Source view (both carry a
            // fold model). Enabled iff the active lens supports folding; greyed
            // in render / preview / hex / table / diff / formatted. (Previously
            // grouped with the editor-only LSP items, so it was dead in Source.)
            return model.canFoldActiveDocument
        case #selector(cmGotoLine(_:)),
             #selector(lspGotoDefinition(_:)), #selector(lspGotoDeclaration(_:)),
             #selector(lspGotoTypeDefinition(_:)), #selector(lspGotoImplementation(_:)),
             #selector(lspFindReferences(_:)),
             #selector(lspFormatDocument(_:)), #selector(lspRenameSymbol(_:)),
             #selector(lspCodeActions(_:)):
            // LSP go-to/references/format/rename/code-actions operate on the
            // EDITOR cursor/buffer, so they're editor-mode-only — gray out elsewhere.
            return hasTab && model.currentViewMode == .editor
                && CodeMirrorEditorRegistry.shared.current() != nil
        case #selector(alignMarkdownTables(_:)):
            // TSK-350: only for a markdown tab with a live editor buffer.
            return model.canAlignMarkdownTables
        case #selector(copyReference(_:)):
            // TSK-942: needs an active file to build a reference from.
            return hasFile
        case #selector(convertFileEncoding(_:)):
            // TSK-352: any active text file.
            return model.canConvertActiveFileEncoding
        case #selector(convertFileLineEnding(_:)):
            // TSK-675: any active text file.
            return model.canConvertActiveFileLineEnding
        case #selector(trimTrailingWhitespace(_:)), #selector(ensureFinalNewline(_:)),
             #selector(convertIndentToSpaces(_:)), #selector(convertIndentToTabs(_:)),
             #selector(sortLinesAsc(_:)), #selector(sortLinesDesc(_:)),
             #selector(reverseLines(_:)), #selector(removeDuplicateLines(_:)),
             #selector(removeEmptyLines(_:)), #selector(collapseBlankLines(_:)),
             #selector(makeUpperCase(_:)), #selector(makeLowerCase(_:)),
             #selector(capitalizeText(_:)):
            // TSK-675 / TSK-1113: any active text file.
            return model.canCleanUpActiveFile
        case #selector(showDocumentStatistics(_:)):
            // TSK-675: any active text file.
            return model.activeDocumentStats != nil
        case #selector(insertTableOfContents(_:)):
            // TSK-675: active Markdown file only.
            return model.canInsertTableOfContents
        case #selector(promoteHeadings(_:)), #selector(demoteHeadings(_:)):
            // active Markdown file only.
            return model.canShiftMarkdownHeadings
        case #selector(minifyJSON(_:)), #selector(copyJSONAsCSV(_:)):
            // Active .json file only.
            return model.canMinifyActiveJSON
        case #selector(copyAsHTML(_:)), #selector(exportAsHTML(_:)), #selector(openInBrowser(_:)):
            // TSK-675: active Markdown file only.
            return model.canExportActiveAsHTML
        case #selector(checkLinks(_:)), #selector(lintMarkdown(_:)):
            // active Markdown file only.
            return model.canCheckLinks
        case #selector(copyCSVAsMarkdownTable(_:)), #selector(copyCSVAsJSON(_:)),
             #selector(showCSVSummary(_:)):
            // active .csv/.tsv file only.
            return model.canConvertActiveCSV
        case #selector(insertSnippet(_:)):
            // TSK-705: editor mode only (inserts at the caret).
            return model.canInsertSnippet
        case #selector(toggleBookmark(_:)):
            item.title = model.isCurrentTabBookmarked
                ? "Remove Bookmark"
                : "Bookmark This"
            return model.bookmarkTargetURL != nil
        case #selector(findNextInPage(_:)), #selector(findPrevInPage(_:)):
            // TSK-946: only steppable while a find bar is actually open.
            return model.canFindNextPrev
        case #selector(replaceInPage(_:)):
            // TSK-949: Find & Replace greys out unless the editor is active
            // (replace is editor-only; no more silent degrade-to-find).
            return model.canFindAndReplace
        case #selector(findInPage(_:)):
            // TSK-947: needs a tab AND find must be available (greyed in
            // HTML-rendered mode — no find runtime / no hosted bar).
            return hasTab && model.canFindInPage
        case #selector(focusTerminal(_:)):
            // TSK-937: only when the terminal pane is open.
            return model.canFocusTerminal
        case #selector(focusFileNav(_:)):
            // TSK-937: only when a folder root is open (the Files tree).
            return model.canFocusFileNav
        case #selector(focusGitPanel(_:)):
            // TSK-937: only when a repo is open under the active root.
            return model.canFocusGitPanel
        case #selector(focusActiveDocument(_:)):
            // TSK-937: only when there's an active document tab.
            return model.canFocusActiveDocument
        case #selector(reloadCurrentFile(_:)),
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

    // MARK: - Focus shortcuts (TSK-937)
    //
    // Each moves keyboard focus to a specific surface; `validateMenuItem`
    // greys the item out when its target surface isn't currently available.

    /// Focus Terminal — opens the pane if closed and takes its first responder.
    @objc func focusTerminal(_ sender: Any?) {
        model.focusTerminal()
    }

    /// Focus File Navigator — reveals the sidebar's Files tree and focuses it.
    @objc func focusFileNav(_ sender: Any?) {
        model.focusFileNav()
    }

    /// Focus Git Panel — expands + focuses the sidebar Git section (Status tab).
    @objc func focusGitPanel(_ sender: Any?) {
        model.focusGitPanel()
    }

    /// Focus Active File — moves focus to the active document surface.
    @objc func focusActiveDocument(_ sender: Any?) {
        model.focusActiveDocument()
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

    /// Open (or re-focus) the Keyboard Shortcuts help window (TSK-678) — every
    /// bound shortcut from the effective `CommandRegistry` (built-in defaults +
    /// the user's `keybinding.json` overrides), grouped + searchable. Always
    /// available (no diagnostic gate); it's a user-facing help page.
    /// TSK-1448 — Help ▸ Open Sample Document: write + open the first-run tour.
    @objc func openSampleDocument(_ sender: Any?) {
        model.openFirstRunSample()
    }

    /// TSK-1575 — Help ▸ Capabilities: open the bundled capabilities guide rendered.
    @objc func openCapabilities(_ sender: Any?) {
        model.openCapabilities()
    }

    @objc func showKeyboardShortcuts(_ sender: Any?) {
        if let win = keyboardShortcutsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(
            rootView: KeyboardShortcutsView(registry: model.commandRegistry))
        let win = makeToolWindow(
            title: "Keyboard Shortcuts", contentSize: NSSize(width: 460, height: 600),
            autosave: "KeyboardShortcutsWindow", controller: host
        )
        keyboardShortcutsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Install the `textview` command-line launcher (TSK-696). Prefers
    /// `/usr/local/bin` (on the default PATH); if that isn't writable, falls
    /// back to a per-user dir and tells the user the one PATH step. The wrapper
    /// just `open -a`s this bundle, so files route through `application(_:open:)`.
    @objc func installCLITool(_ sender: Any?) {
        let appPath = Bundle.main.bundlePath
        let alert = NSAlert()
        do {
            let preferred = CLILauncher.preferredBinDir
            if FileManager.default.isWritableFile(atPath: preferred.path) {
                let dest = try CLILauncher.install(appPath: appPath, into: preferred)
                alert.messageText = "Command-Line Tool Installed"
                alert.informativeText = "Installed ‘\(CLILauncher.commandName)’ at \(dest.path).\n\n"
                    + "Run ‘\(CLILauncher.commandName) <file>’ from a terminal to open files in TextView."
            } else {
                let fallback = CLILauncher.fallbackBinDir()
                let dest = try CLILauncher.installCreatingDir(appPath: appPath, into: fallback)
                alert.messageText = "Command-Line Tool Installed"
                alert.informativeText =
                    "/usr/local/bin isn’t writable, so ‘\(CLILauncher.commandName)’ was installed at:\n"
                    + "\(dest.path)\n\nAdd its folder to your PATH:\n"
                    + "  export PATH=\"\(fallback.path):$PATH\"\n\n"
                    + "…or copy it with admin rights:\n  sudo cp \(dest.path) /usr/local/bin/"
            }
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t Install Command-Line Tool"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
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
        // TSK-1248: when the user is editing a CONTROL's text field (the sidebar
        // file-nav filter, a rename/goto prompt), ⌘F belongs to that field — don't
        // steal focus to open the document find bar over it. (A find bar already
        // open is exempt so ⌘F still toggles IT closed — see the model method.)
        if model.shouldDeferFindToFocusedField(NSApp.keyWindow?.firstResponder) { return }
        // TSK-947 / parity B5: ⌘F is a clean no-op in HTML-rendered mode (no
        // find runtime, no hosted bar) — guarding here stops the old flip of an
        // INVISIBLE rendered-find bar, and never falls through to the source bar.
        guard model.canFindInPage else { return }
        // Cmd+F TOGGLES the find bar for the active surface (TSK-739): a second
        // press closes it. Each branch routes to the matching bar's toggle.
        // Rendered markdown — only meaningful when the file is markdown
        // and the user is viewing the rendered side.
        // Route ⌘F to the matching bar for the active surface. Pure decision
        // (FindBarRouting, host-tested) so the branch order can't silently regress
        // — the PDF branch (TSK-1140) is what stops ⌘F falling through to the
        // useless source bar on a .pdf tab.
        switch FindBarRouting.target(
            viewMode: model.currentViewMode,
            category: model.currentCategory,
            supportsViewModeToggle: model.supportsViewModeToggle) {
        case .rendered: model.toggleRenderedFindBar()
        case .editor:   model.toggleEditorFindBar()
        case .pdf:      model.togglePdfFindBar()
        case .source:   model.toggleSourceFindBar()
        }
    }

    /// Cmd+Option+F — Find & Replace. Replace only works on the editable CM6
    /// editor surface; the rendered and source views are read-only. The menu
    /// item is greyed outside the editor (`canFindAndReplace`, TSK-949), so
    /// this fires only in editor mode — no more silent degrade-to-find.
    @objc func replaceInPage(_ sender: Any?) {
        guard model.currentViewMode == .editor else { return }
        model.showEditorReplaceBar()
    }

    /// ⌘G / ⌥⌘G — step the active find bar's match cursor (TSK-946). No-op
    /// (and the menu item greys via `canFindNextPrev`) when no bar is open.
    @objc func findNextInPage(_ sender: Any?) {
        model.findNext()
    }

    @objc func findPrevInPage(_ sender: Any?) {
        model.findPrev()
    }

    // MARK: - Editor-mode menu items (CM6 Phase 2)

    @objc func toggleShowInvisibleChars(_ sender: Any?) {
        model.toggleShowInvisibleChars()
    }

    @objc func toggleEditorReadOnly(_ sender: Any?) {
        model.toggleEditorReadOnly()
    }

    @objc func toggleVimMode(_ sender: Any?) {
        model.toggleVimMode()
    }

    @objc func toggleMarkdownOverview(_ sender: Any?) {
        model.toggleMarkdownOverview()
    }

    /// View → Fold All. Routes through the model so the command reaches the
    /// active foldable lens — CM6 in `.editor`, the read-only Source view in
    /// `.source` (previously editor-only, so it did nothing in Source). The
    /// model gates on `canFoldActiveDocument` (same as the menu validation).
    @objc func cmFoldAll(_ sender: Any?) {
        model.foldAllActiveDocument()
    }

    @objc func cmUnfoldAll(_ sender: Any?) {
        model.unfoldAllActiveDocument()
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
    /// TSK-1544: start the GUI instance's socket MCP endpoint. Quiet on
    /// success (stderr is the user's terminal only when launched by hand);
    /// loud-but-non-fatal on failure — the app must never refuse to launch
    /// because an automation socket couldn't bind.
    @MainActor
    fileprivate func startMCPSocketListener() {
        let listener = MCPSocketListener(host: model)
        do {
            try listener.start()
            mcpSocketListener = listener
        } catch {
            FileHandle.standardError.write(
                Data("mcp: socket listener failed to start: \(error)\n".utf8))
        }
    }

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
    /// Build a fresh monitor window (shared by launch mode + the menu). Publishes
    /// the WindowServer windowid ONLY in launch mode (`publishWindowId`), so a
    /// menu-opened monitor doesn't clobber the main window's windowid file.
    @MainActor
    private func makeClaudeMonitorWindow(publishWindowId: Bool) -> NSWindow {
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
        if publishWindowId, let identifier = Bundle.main.bundleIdentifier {
            let url = ArtifactDir.url
                .appendingPathComponent("\(identifier).windowid")
            try? "\(window.windowNumber)".write(
                to: url, atomically: true, encoding: .utf8)
        }
        return window
    }

    /// `--claude-monitor` launch mode: the monitor is the app's ONLY window, so
    /// it stays on `self.window` (and publishes the windowid for the T5 lane).
    @MainActor
    fileprivate func openClaudeMonitorWindow() {
        let window = makeClaudeMonitorWindow(publishWindowId: true)
        showWindow(window)
        self.window = window
        activateIfForeground()
    }

    /// TSK-1571: open the monitor from the Tools menu. Re-focuses the existing
    /// monitor if one is already open (no duplicates) and — crucially — retains
    /// it on `monitorWindow`, NOT `self.window`, so the main doc window's
    /// reference survives.
    @MainActor
    fileprivate func openClaudeMonitorFromMenu() {
        if let existing = monitorWindow, existing.isVisible {
            showWindow(existing)
            activateIfForeground()
            return
        }
        let window = makeClaudeMonitorWindow(publishWindowId: false)
        monitorWindow = window
        showWindow(window)
        activateIfForeground()
    }

    @objc func openClaudeMonitor(_ sender: Any?) {
        openClaudeMonitorFromMenu()
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

// TSK-1243/1247: deliver the VM-GUI-lane launch config at the VERY START of
// module execution — BEFORE the env-mode detection below and before app.run().
// A LaunchServices launch under `sudo -u` delivers neither the `open --env` vars
// NOR (verified) an AppDelegate.didFinishLaunching that runs our config-read (the
// /tmp config file was left UNconsumed when the read lived there). Module-scope
// code provably runs (app.run() at the bottom does → the app launches), so read
// the harness's config file + setenv each knob HERE; every downstream
// ProcessInfo.environment read (skip-restore @ ~378, artifact dir, script path)
// then sees them. Absent in prod ⇒ no-op.
AppDelegate.applyLaunchConfigFileIfPresent()

// TSK-1544: `--mcp-connect` — bridge stdio to the RUNNING app's MCP socket.
// A pure byte pump. ⚠️ THIS BRANCH MUST RUN BEFORE `NSApplication.shared`
// (below): touching AppKit registers this process with LaunchServices as an
// instance of TextView.app, and Finder then tries to ACTIVATE the windowless
// bridge instead of launching the real app — `open` fails with -600 and the
// owner "can't open" the app (P0 incident 2026-07-07; guarded by
// MCPBridgeLaunchOrderTests). When no app is listening, fall through as a
// headless `--mcp-stdio` server so one client config works either way.
let mcpConnectMode = CommandLine.arguments.contains("--mcp-connect")
if mcpConnectMode,
   let sock = MCPSocketBridge.connect(path: MCPSocketListener.defaultSocketPath()) {
    FileHandle.standardError.write(Data("mcp: bridged to the running app\n".utf8))
    // P0 zombie guard: orphan-held pipe ends can keep stdin from EOFing
    // after the client dies — self-reap when the parent goes away, so
    // stale bridges never accumulate.
    MCPSocketBridge.exitWhenOrphaned()
    // TSK-1552: the SELF-HEALING loop — an app quit/relaunch no longer kills
    // the client's MCP session; the bridge reconnects with capped backoff
    // (requests queue unread in the pipe while disconnected) and returns
    // only when the CLIENT closes stdin.
    MCPSocketBridge.serve(
        localIn: .standardInput, localOut: .standardOutput,
        socketPath: MCPSocketListener.defaultSocketPath(),
        initialRemote: sock)
    exit(0)
}

let app = NSApplication.shared

/// `--mcp-stdio` puts the process in headless RPC mode: no Dock icon,
/// no menu bar, no windows. We still need to call `app.run()` because
/// `@MainActor`-isolated DocumentModel state can only be mutated from
/// the main thread's run loop, which `NSApp.run` services.
let mcpStdioMode = CommandLine.arguments.contains("--mcp-stdio") || mcpConnectMode

/// `--claude-monitor` opens ONLY the standalone read-only Claude session
/// monitor PoC window (no document UI). Stays `.regular` so the window is
/// interactive and screenshot-validatable.
let claudeMonitorMode = CommandLine.arguments.contains("--claude-monitor")

/// Resolves every shipped SwiftPM resource bundle from the running app and
/// returns whether all came from the app's OWN bundle. A resource that is
/// missing — or that resolves from a `/.build/` path (the SwiftPM `Bundle.module`
/// dev fallback that crashed the hand-assembled `.app` on clean machines) —
/// FAILS the check. Backs `--verify-resources` (TSK-1257).
func runResourceSelfCheck() -> Bool {
    var ok = true
    func emit(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }
    func check(_ label: String, _ url: URL?) {
        guard let url else { emit("FAIL  \(label): not found\n"); ok = false; return }
        if !FileManager.default.fileExists(atPath: url.path) {
            emit("FAIL  \(label): \(url.path) missing\n"); ok = false; return
        }
        if url.path.contains("/.build/") {
            emit("FAIL  \(label): resolved from .build (packaging bug) — \(url.path)\n")
            ok = false; return
        }
        emit("OK    \(label): \(url.path)\n")
    }
    // ViewerUI bundle (CodeMirror host, mermaid runtime, markdown.css).
    check("codemirror.html", CodeMirrorResources.hostHTMLURL)
    check("codemirror.js", CodeMirrorResources.jsBundleURL)
    check("codemirror.css", CodeMirrorResources.hostCSSURL)
    check("markdown.css",
          Bundle.viewerUIResources.url(forResource: "markdown", withExtension: "css"))
    check("mermaid.min.js",
          Bundle.viewerUIResources.url(forResource: "mermaid.min", withExtension: "js"))
    // (The ViewerCore Queries/*.scm bundle was DELETED with the Swift fold
    // twin — B3.6, 78c8e973; fold queries are baked into the rust core's
    // static lib now, so there is no on-disk resource left to check.)
    emit(ok ? "OK    all resource bundles resolved from the app bundle\n"
            : "FAIL  resource self-check failed — app would crash on a clean machine\n")
    return ok
}

/// `--verify-resources` is a HOST-SAFE, window-free packaging gate (TSK-1257):
/// it resolves every shipped SwiftPM resource bundle from the RUNNING app and
/// exits 0 (all resolved from the app's own bundle) / 1 (any missing OR resolved
/// from `/.build/`). `build-app.sh` + `verify-app.sh` run it against the
/// assembled `dist/` app so a hand-assembled `.app` that secretly reads the dev
/// machine's `.build` (the M5-Pro launch crash) fails the build instead of a
/// user. Runs BEFORE `NSApplication` is created — no Dock tile, no window.
if CommandLine.arguments.contains("--verify-resources") {
    exit(runResourceSelfCheck() ? 0 : 1)
}

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
        let env = AppDelegate.mdvLiveEnv("MDV_ARTIFACT_DIR")
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
// TSK-1243: under the viaOpen VM-UAT launch (sudo -u open), AppKit does NOT post
// applicationDidFinishLaunching (the launch Apple Event isn't delivered in that
// context), so the spawned test app would never run its --script. When launched via
// the test config-file (launchConfigPresent), post a one-shot fallback that
// force-runs the launch sequence on the first run-loop tick; idempotent
// (launchSequenceRan) so the normal auto-fire path is unaffected. Prod (no config
// file) is untouched.
if AppDelegate.launchConfigPresent {
    DispatchQueue.main.async {
        delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification))
    }
}
app.run()
