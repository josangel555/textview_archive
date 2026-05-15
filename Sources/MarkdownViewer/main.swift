import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import ViewerCore
import ViewerUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = DocumentModel()
    var window: NSWindow?
    private var openRecentMenu: NSMenu?
    private var windowMenu: NSMenu?
    private var cancellables: Set<AnyCancellable> = []
    private var diagnosticSignalSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opt out of macOS's automatic window tabbing — we ship our own in-app
        // tab bar; the system "Show Tab Bar" menu item is confusing here.
        NSWindow.allowsAutomaticWindowTabbing = false

        buildMenu()

        // CRITICAL: use NSHostingController.view (not a bare NSHostingView
        // set as contentView). The controller's view installs auto-layout
        // constraints that pin it to fill the window's contentView, so when
        // the window's frame is restored from autosave or the user resizes,
        // the SwiftUI content grows with it. The bare-NSHostingView pattern
        // froze the hosted view at the window's *initial* content size and
        // never resized it — that's the bug where opening any non-markdown
        // file revealed a sliver of UI (line numbers only) inside a vast
        // empty white background.
        let hostingController = NSHostingController(rootView: ContentView(model: model))

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
        window.makeKeyAndOrderFront(nil)
        self.window = window

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

        // Restore last-opened folder (silently no-ops if path no longer exists).
        model.restorePreviousFolderIfAvailable()

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

        NSApp.activate()

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
        let json = "/tmp/mdv-step-\(n).json"
        let png  = "/tmp/mdv-step-\(n).png"
        let dump = DiagnosticDump.dump(window: win)
        var enriched = dump
        enriched["step"] = step
        enriched["label"] = label
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
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let json = "/tmp/mdv-auto.json"
                let png  = "/tmp/mdv-auto.png"
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
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            // Give the compositor one runloop tick to flush after
            // activation before we capture.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let pid = getpid()
                let jsonPath = "/tmp/mdv-diagnostic-\(pid).json"
                let pngPath  = "/tmp/mdv-snapshot-\(pid).png"
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
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            model.openPath(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
            model.openFolder(url)
        }
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
            title: "About MarkdownViewer",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: "Hide MarkdownViewer",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        ))
        appMenu.addItem(NSMenuItem(
            title: "Quit MarkdownViewer",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
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
        mainMenu.addItem(viewMenuItem)
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
        let zoomIn = NSMenuItem(title: "Zoom In",
                                action: #selector(zoomIn(_:)),
                                keyEquivalent: "+")
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

        viewMenuItem.submenu = viewMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.delegate = self
        windowMenu.autoenablesItems = false
        self.windowMenu = windowMenu
        // Items are populated lazily in rebuildWindowMenu() via menuNeedsUpdate.
        windowMenuItem.submenu = windowMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
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
        let findItem = NSMenuItem(
            title: "Find…",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: "f"
        )
        findItem.tag = NSTextFinder.Action.showFindInterface.rawValue
        findSubmenu.addItem(findItem)
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
        mainMenu.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        let helpItem = NSMenuItem(
            title: "MarkdownViewer Help",
            action: #selector(NSApplication.showHelp(_:)),
            keyEquivalent: "?"
        )
        helpMenu.addItem(helpItem)
        helpMenuItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
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
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
