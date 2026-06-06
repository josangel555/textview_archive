import Foundation

extension CommandRegistry {

    /// The shipped, built-in catalog. ONE canonical list, assembled from
    /// the `ScriptVerb` vocabulary + the `main.swift` menu commands +
    /// the palette commands.
    ///
    /// Conventions:
    ///   - `id` is dot-namespaced (`<area>.<verb>`); it is a config
    ///     contract (the key users write in `keybinding.json`) and must
    ///     never be renamed once shipped.
    ///   - `defaultShortcut` mirrors the `keyEquivalent` +
    ///     `keyEquivalentModifierMask` the menu builder hard-codes today,
    ///     so the registry can become the single source of truth for
    ///     menu shortcuts.
    ///   - `scriptVerb` is the `ScriptVerb.apply` line the palette uses to
    ///     invoke the command headlessly. `nil` means the action is still
    ///     window/`NSApp`-coupled and not yet palette-invokable (see the
    ///     GAP report in the PR description).
    public static let builtIn = CommandRegistry(commands: builtInCommands)

    /// Convenience: the built-in catalog with the user's keybinding
    /// overrides already folded in. `config.bindings` is the parsed
    /// `commandID → Shortcut` map (empty when no file / a bad file).
    public static func builtIn(applying config: KeybindingConfig) -> CommandRegistry {
        builtIn.applying(overrides: config.bindings)
    }

    private static let builtInCommands: [CommandDescriptor] = [

        // MARK: File
        CommandDescriptor(
            id: "file.newTab", title: "New Tab", category: .file,
            defaultShortcut: Shortcut(key: "t", modifiers: [.command]),
            scriptVerb: "new-tab"),
        CommandDescriptor(
            id: "file.open", title: "Open…", category: .file,
            // ⌘O routes through an NSOpenPanel — no pure verb.
            defaultShortcut: Shortcut(key: "o", modifiers: [.command]),
            scriptVerb: nil),
        CommandDescriptor(
            id: "file.openFolder", title: "Open Folder…", category: .file,
            defaultShortcut: Shortcut(key: "o", modifiers: [.command, .shift]),
            scriptVerb: nil),
        CommandDescriptor(
            id: "file.goToPath", title: "Go to File or Folder…", category: .file,
            defaultShortcut: Shortcut(key: "g", modifiers: [.command, .shift]),
            scriptVerb: "show-goto"),
        CommandDescriptor(
            id: "file.closeTab", title: "Close Tab", category: .file,
            defaultShortcut: Shortcut(key: "w", modifiers: [.command]),
            scriptVerb: "close-tab"),
        CommandDescriptor(
            id: "file.save", title: "Save", category: .file,
            defaultShortcut: Shortcut(key: "s", modifiers: [.command]),
            scriptVerb: "editor-save"),
        CommandDescriptor(
            id: "file.reload", title: "Reload", category: .file,
            // Menu binds ⌘R; toggle.view also uses ⇧⌘R — distinct.
            defaultShortcut: Shortcut(key: "r", modifiers: [.command]),
            scriptVerb: "reload"),
        CommandDescriptor(
            id: "file.clearRecents", title: "Clear Recent Files", category: .file,
            scriptVerb: nil),

        // MARK: View
        CommandDescriptor(
            id: "view.toggleRenderedSource", title: "Toggle Rendered / Source",
            category: .view,
            defaultShortcut: Shortcut(key: "r", modifiers: [.command, .shift]),
            scriptVerb: "toggle-view"),
        CommandDescriptor(
            id: "view.toggleSidebar", title: "Toggle Sidebar", category: .view,
            defaultShortcut: Shortcut(key: "s", modifiers: [.command, .control]),
            scriptVerb: "toggle-sidebar"),
        CommandDescriptor(
            id: "view.toggleWordWrap", title: "Wrap Long Lines", category: .view,
            defaultShortcut: Shortcut(key: "w", modifiers: [.command, .option]),
            scriptVerb: nil),
        CommandDescriptor(
            id: "view.toggleInvisibles", title: "Show Invisibles", category: .view,
            defaultShortcut: Shortcut(key: "i", modifiers: [.command, .option]),
            scriptVerb: nil),
        CommandDescriptor(
            id: "view.foldAll", title: "Fold All", category: .view,
            defaultShortcut: Shortcut(key: "[", modifiers: [.command, .option]),
            scriptVerb: nil),
        CommandDescriptor(
            id: "view.unfoldAll", title: "Unfold All", category: .view,
            defaultShortcut: Shortcut(key: "]", modifiers: [.command, .option]),
            scriptVerb: nil),
        CommandDescriptor(
            id: "view.goToLine", title: "Go to Line…", category: .view,
            defaultShortcut: Shortcut(key: "l", modifiers: [.command]),
            scriptVerb: nil),
        CommandDescriptor(
            id: "view.quickOpen", title: "Quick Open…", category: .view,
            defaultShortcut: Shortcut(key: "k", modifiers: [.command]),
            scriptVerb: "show-palette"),
        CommandDescriptor(
            id: "view.zoomIn", title: "Zoom In", category: .view,
            defaultShortcut: Shortcut(key: "=", modifiers: [.command]),
            scriptVerb: "zoom-in"),
        CommandDescriptor(
            id: "view.zoomOut", title: "Zoom Out", category: .view,
            defaultShortcut: Shortcut(key: "-", modifiers: [.command]),
            scriptVerb: "zoom-out"),
        CommandDescriptor(
            id: "view.actualSize", title: "Actual Size", category: .view,
            defaultShortcut: Shortcut(key: "0", modifiers: [.command]),
            scriptVerb: "zoom-reset"),
        CommandDescriptor(
            id: "view.prettyPrint", title: "Pretty-Print", category: .view,
            defaultShortcut: Shortcut(key: "f", modifiers: [.command, .option]),
            scriptVerb: "toggle-format"),
        CommandDescriptor(
            id: "view.applyJQ", title: "Apply jq Filter…", category: .view,
            defaultShortcut: Shortcut(key: "j", modifiers: [.command, .option]),
            scriptVerb: nil),
        CommandDescriptor(
            id: "view.toggleBookmark", title: "Bookmark / Unbookmark Current",
            category: .view,
            defaultShortcut: Shortcut(key: "d", modifiers: [.command]),
            scriptVerb: "toggle-bookmark"),
        CommandDescriptor(
            id: "view.toggleLineBookmark",
            title: "Bookmark / Unbookmark Current Line", category: .view,
            defaultShortcut: Shortcut(key: "d", modifiers: [.command, .option]),
            scriptVerb: "toggle-line-bookmark"),
        CommandDescriptor(
            id: "view.toggleSplit", title: "Toggle Split", category: .view,
            defaultShortcut: Shortcut(key: "backslash", modifiers: [.command]),
            scriptVerb: "toggle-split"),
        CommandDescriptor(
            id: "view.swapSplit", title: "Swap Split Panes", category: .view,
            defaultShortcut: Shortcut(key: "backslash", modifiers: [.command, .shift]),
            scriptVerb: "swap-split"),
        CommandDescriptor(
            id: "view.folderStats", title: "Toggle Folder Stats", category: .view,
            defaultShortcut: Shortcut(key: "i", modifiers: [.command, .control]),
            scriptVerb: "folder-stats"),

        // MARK: Edit
        CommandDescriptor(
            id: "edit.undo", title: "Undo", category: .edit,
            defaultShortcut: Shortcut(key: "z", modifiers: [.command]),
            scriptVerb: nil),
        CommandDescriptor(
            id: "edit.redo", title: "Redo", category: .edit,
            defaultShortcut: Shortcut(key: "z", modifiers: [.command, .shift]),
            scriptVerb: nil),

        // MARK: Find
        CommandDescriptor(
            id: "find.find", title: "Find…", category: .find,
            defaultShortcut: Shortcut(key: "f", modifiers: [.command]),
            // The Cmd+F router picks source/editor/rendered bar by mode
            // (window-coupled). The rendered-find verb below is the closest
            // pure equivalent but isn't a 1:1 for the router, so leave nil.
            scriptVerb: nil),
        CommandDescriptor(
            id: "find.replace", title: "Find and Replace…", category: .find,
            defaultShortcut: Shortcut(key: "f", modifiers: [.command, .option]),
            scriptVerb: nil),
        CommandDescriptor(
            id: "find.inFolder", title: "Find in Folder…", category: .find,
            defaultShortcut: Shortcut(key: "f", modifiers: [.command, .shift]),
            scriptVerb: "show-cross-search"),
        CommandDescriptor(
            id: "find.next", title: "Find Next", category: .find,
            defaultShortcut: Shortcut(key: "g", modifiers: [.command]),
            scriptVerb: "find-next"),
        CommandDescriptor(
            id: "find.previous", title: "Find Previous", category: .find,
            defaultShortcut: Shortcut(key: "g", modifiers: [.command, .option]),
            scriptVerb: "find-prev"),
        CommandDescriptor(
            id: "find.renderedShow", title: "Find in Rendered View", category: .find,
            scriptVerb: "show-find"),

        // MARK: Tabs
        CommandDescriptor(
            id: "tabs.next", title: "Next Tab", category: .tabs,
            // Natural macOS tab-switch default (Safari/Terminal/Notes): ⌘⇧].
            // Mirrored in the AppKit Window menu (main.swift) which actually
            // intercepts the keystroke; ⌘⌥arrow is no longer the default but
            // remains user-rebindable via keybinding.json (TSK-328).
            defaultShortcut: Shortcut(key: "]", modifiers: [.command, .shift]),
            scriptVerb: "next-tab"),
        CommandDescriptor(
            id: "tabs.previous", title: "Previous Tab", category: .tabs,
            defaultShortcut: Shortcut(key: "[", modifiers: [.command, .shift]),
            scriptVerb: "prev-tab"),
        CommandDescriptor(
            id: "tabs.moveLeft", title: "Move Tab Left", category: .tabs,
            defaultShortcut: Shortcut(key: "[", modifiers: [.command, .option]),
            // Collides with view.foldAll by default — intentional, the menu
            // disambiguates by responder/mode; flagged in shortcutMap.
            scriptVerb: "move-tab-left"),
        CommandDescriptor(
            id: "tabs.moveRight", title: "Move Tab Right", category: .tabs,
            defaultShortcut: Shortcut(key: "]", modifiers: [.command, .option]),
            scriptVerb: "move-tab-right"),

        // MARK: Navigation (palette / go-to overlays)
        CommandDescriptor(
            id: "nav.showPalette", title: "Quick Open (Command Palette)",
            category: .navigation,
            scriptVerb: "show-palette"),
        CommandDescriptor(
            id: "nav.crossSearch", title: "Search Across Files", category: .navigation,
            scriptVerb: "show-cross-search"),

        // MARK: Git
        CommandDescriptor(
            id: "git.showPanel", title: "Show Git Panel", category: .git,
            defaultShortcut: Shortcut(key: "b", modifiers: [.command, .option, .shift]),
            scriptVerb: "show-git-panel"),
        CommandDescriptor(
            id: "git.fileHistory", title: "Show File History", category: .git,
            defaultShortcut: Shortcut(key: "h", modifiers: [.command, .option, .shift]),
            scriptVerb: "git-file-history"),
        CommandDescriptor(
            id: "git.repoHistory", title: "Show Repository History", category: .git,
            defaultShortcut: Shortcut(key: "l", modifiers: [.command, .option, .shift]),
            scriptVerb: nil),

        // MARK: Sessions
        CommandDescriptor(
            id: "session.new", title: "New Session…", category: .sessions,
            defaultShortcut: Shortcut(key: "n", modifiers: [.command, .shift]),
            scriptVerb: nil),
        CommandDescriptor(
            id: "session.next", title: "Next Session", category: .sessions,
            defaultShortcut: Shortcut(key: "tab", modifiers: [.control]),
            scriptVerb: "session-next"),
        CommandDescriptor(
            id: "session.previous", title: "Previous Session", category: .sessions,
            defaultShortcut: Shortcut(key: "tab", modifiers: [.control, .shift]),
            scriptVerb: "session-prev"),
        CommandDescriptor(
            id: "session.close", title: "Close Session", category: .sessions,
            defaultShortcut: Shortcut(key: "w", modifiers: [.command, .shift]),
            scriptVerb: "session-close-active"),

        // MARK: Sidebar
        CommandDescriptor(
            id: "sidebar.selectNext", title: "Sidebar: Select Next", category: .navigation,
            scriptVerb: "sidebar-select-next"),
        CommandDescriptor(
            id: "sidebar.selectPrevious", title: "Sidebar: Select Previous",
            category: .navigation,
            scriptVerb: "sidebar-select-prev"),
        CommandDescriptor(
            id: "sidebar.walkUp", title: "Sidebar: Focus Parent Folder",
            category: .navigation,
            scriptVerb: "sidebar-walk-up"),

        // MARK: Window
        CommandDescriptor(
            id: "window.minimize", title: "Minimize", category: .window,
            defaultShortcut: Shortcut(key: "m", modifiers: [.command]),
            scriptVerb: nil),
        CommandDescriptor(
            id: "window.zoom", title: "Zoom Window", category: .window,
            scriptVerb: nil),

        // MARK: Debug (gated; only meaningful when DiagnosticGate is on)
        CommandDescriptor(
            id: "debug.diagnosticWindow", title: "Diagnostic Window", category: .debug,
            scriptVerb: nil),
        CommandDescriptor(
            id: "debug.instrumentation", title: "Instrumentation", category: .debug,
            scriptVerb: nil),
        CommandDescriptor(
            id: "debug.emitTestLog", title: "Emit Test Log Events", category: .debug,
            scriptVerb: "emit-test-log"),

        // Text tools (TSK-292/294/295) — palette/Omni-invokable; operate on the
        // clipboard via TextToolRunner. scriptVerb == TextToolVerb.rawValue.
        CommandDescriptor(
            id: "tools.uuid", title: "Generate UUID", category: .edit,
            scriptVerb: "tools.uuid"),
        CommandDescriptor(
            id: "tools.sha256", title: "SHA-256 (hex) of Clipboard", category: .edit,
            scriptVerb: "tools.sha256"),
        CommandDescriptor(
            id: "tools.base64Encode", title: "Base64 Encode Clipboard", category: .edit,
            scriptVerb: "tools.base64Encode"),
        CommandDescriptor(
            id: "tools.base64Decode", title: "Base64 Decode Clipboard", category: .edit,
            scriptVerb: "tools.base64Decode"),
    ]
}
