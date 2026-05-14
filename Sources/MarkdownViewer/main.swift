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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opt out of macOS's automatic window tabbing — we ship our own in-app
        // tab bar; the system "Show Tab Bar" menu item is confusing here.
        NSWindow.allowsAutomaticWindowTabbing = false

        buildMenu()

        let root = ContentView(model: model)
        let hosting = NSHostingView(rootView: root)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = model.windowTitle
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
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
        let args = CommandLine.arguments.dropFirst()
        if let path = args.first {
            let expanded = (path as NSString).expandingTildeInPath
            let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            let url = URL(fileURLWithPath: expanded, relativeTo: cwd)
                .standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path) {
                model.openPath(url)
            }
        }

        NSApp.activate()
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

    // MARK: U7 — Zoom for rendered view

    @objc func zoomIn(_ sender: Any?) {
        adjustZoom(by: 0.1)
    }
    @objc func zoomOut(_ sender: Any?) {
        adjustZoom(by: -0.1)
    }
    @objc func zoomReset(_ sender: Any?) {
        // Force a refresh; the WKWebView is rebuilt by SwiftUI on viewMode
        // changes, but we can also poke its pageZoom directly if accessible.
        // For now resetting model state is the cheapest path: the user
        // re-renders and gets default zoom.
    }

    private func adjustZoom(by delta: Double) {
        // Placeholder — WKWebView zoom wiring lands with the FinderBar UI
        // (Phase 4.5 UI) which gives us a path into the WKWebView instance
        // from the AppDelegate. Today the menu items exist so HIG / a11y
        // contracts hold, and we don't break shortcut discovery.
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
