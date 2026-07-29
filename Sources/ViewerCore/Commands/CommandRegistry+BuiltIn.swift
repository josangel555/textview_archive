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
        // TSK-1256/942: copy a line-precise mdv:// reference to the current editor
        // line — or a line-RANGE reference when text is selected (TSK-942). Bound to
        // ⌘⌥⇧C (IntelliJ's "Copy Reference" chord; `c` is otherwise unbound here).
        CommandDescriptor(
            id: "edit.copyReference", title: "Copy Reference", category: .edit,
            defaultShortcut: Shortcut(key: "c", modifiers: [.command, .option, .shift]),
            scriptVerb: "copy-reference"),
        // TSK-1335 — palette parity for the existing Edit ▸ Convert Encoding submenu
        // (the host work, DocumentModel.convertActiveFileEncoding, already exists).
        // Re-saves the active file in the chosen encoding; .excluded from macros
        // (a disk-write keyed on the active file, not a clean headless replay).
        CommandDescriptor(
            id: "edit.convertEncoding.utf8", title: "Convert Encoding: UTF-8", category: .format,
            scriptVerb: "convert-encoding utf-8", replayability: .excluded),
        CommandDescriptor(
            id: "edit.convertEncoding.utf16", title: "Convert Encoding: UTF-16", category: .format,
            scriptVerb: "convert-encoding utf-16", replayability: .excluded),
        CommandDescriptor(
            id: "edit.convertEncoding.windows1252",
            title: "Convert Encoding: Western (Windows-1252)", category: .format,
            scriptVerb: "convert-encoding windows-1252", replayability: .excluded),
        CommandDescriptor(
            id: "edit.convertEncoding.isoLatin1",
            title: "Convert Encoding: Western (ISO Latin-1)", category: .format,
            scriptVerb: "convert-encoding iso-latin-1", replayability: .excluded),
        // TSK-1335 — palette parity for Edit ▸ Align Markdown Tables (the transform,
        // Formatter.prettyPrint(.markdown), already exists). Replayable: a deterministic
        // editor-buffer transform like Pretty-Print.
        CommandDescriptor(
            id: "edit.alignTables", title: "Align Markdown Tables", category: .format,
            // TSK-1437: daily-driver markdown loop — ⌥⌘A ("align"; a/⌥ free in
            // both the registry map and the menu bar). Menu binds the same key.
            defaultShortcut: Shortcut(key: "a", modifiers: [.command, .option]),
            scriptVerb: "align-tables"),
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
            // Opens an interactive go-to overlay (needs the user to type/pick) —
            // not a deterministic macro step (TSK-957).
            scriptVerb: "show-goto", replayability: .excluded),
        CommandDescriptor(
            id: "file.closeTab", title: "Close Tab", category: .file,
            defaultShortcut: Shortcut(key: "w", modifiers: [.command]),
            scriptVerb: "close-tab"),
        // Reopen the most recently closed tab — the browser chord (⇧⌘T), and
        // repeatable: each invocation walks one step further back.
        CommandDescriptor(
            id: "file.reopenClosedTab", title: "Reopen Closed Tab", category: .file,
            defaultShortcut: Shortcut(key: "t", modifiers: [.command, .shift]),
            scriptVerb: "reopen-closed-tab"),
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
            // TSK-326: omni-invokable — clears the recents/history store via the
            // pure model method the File-menu item calls. Deterministic.
            scriptVerb: "clear-recents"),

        // MARK: View
        CommandDescriptor(
            id: "view.toggleRenderedSource", title: "Toggle Rendered / Source",
            category: .view,
            defaultShortcut: Shortcut(key: "r", modifiers: [.command, .shift]),
            scriptVerb: "toggle-view"),
        CommandDescriptor(
            id: "view.toggleViewOnly", title: "Toggle View Only", category: .view,
            // TSK-936: owner reserved ⌘1-9 for tool windows + ⇧⌘R is taken by
            // Rendered/Source; ⇧⌘L ("Lock") is free (plain ⌘L = Go to Line).
            defaultShortcut: Shortcut(key: "l", modifiers: [.command, .shift]),
            scriptVerb: "toggle-view-only"),
        CommandDescriptor(
            id: "view.toggleSidebar", title: "Toggle Sidebar", category: .view,
            defaultShortcut: Shortcut(key: "s", modifiers: [.command, .control]),
            scriptVerb: "toggle-sidebar"),
        CommandDescriptor(
            id: "view.toggleWordWrap", title: "Wrap Long Lines", category: .view,
            defaultShortcut: Shortcut(key: "w", modifiers: [.command, .option]),
            // TSK-951: palette parity — pure model toggle (toggleSourceWordWrap).
            scriptVerb: "toggle-word-wrap"),
        CommandDescriptor(
            id: "view.toggleSpellCheck", title: "Toggle Spell Check", category: .view,
            scriptVerb: "toggle-spell-check"),
        CommandDescriptor(
            id: "view.toggleAutocomplete", title: "Toggle Autocomplete", category: .view,
            scriptVerb: "toggle-autocomplete"),
        // TSK-1505: spelling actions — ⌘K-discoverable palette parity for the
        // automatable spelling loop (find → fix → learn → language → report).
        CommandDescriptor(
            id: "edit.nextMisspelling", title: "Next Misspelling", category: .edit,
            scriptVerb: "next-misspelling"),
        CommandDescriptor(
            id: "edit.prevMisspelling", title: "Previous Misspelling", category: .edit,
            scriptVerb: "prev-misspelling"),
        CommandDescriptor(
            id: "edit.fixMisspelling", title: "Fix Misspelling", category: .edit,
            scriptVerb: "fix-misspelling"),
        CommandDescriptor(
            id: "edit.addToDictionary", title: "Add to Dictionary", category: .edit,
            scriptVerb: "add-to-dictionary"),
        CommandDescriptor(
            id: "edit.ignoreWord", title: "Ignore Spelling", category: .edit,
            scriptVerb: "ignore-word"),
        CommandDescriptor(
            id: "edit.checkSpellingDocument", title: "Check Spelling in Document", category: .edit,
            scriptVerb: "check-spelling-document"),
        CommandDescriptor(
            id: "view.toggleInvisibles", title: "Show Invisibles", category: .view,
            defaultShortcut: Shortcut(key: "i", modifiers: [.command, .option]),
            // TSK-951: palette parity — pure model toggle (toggleShowInvisibleChars).
            scriptVerb: "toggle-invisibles"),
        CommandDescriptor(
            id: "view.foldAll", title: "Fold All", category: .view,
            defaultShortcut: Shortcut(key: "[", modifiers: [.command, .option]),
            // TSK-326: omni-invokable — folds the active foldable lens via the
            // pure model method the View-menu item calls. Resolves against the
            // active document state (not the caret), so it's deterministic.
            scriptVerb: "fold-all"),
        CommandDescriptor(
            id: "view.unfoldAll", title: "Unfold All", category: .view,
            defaultShortcut: Shortcut(key: "]", modifiers: [.command, .option]),
            // TSK-326: omni-invokable — see view.foldAll.
            scriptVerb: "unfold-all"),
        CommandDescriptor(
            id: "view.goToLine", title: "Go to Line…", category: .view,
            defaultShortcut: Shortcut(key: "l", modifiers: [.command]),
            scriptVerb: nil),
        CommandDescriptor(
            id: "view.quickOpen", title: "Quick Open…", category: .view,
            // TSK-709 (owner): ⌘K UNBOUND — freed for the terminal. The palette
            // opens via nav.showPalette (⇧⌘P) + double-Shift instead.
            // Opens the interactive command palette — excluded from macros
            // (a macro recorded FROM the palette shouldn't reopen it; TSK-957).
            scriptVerb: "show-palette", replayability: .excluded),
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
            // TSK-904 discoverability: the palette fuzzy-matches on `title`
            // ONLY, so a search for "format" / "json" / "prettify" missed the
            // bare "Pretty-Print". The keyword tail makes those queries hit it
            // (the format names mirror Formatter.SupportedFormat.displayName).
            // `id` stays "view.prettyPrint" — a shipped keybinding contract.
            id: "view.prettyPrint",
            title: "Pretty-Print / Format JSON, XML, JS, CSS", category: .view,
            defaultShortcut: Shortcut(key: "f", modifiers: [.command, .option]),
            scriptVerb: "toggle-format"),
        CommandDescriptor(
            id: "terminal.openHere", title: "Open Terminal Here", category: .navigation,
            scriptVerb: "terminal-open-here"),
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

        // Focus shortcuts (TSK-937): move keyboard focus to a specific
        // surface. NO default shortcut — these keys overlap existing
        // bindings (the TSK-936 muscle-memory concern), so the ACTIONS ship
        // discoverable via menu + palette; key choice is a deliberate
        // follow-up rather than a blind conflicting default.
        CommandDescriptor(
            id: "view.focusTerminal", title: "Focus Terminal", category: .view,
            scriptVerb: "focus-terminal"),
        CommandDescriptor(
            id: "view.focusFileNav", title: "Focus File Navigator", category: .view,
            scriptVerb: "focus-file-nav"),
        CommandDescriptor(
            id: "view.focusGit", title: "Focus Git Panel", category: .view,
            scriptVerb: "focus-git"),
        CommandDescriptor(
            id: "view.focusDocument", title: "Focus Active File", category: .view,
            scriptVerb: "focus-document"),

        // MARK: Edit
        CommandDescriptor(
            id: "edit.undo", title: "Undo", category: .edit,
            defaultShortcut: Shortcut(key: "z", modifiers: [.command]),
            scriptVerb: nil),
        CommandDescriptor(
            id: "edit.redo", title: "Redo", category: .edit,
            defaultShortcut: Shortcut(key: "z", modifiers: [.command, .shift]),
            scriptVerb: nil),
        // TSK-951: menu-only Edit text-transforms were invisible to the palette
        // (no registry entry). Each maps to an existing host-tested active-file
        // transform on the model (no-op when there's no active text file).
        CommandDescriptor(
            id: "edit.removeEmptyLines", title: "Remove Empty Lines", category: .edit,
            scriptVerb: "edit-remove-empty-lines"),
        CommandDescriptor(
            id: "edit.collapseBlankLines", title: "Collapse Blank Lines", category: .edit,
            scriptVerb: "edit-collapse-blank-lines"),
        CommandDescriptor(
            id: "edit.trimTrailingWhitespace", title: "Trim Trailing Whitespace", category: .format,
            scriptVerb: "edit-trim-trailing"),
        CommandDescriptor(
            id: "edit.ensureFinalNewline", title: "Ensure Final Newline", category: .format,
            scriptVerb: "edit-ensure-final-newline"),
        // TSK-1186: the case transforms dispatch (edit-uppercase/lowercase/capitalize
        // via TextTransform) but had no palette descriptors — menu-only until now.
        CommandDescriptor(
            id: "edit.uppercase", title: "Uppercase", category: .edit,
            scriptVerb: "edit-uppercase"),
        CommandDescriptor(
            id: "edit.lowercase", title: "Lowercase", category: .edit,
            scriptVerb: "edit-lowercase"),
        CommandDescriptor(
            id: "edit.capitalize", title: "Capitalize", category: .edit,
            scriptVerb: "edit-capitalize"),
        // TSK-1186: heading promote/demote (MarkdownHeadingShift, host-tested
        // TSK-882) drove from the menu only — now palette- + verb-invokable.
        CommandDescriptor(
            id: "edit.promoteHeading", title: "Promote Heading", category: .format,
            scriptVerb: "edit-promote-heading"),
        CommandDescriptor(
            id: "edit.demoteHeading", title: "Demote Heading", category: .format,
            scriptVerb: "edit-demote-heading"),
        // TSK-1186: line ops (sort/reverse/dedup) had model methods but no verbs.
        CommandDescriptor(
            id: "edit.sortLines", title: "Sort Lines (Ascending)", category: .edit,
            scriptVerb: "edit-sort-lines"),
        CommandDescriptor(
            id: "edit.sortLinesDescending", title: "Sort Lines (Descending)", category: .edit,
            scriptVerb: "edit-sort-lines-desc"),
        CommandDescriptor(
            id: "edit.reverseLines", title: "Reverse Lines", category: .edit,
            scriptVerb: "edit-reverse-lines"),
        CommandDescriptor(
            id: "edit.removeDuplicateLines", title: "Remove Duplicate Lines", category: .edit,
            scriptVerb: "edit-remove-duplicate-lines"),
        // TSK-1186: line-ending converters as PARAM-LESS per-target verbs (the
        // dispatcher carries args, but enumerated targets keep the palette
        // prompt-free) — convertActiveFileLineEnding is file-write, host-tested.
        CommandDescriptor(
            id: "edit.convertLineEndingsLF", title: "Convert Line Endings to LF", category: .format,
            scriptVerb: "convert-line-endings-lf"),
        CommandDescriptor(
            id: "edit.convertLineEndingsCRLF", title: "Convert Line Endings to CRLF", category: .format,
            scriptVerb: "convert-line-endings-crlf"),
        CommandDescriptor(
            id: "edit.convertLineEndingsCR", title: "Convert Line Endings to CR", category: .format,
            scriptVerb: "convert-line-endings-cr"),
        // TSK-1186: indentation converters (per-target, param-less) — file-write.
        CommandDescriptor(
            id: "edit.convertIndentationToSpaces", title: "Convert Indentation to Spaces", category: .format,
            scriptVerb: "convert-indentation-to-spaces"),
        CommandDescriptor(
            id: "edit.convertIndentationToTabs", title: "Convert Indentation to Tabs", category: .format,
            scriptVerb: "convert-indentation-to-tabs"),
        // TSK-1162: macro record/replay control verbs. Marked .excluded so a
        // recording never captures its own start/stop/replay.
        CommandDescriptor(
            id: "macro.recordStart", title: "Start Recording Macro", category: .view,
            scriptVerb: "macro-record-start", replayability: .excluded),
        CommandDescriptor(
            id: "macro.recordStop", title: "Stop Recording Macro", category: .view,
            scriptVerb: "macro-record-stop", replayability: .excluded),
        CommandDescriptor(
            id: "macro.replayLast", title: "Replay Last Macro", category: .view,
            scriptVerb: "macro-replay-last", replayability: .excluded),
        CommandDescriptor(
            // TSK-904: "Compact" keyword so the palette finds the inverse of
            // Pretty-Print under its common synonym, not just "minify".
            id: "edit.minifyJSON", title: "Minify JSON (Compact)", category: .edit,
            scriptVerb: "edit-minify-json"),
        CommandDescriptor(
            id: "edit.insertTOC", title: "Insert Table of Contents", category: .format,
            // TSK-1437: daily-driver markdown loop — ⌥⌘O ("outline"; ⌘O/⇧⌘O are
            // open/open-folder, the ⌥ variant is free). Menu binds the same key.
            defaultShortcut: Shortcut(key: "o", modifiers: [.command, .option]),
            scriptVerb: "edit-insert-toc"),
        CommandDescriptor(
            id: "edit.insertDate", title: "Insert Date and Time", category: .edit,
            scriptVerb: "edit-insert-date"),

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
            // Opens the cross-file search panel (needs a typed query) — not a
            // deterministic macro step (TSK-957).
            scriptVerb: "show-cross-search", replayability: .excluded),
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
            // Opens the rendered find bar (needs a typed query) — excluded (TSK-957).
            scriptVerb: "show-find", replayability: .excluded),

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
            // TSK-720: ⇧⌘P opens the command palette — the iconic VS Code
            // binding. (⌘K was freed for the terminal — TSK-709.) We deliberately
            // do NOT bind ⌘P — that's the macOS-standard Print chord (Mac HIG;
            // reserved for print/PDF, TSK-638), unlike VS Code which overrides
            // it. So VS Code users get ⇧⌘P; ⌘P stays Print.
            defaultShortcut: Shortcut(key: "p", modifiers: [.command, .shift]),
            // Opens the interactive command palette — excluded from macros (TSK-957).
            scriptVerb: "show-palette", replayability: .excluded),
        CommandDescriptor(
            id: "nav.crossSearch", title: "Search Across Files", category: .navigation,
            // Opens the cross-file search panel (needs a typed query) — excluded (TSK-957).
            scriptVerb: "show-cross-search", replayability: .excluded),

        // MARK: LSP go-to (TSK-464 — deliberate-command form of the
        // editor's Cmd-click navigation; resolved at the active cursor)
        // All five go-to verbs resolve against the LIVE caret position, so
        // replaying them in a macro lands wherever the cursor happens to be —
        // excluded as pointer/selection-dependent (TSK-957).
        CommandDescriptor(
            id: "lsp.gotoDefinition", title: "Go to Definition", category: .lsp,
            scriptVerb: "editor-goto-definition", replayability: .excluded),
        CommandDescriptor(
            id: "lsp.gotoDeclaration", title: "Go to Declaration", category: .lsp,
            scriptVerb: "editor-goto-declaration", replayability: .excluded),
        CommandDescriptor(
            id: "lsp.gotoTypeDefinition", title: "Go to Type Definition", category: .lsp,
            scriptVerb: "editor-goto-type-definition", replayability: .excluded),
        CommandDescriptor(
            id: "lsp.gotoImplementation", title: "Go to Implementation", category: .lsp,
            scriptVerb: "editor-goto-implementation", replayability: .excluded),
        CommandDescriptor(
            // TSK-950: list all references in the LSP navigation panel (was
            // source-view right-click only). Resolved at the active editor cursor.
            id: "lsp.findReferences", title: "Find References", category: .lsp,
            scriptVerb: "editor-find-references", replayability: .excluded),
        CommandDescriptor(
            id: "lsp.format", title: "Format Document", category: .lsp,
            // TSK-757: ⇧⌥F — VS Code's universal "Format Document" chord. ⌘⌥F is
            // taken by find.replace; ⇧⌥F is free. Auto-wires the Edit-menu item
            // via applyShortcut("lsp.format", …) in main.swift.
            // Whole-document transform — deterministic, so it stays replayable.
            defaultShortcut: Shortcut(key: "f", modifiers: [.option, .shift]),
            scriptVerb: "editor-format"),
        CommandDescriptor(
            id: "lsp.rename", title: "Rename Symbol…", category: .lsp,
            // Opens a rename prompt at the cursor (interactive + selection-
            // dependent) — excluded (TSK-957).
            scriptVerb: "show-lsp-rename", replayability: .excluded),
        CommandDescriptor(
            id: "lsp.codeActions", title: "Code Actions…", category: .lsp,
            // Opens an interactive code-actions menu at the cursor — excluded (TSK-957).
            scriptVerb: "show-code-actions", replayability: .excluded),

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
            // TSK-326: omni-invokable — opens the Git panel on the Log tab, the
            // same call the View-menu's "Show Repository History" makes.
            scriptVerb: "show-repo-history"),

        // MARK: Tools / hosted-view panels
        // TSK-1413 — ⌘K palette discoverability for the hosted-view tools that
        // were reachable ONLY via the File/View menus (no palette entry). Each
        // maps to its existing show-* verb → openHostedView. (Feed Reader was
        // the orphan wired in TSK-1417; this makes it palette-discoverable too.)
        CommandDescriptor(
            id: "file.newHTTPRequest", title: "New HTTP Request", category: .file,
            scriptVerb: "show-http-client"),
        CommandDescriptor(
            id: "file.feedReader", title: "Open Feed Reader", category: .file,
            scriptVerb: "show-feed-reader"),
        CommandDescriptor(
            id: "view.folderTreemap", title: "Show Folder Treemap", category: .view,
            scriptVerb: "show-folder-treemap"),
        CommandDescriptor(
            id: "view.dependencyGraph", title: "Show Dependency Graph", category: .view,
            scriptVerb: "show-dependency-graph"),
        CommandDescriptor(
            id: "view.walkthroughs", title: "Browse Walkthroughs", category: .view,
            scriptVerb: "show-walkthroughs"),

        // TSK-1425: clipboard-export conversions — ⌘K palette parity for the
        // File ▸ Export/Share menu items (non-interactive copy actions). The
        // Interactive export actions that open a dialog (Export as HTML…) stay
        // menu-only, like Find/Replace/Open (correctly scriptVerb-less). The
        // doc-quality tools (Lint / Check Links / CSV Summary / Document
        // Statistics) route to the shared results PANEL since TSK-1434, so they
        // are palette-invokable below.
        CommandDescriptor(
            id: "file.copyDocAsHTML", title: "Copy as HTML", category: .file,
            scriptVerb: "copy-doc-as-html"),
        CommandDescriptor(
            id: "file.copyCSVAsMarkdownTable", title: "Copy CSV as Markdown Table", category: .file,
            scriptVerb: "copy-csv-as-markdown-table"),
        CommandDescriptor(
            id: "file.copyCSVAsJSON", title: "Copy CSV as JSON", category: .file,
            scriptVerb: "copy-csv-as-json"),
        CommandDescriptor(
            id: "file.copyJSONAsCSV", title: "Copy JSON as CSV", category: .file,
            scriptVerb: "copy-json-as-csv"),
        // TSK-1434: doc-quality tools — results in the shared panel.
        CommandDescriptor(
            id: "file.checkLinks", title: "Check Links", category: .file,
            // TSK-1437: daily-driver doc-quality loop — ⇧⌘K ("linK-check"; k is
            // unbound app-wide). Menu binds the same key.
            defaultShortcut: Shortcut(key: "k", modifiers: [.command, .shift]),
            scriptVerb: "check-links"),
        CommandDescriptor(
            id: "file.lintMarkdown", title: "Lint Markdown", category: .file,
            scriptVerb: "lint-markdown"),
        CommandDescriptor(
            id: "file.documentStats", title: "Document Statistics", category: .file,
            scriptVerb: "document-stats"),
        CommandDescriptor(
            id: "file.csvSummary", title: "CSV Summary", category: .file,
            scriptVerb: "csv-summary"),

        CommandDescriptor(
            id: "git.toggleBlame", title: "Toggle Git Blame", category: .git,
            scriptVerb: "toggle-blame"),

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
        // Sidebar navigation moves relative to the CURRENT selection, so a
        // replay lands relative to wherever the user is now, not where the
        // macro was recorded — excluded as selection-dependent (TSK-957).
        CommandDescriptor(
            id: "sidebar.selectNext", title: "Sidebar: Select Next", category: .navigation,
            scriptVerb: "sidebar-select-next", replayability: .excluded),
        CommandDescriptor(
            id: "sidebar.selectPrevious", title: "Sidebar: Select Previous",
            category: .navigation,
            scriptVerb: "sidebar-select-prev", replayability: .excluded),
        CommandDescriptor(
            id: "sidebar.walkUp", title: "Sidebar: Focus Parent Folder",
            category: .navigation,
            scriptVerb: "sidebar-walk-up", replayability: .excluded),

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
        // Line/case transforms on the clipboard (TSK-352).
        CommandDescriptor(
            id: "tools.sortLinesAsc", title: "Sort Clipboard Lines (A→Z)", category: .edit,
            scriptVerb: "tools.sortLinesAsc"),
        CommandDescriptor(
            id: "tools.sortLinesDesc", title: "Sort Clipboard Lines (Z→A)", category: .edit,
            scriptVerb: "tools.sortLinesDesc"),
        CommandDescriptor(
            id: "tools.uniqueLines", title: "Remove Duplicate Lines (Clipboard)", category: .edit,
            scriptVerb: "tools.uniqueLines"),
        CommandDescriptor(
            id: "tools.reverseLines", title: "Reverse Clipboard Lines", category: .edit,
            scriptVerb: "tools.reverseLines"),
        CommandDescriptor(
            id: "tools.upperCase", title: "UPPERCASE Clipboard", category: .edit,
            scriptVerb: "tools.upperCase"),
        CommandDescriptor(
            id: "tools.lowerCase", title: "lowercase Clipboard", category: .edit,
            scriptVerb: "tools.lowerCase"),
        // Encode/decode + whitespace transforms on the clipboard (TSK-352).
        CommandDescriptor(
            id: "tools.trimTrailing", title: "Trim Trailing Whitespace (Clipboard)", category: .edit,
            scriptVerb: "tools.trimTrailing"),
        CommandDescriptor(
            id: "tools.urlEncode", title: "URL Encode Clipboard", category: .edit,
            scriptVerb: "tools.urlEncode"),
        CommandDescriptor(
            id: "tools.urlDecode", title: "URL Decode Clipboard", category: .edit,
            scriptVerb: "tools.urlDecode"),
        CommandDescriptor(
            id: "tools.htmlEncode", title: "HTML Encode Clipboard", category: .edit,
            scriptVerb: "tools.htmlEncode"),
        CommandDescriptor(
            id: "tools.htmlDecode", title: "HTML Decode Clipboard", category: .edit,
            scriptVerb: "tools.htmlDecode"),
        CommandDescriptor(
            id: "tools.fileChecksum", title: "Copy SHA-256 of Current File", category: .edit,
            scriptVerb: "tools.fileChecksum"),
    ]
}
