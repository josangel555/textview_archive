import AppKit
import SwiftUI
import ViewerCore
import ViewerUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = DocumentModel()
    var window: NSWindow?
    private var openRecentMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        self.window = window

        // Open file from argv if provided.
        let args = CommandLine.arguments.dropFirst()
        if let path = args.first {
            let expanded = (path as NSString).expandingTildeInPath
            model.open(url: URL(fileURLWithPath: expanded))
            window.title = model.windowTitle
        }

        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            model.open(url: url)
            window?.title = model.windowTitle
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
        if panel.runModal() == .OK, let url = panel.url {
            model.open(url: url)
            window?.title = model.windowTitle
        }
    }

    @objc func toggleViewMode(_ sender: Any?) {
        model.toggleViewMode()
    }

    @objc func openRecentItem(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        model.open(url: url)
        window?.title = model.windowTitle
    }

    @objc func clearRecents(_ sender: Any?) {
        model.clearRecents()
    }

    // MARK: NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === openRecentMenu else { return }
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
        let openItem = NSMenuItem(
            title: "Open…",
            action: #selector(openDocument(_:)),
            keyEquivalent: "o"
        )
        openItem.target = self
        fileMenu.addItem(openItem)

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
        fileMenu.addItem(NSMenuItem(
            title: "Close Window",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))
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
        viewMenuItem.submenu = viewMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Copy",
            action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Select All",
            action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(.separator())
        let findItem = NSMenuItem(
            title: "Find…",
            action: #selector(NSTextView.performFindPanelAction(_:)),
            keyEquivalent: "f"
        )
        findItem.tag = NSTextFinder.Action.showFindInterface.rawValue
        editMenu.addItem(findItem)
        editMenuItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
