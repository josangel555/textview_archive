import XCTest
@testable import ViewerCore

/// Pure-logic (T1, host-safe) coverage for the command registry +
/// keybinding config (UX-M / #232, action catalog / #223).
///
/// All file IO is confined to an injected temp directory — the real
/// `~/.textview` is NEVER touched (we pass `directory:` explicitly).
final class CommandRegistryTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("textview-keybind-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Registry shape

    func test_builtIn_isNonEmpty() {
        XCTAssertFalse(CommandRegistry.builtIn.commands.isEmpty)
        XCTAssertGreaterThan(CommandRegistry.builtIn.commands.count, 20)
    }

    func test_builtIn_idsAreUnique() {
        let ids = CommandRegistry.builtIn.commands.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate command ids: \(duplicates(ids))")
    }

    func test_builtIn_titlesAreNonEmpty() {
        for cmd in CommandRegistry.builtIn.commands {
            XCTAssertFalse(cmd.title.isEmpty, "empty title for \(cmd.id)")
        }
    }

    func test_builtIn_idsAreDotNamespaced() {
        for cmd in CommandRegistry.builtIn.commands {
            XCTAssertTrue(cmd.id.contains("."), "id not namespaced: \(cmd.id)")
        }
    }

    func test_command_lookupByID() {
        XCTAssertNotNil(CommandRegistry.builtIn.command(id: "view.toggleSidebar"))
        XCTAssertNil(CommandRegistry.builtIn.command(id: "does.not.exist"))
    }

    func test_paletteInvokable_isSubsetWithVerbs() {
        let invokable = CommandRegistry.builtIn.paletteInvokable
        XCTAssertFalse(invokable.isEmpty)
        for cmd in invokable {
            XCTAssertNotNil(cmd.scriptVerb)
        }
        // And the count matches the filter on the full list.
        let expected = CommandRegistry.builtIn.commands.filter { $0.scriptVerb != nil }
        XCTAssertEqual(invokable.count, expected.count)
    }

    func test_scriptVerbs_areKnownVocabulary() {
        // Every command that claims a script verb should use a verb token
        // that the ScriptVerb dispatcher recognises (the prefix before any
        // arg). Guards against typos drifting the catalog away from the
        // dispatcher.
        let known: Set<String> = [
            "toggle-view", "toggle-sidebar", "zoom-in", "zoom-out", "zoom-reset",
            "close-tab", "new-tab", "next-tab", "prev-tab", "show-palette",
            "dismiss-palette", "show-goto", "toggle-format", "editor-save",
            "toggle-bookmark", "show-cross-search", "show-find", "find-next",
            "find-prev", "sidebar-select-next", "sidebar-select-prev",
            "sidebar-walk-up", "session-next", "session-prev",
            "session-close-active", "folder-stats", "emit-test-log",
            "tools.uuid", "tools.sha256", "tools.base64Encode", "tools.base64Decode",
            "tools.fileChecksum",
            // line/case transforms (TSK-352)
            "tools.sortLinesAsc", "tools.sortLinesDesc", "tools.uniqueLines",
            "tools.reverseLines", "tools.upperCase", "tools.lowerCase",
            // encode/decode + whitespace (TSK-352)
            "tools.trimTrailing", "tools.urlEncode", "tools.urlDecode",
            "tools.htmlEncode", "tools.htmlDecode",
            "reload", "toggle-split", "swap-split", "move-tab-left", "move-tab-right",
            "show-git-panel", "toggle-line-bookmark", "git-file-history",
            // palette parity for view toggles + menu-only edit transforms (TSK-951)
            "toggle-word-wrap", "toggle-invisibles",
            // view-only (read-only) lock toggle (TSK-936)
            "toggle-view-only",
            // case transforms surfaced to the palette (TSK-1113)
            "edit-uppercase", "edit-lowercase", "edit-capitalize",
            "edit-promote-heading", "edit-demote-heading",
            "edit-sort-lines", "edit-sort-lines-desc",
            "edit-reverse-lines", "edit-remove-duplicate-lines",
            "convert-line-endings-lf", "convert-line-endings-crlf", "convert-line-endings-cr",
            "convert-indentation-to-spaces", "convert-indentation-to-tabs",
            "macro-record-start", "macro-record-stop", "macro-replay-last",
            "edit-remove-empty-lines", "edit-collapse-blank-lines",
            "edit-trim-trailing", "edit-ensure-final-newline",
            "edit-minify-json", "edit-insert-toc", "edit-insert-date",
            // LSP go-to commands (TSK-464)
            "editor-goto-definition", "editor-goto-declaration",
            "editor-goto-type-definition", "editor-goto-implementation",
            "editor-format",
            // LSP find-references → navigation panel (TSK-950)
            "editor-find-references",
            // LSP rename prompt + code-action picker (TSK-640)
            "show-lsp-rename", "show-code-actions",
            // git blame gutter toggle (TSK-814)
            "toggle-blame",
            // open a terminal in the focused file's folder (TSK-769)
            "terminal-open-here",
            // focus shortcuts: move focus to a surface (TSK-937)
            "focus-terminal", "focus-file-nav", "focus-git", "focus-document",
            // omni-search coverage: fold/unfold, repo history, clear recents (TSK-326)
            "fold-all", "unfold-all", "show-repo-history", "clear-recents",
            // copy a line-precise mdv:// reference to the current editor line (TSK-1256)
            "copy-reference",
            // re-save the active file in a chosen encoding via the ⌘K palette (TSK-1335)
            "convert-encoding",
            // re-align GFM tables in the active markdown editor via the palette (TSK-1335)
            "align-tables",
            // hosted-view tools made ⌘K-discoverable (TSK-1413); see also the
            // catalog-based CommandVerbCohesionTests which supersedes this
            // hand-maintained allow-list.
            "show-http-client", "show-feed-reader", "show-folder-treemap",
            "show-dependency-graph", "show-walkthroughs",
        ]
        for cmd in CommandRegistry.builtIn.commands {
            guard let verb = cmd.scriptVerb else { continue }
            let token = verb.split(separator: " ").first.map(String.init) ?? verb
            XCTAssertTrue(known.contains(token),
                          "\(cmd.id) uses unknown verb token '\(token)'")
        }
    }

    /// `file.reload` carries a script verb so it's Omni/palette-invokable +
    /// automatable (regression guard: it previously shipped `scriptVerb: nil`,
    /// making Reload menu-only and headless-untestable).
    func test_fileReload_isPaletteInvokable() {
        let cmd = CommandRegistry.builtIn.command(id: "file.reload")
        XCTAssertEqual(cmd?.scriptVerb, "reload")
        XCTAssertTrue(CommandRegistry.builtIn.paletteInvokable.contains { $0.id == "file.reload" },
                      "Reload must appear in the command palette")
    }

    /// TSK-951: the view toggles + menu-only edit transforms must now be
    /// palette-invokable (carry a scriptVerb), not dimmed/absent.
    func test_paletteParity_viewTogglesAndEditTransforms() {
        let expected: [(String, String)] = [
            ("view.toggleWordWrap", "toggle-word-wrap"),
            ("view.toggleInvisibles", "toggle-invisibles"),
            ("edit.removeEmptyLines", "edit-remove-empty-lines"),
            ("edit.collapseBlankLines", "edit-collapse-blank-lines"),
            ("edit.trimTrailingWhitespace", "edit-trim-trailing"),
            ("edit.ensureFinalNewline", "edit-ensure-final-newline"),
            ("edit.minifyJSON", "edit-minify-json"),
            ("edit.insertTOC", "edit-insert-toc"),
            ("edit.insertDate", "edit-insert-date"),
        ]
        let invokable = Set(CommandRegistry.builtIn.paletteInvokable.map { $0.id })
        for (id, verb) in expected {
            let cmd = CommandRegistry.builtIn.command(id: id)
            XCTAssertEqual(cmd?.scriptVerb, verb, "\(id) must carry verb \(verb) (TSK-951)")
            XCTAssertTrue(invokable.contains(id), "\(id) must be palette-invokable (TSK-951)")
        }
    }

    // MARK: - JSON format discoverability (TSK-904)

    /// The command palette fuzzy-filters on `title` ONLY
    /// (`CommandPaletteView.applyFilter` → `RustFuzzyAdapter.filterWithMatches
    /// { $0.title }`). So discoverability is a property of the TITLE: a user
    /// typing "format json" / "prettify" / "compact" must surface the two JSON
    /// format commands. This runs the EXACT filter the palette runs, so a title
    /// regression that re-hid these commands fails here.
    private func paletteFinds(_ id: String, query: String) -> Bool {
        let hits = RustFuzzyAdapter.filterWithMatches(
            CommandRegistry.builtIn.commands, query: query
        ) { $0.title }
        return hits.contains { $0.item.id == id }
    }

    func test_palette_prettyPrint_discoverableByFormatKeywords() {
        // The bare "Pretty-Print" title hid the command from a "format"/"json"
        // search; the enriched title must restore it.
        for q in ["format", "json", "Format JSON", "pretty"] {
            XCTAssertTrue(paletteFinds("view.prettyPrint", query: q),
                          "palette query \"\(q)\" should surface view.prettyPrint (TSK-904)")
        }
    }

    func test_palette_minifyJSON_discoverableByKeywords() {
        for q in ["minify", "json", "compact"] {
            XCTAssertTrue(paletteFinds("edit.minifyJSON", query: q),
                          "palette query \"\(q)\" should surface edit.minifyJSON (TSK-904)")
        }
    }

    func test_prettyPrint_titleMentionsEveryFormattableType() {
        // Each Formatter.SupportedFormat that `detect` can return (i.e. not the
        // explicit-only markdown lens) should appear in the palette title so its
        // displayName is searchable.
        let title = CommandRegistry.builtIn.command(id: "view.prettyPrint")?.title ?? ""
        for f in [Formatter.SupportedFormat.json, .xml, .js, .css] {
            // The title uses short tokens (JSON/XML/JS/CSS); assert the canonical
            // token for each so the palette hit is not accidental.
            let token = f == .js ? "JS" : f.displayName
            XCTAssertTrue(title.contains(token),
                          "view.prettyPrint title must mention \(token) (TSK-904): \(title)")
        }
    }

    // MARK: - Shortcut parsing

    func test_shortcut_parsesSimpleModifierCombo() {
        let sc = Shortcut.parse("cmd+shift+f")
        XCTAssertEqual(sc, Shortcut(key: "f", modifiers: [.command, .shift]))
    }

    func test_shortcut_modifierAliasesFold() {
        XCTAssertEqual(Shortcut.parse("command+f"), Shortcut.parse("cmd+f"))
        XCTAssertEqual(Shortcut.parse("opt+f"), Shortcut.parse("alt+f"))
        XCTAssertEqual(Shortcut.parse("control+f"), Shortcut.parse("ctrl+f"))
        XCTAssertEqual(Shortcut.parse("meta+f"), Shortcut.parse("cmd+f"))
    }

    func test_shortcut_orderIndependent() {
        XCTAssertEqual(Shortcut.parse("shift+cmd+f"), Shortcut.parse("cmd+shift+f"))
    }

    func test_shortcut_symbolicKeys() {
        XCTAssertEqual(Shortcut.parse("ctrl+tab"),
                       Shortcut(key: "tab", modifiers: [.control]))
        XCTAssertEqual(Shortcut.parse("alt+cmd+left"),
                       Shortcut(key: "left", modifiers: [.option, .command]))
        // esc folds to escape, enter folds to return.
        XCTAssertEqual(Shortcut.parse("esc"), Shortcut.parse("escape"))
        XCTAssertEqual(Shortcut.parse("enter"), Shortcut.parse("return"))
    }

    func test_shortcut_literalPlusKey() {
        XCTAssertEqual(Shortcut.parse("cmd++"),
                       Shortcut(key: "+", modifiers: [.command]))
    }

    func test_shortcut_caseInsensitive() {
        XCTAssertEqual(Shortcut.parse("CMD+SHIFT+F"), Shortcut.parse("cmd+shift+f"))
    }

    func test_shortcut_rejectsGarbage() {
        XCTAssertNil(Shortcut.parse(""))
        XCTAssertNil(Shortcut.parse("   "))
        XCTAssertNil(Shortcut.parse("frobnicate+f"))   // unknown modifier
        XCTAssertNil(Shortcut.parse("cmd+notakey"))    // multi-char non-symbolic key
        XCTAssertNil(Shortcut.parse("cmd+"))           // missing base key
    }

    func test_shortcut_displayStringRoundTrips() {
        let sc = Shortcut.parse("shift+cmd+f")!
        XCTAssertEqual(sc.displayString, "shift+cmd+f")
        XCTAssertEqual(Shortcut.parse(sc.displayString), sc)
    }

    // MARK: - KeybindingConfig parse (in-memory)

    func test_parse_validOverrides() {
        let json = #"{ "view.toggleSidebar": "cmd+shift+e", "file.save": "cmd+s" }"#
        let r = KeybindingConfig.parse(data: Data(json.utf8))
        XCTAssertFalse(r.malformedFile)
        XCTAssertTrue(r.invalidValues.isEmpty)
        XCTAssertTrue(r.unknownIDs.isEmpty)
        XCTAssertEqual(r.config.bindings["view.toggleSidebar"],
                       Shortcut(key: "e", modifiers: [.command, .shift]))
        XCTAssertEqual(r.config.bindings["file.save"],
                       Shortcut(key: "s", modifiers: [.command]))
    }

    func test_parse_malformedValue_isDroppedNotFatal() {
        let json = #"{ "view.toggleSidebar": "cmd+shift+e", "file.save": "nonsense+++" }"#
        let r = KeybindingConfig.parse(data: Data(json.utf8))
        XCTAssertFalse(r.malformedFile)
        // Good entry survives, bad one is reported and dropped.
        XCTAssertEqual(r.config.bindings.count, 1)
        XCTAssertNotNil(r.config.bindings["view.toggleSidebar"])
        XCTAssertNil(r.config.bindings["file.save"])
        XCTAssertEqual(r.invalidValues["file.save"], "nonsense+++")
    }

    func test_parse_unknownID_isReportedAndSkipped() {
        let json = #"{ "totally.bogus.id": "cmd+x", "file.save": "cmd+s" }"#
        let r = KeybindingConfig.parse(data: Data(json.utf8))
        XCTAssertEqual(r.unknownIDs, ["totally.bogus.id"])
        XCTAssertNil(r.config.bindings["totally.bogus.id"])
        XCTAssertNotNil(r.config.bindings["file.save"])
    }

    func test_parse_nonStringValue_isDropped() {
        let json = #"{ "file.save": 42, "view.toggleSidebar": "cmd+e" }"#
        let r = KeybindingConfig.parse(data: Data(json.utf8))
        XCTAssertNil(r.config.bindings["file.save"])
        XCTAssertNotNil(r.invalidValues["file.save"])
        XCTAssertNotNil(r.config.bindings["view.toggleSidebar"])
    }

    func test_parse_nonObjectJSON_isMalformedFile() {
        let r = KeybindingConfig.parse(data: Data(#"["cmd+s"]"#.utf8))
        XCTAssertTrue(r.malformedFile)
        XCTAssertTrue(r.config.isEmpty)
    }

    func test_parse_garbageBytes_isMalformedFile() {
        let r = KeybindingConfig.parse(data: Data("not json at all {".utf8))
        XCTAssertTrue(r.malformedFile)
        XCTAssertTrue(r.config.isEmpty)
    }

    // MARK: - KeybindingConfig load (temp directory)

    func test_load_missingFile_returnsEmptyAndCreatesDir() {
        // tmpDir does not exist yet.
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmpDir.path))
        let r = KeybindingConfig.load(directory: tmpDir)
        XCTAssertTrue(r.config.isEmpty)
        XCTAssertFalse(r.malformedFile)
        // load() creates the directory so a future write has a home.
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmpDir.path))
    }

    func test_load_validFile_appliesOverrides() throws {
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let json = #"{ "view.quickOpen": "cmd+p" }"#
        try Data(json.utf8).write(to: tmpDir.appendingPathComponent("keybinding.json"))
        let r = KeybindingConfig.load(directory: tmpDir)
        XCTAssertEqual(r.config.bindings["view.quickOpen"],
                       Shortcut(key: "p", modifiers: [.command]))
    }

    func test_load_malformedFile_isSafeAndEmpty() throws {
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        try Data("}{".utf8).write(to: tmpDir.appendingPathComponent("keybinding.json"))
        let r = KeybindingConfig.load(directory: tmpDir)
        XCTAssertTrue(r.malformedFile)
        XCTAssertTrue(r.config.isEmpty)
    }

    func test_load_doesNotTouchRealHomeConfig() {
        // Sanity: the default directory is ~/.textview, and our load with
        // an explicit temp dir must not equal it (so the suite never reads
        // or writes the real config).
        XCTAssertNotEqual(tmpDir.standardizedFileURL,
                          KeybindingConfig.defaultDirectory.standardizedFileURL)
    }

    // MARK: - Override precedence (user > default)

    func test_applying_overrideReplacesDefault() {
        // nav.showPalette has a stable built-in default (⇧⌘P); a user override
        // must win over it. (Was view.quickOpen/⌘K before TSK-709 freed ⌘K.)
        let original = CommandRegistry.builtIn.command(id: "nav.showPalette")!
        XCTAssertEqual(original.defaultShortcut, Shortcut(key: "p", modifiers: [.command, .shift]))

        let merged = CommandRegistry.builtIn.applying(
            overrides: ["nav.showPalette": Shortcut(key: "j", modifiers: [.command])])
        let after = merged.command(id: "nav.showPalette")!
        XCTAssertEqual(after.defaultShortcut, Shortcut(key: "j", modifiers: [.command]),
                       "user override must win over built-in default")
        // Identity/category/verb preserved through the merge.
        XCTAssertEqual(after.id, original.id)
        XCTAssertEqual(after.scriptVerb, original.scriptVerb)
        XCTAssertEqual(after.category, original.category)
    }

    func test_applying_unknownIDIsIgnored() {
        let merged = CommandRegistry.builtIn.applying(
            overrides: ["bogus.id": Shortcut(key: "z", modifiers: [.command])])
        XCTAssertNil(merged.command(id: "bogus.id"))
        XCTAssertEqual(merged.commands.count, CommandRegistry.builtIn.commands.count)
    }

    func test_applying_emptyOverridesIsIdentity() {
        let merged = CommandRegistry.builtIn.applying(overrides: [:])
        XCTAssertEqual(merged.commands, CommandRegistry.builtIn.commands)
    }

    // MARK: - Conflict handling (last-wins + report)

    func test_shortcutMap_reportsConflict_lastWins() {
        // Force two commands onto the same keystroke via overrides.
        let key = Shortcut(key: "y", modifiers: [.command, .control, .shift])
        let merged = CommandRegistry.builtIn.applying(overrides: [
            "view.toggleSidebar": key,
            "view.quickOpen": key,
        ])
        var conflicts: [(Shortcut, String, String)] = []
        let map = merged.shortcutMap { sc, losing, winning in
            conflicts.append((sc, losing, winning))
        }
        // Exactly one conflict reported for that key.
        let forKey = conflicts.filter { $0.0 == key }
        XCTAssertEqual(forKey.count, 1)
        // Last in declaration order wins the map entry.
        let winner = map[key]
        XCTAssertNotNil(winner)
        XCTAssertEqual(winner, forKey.first?.2)
    }

    // MARK: - Default shortcut coverage (TSK-325)

    /// The user-facing git/view actions that previously shipped no default
    /// shortcut now carry one, and each routes to its own command (no later
    /// command stole the keystroke via the last-wins shortcutMap).
    func test_addedDefaultShortcuts_arePresentAndConflictFree() {
        let map = CommandRegistry.builtIn.shortcutMap()
        for id in ["git.fileHistory", "git.repoHistory", "view.folderStats"] {
            let cmd = CommandRegistry.builtIn.command(id: id)
            XCTAssertNotNil(cmd?.defaultShortcut, "\(id) should have a default shortcut")
            if let sc = cmd?.defaultShortcut {
                XCTAssertEqual(map[sc], id, "\(id)'s shortcut must route to it (no collision stole it)")
            }
        }
    }

    // MARK: - Copy Reference binding (TSK-942)

    /// ⌘⌥⇧C copies an mdv:// reference (IntelliJ's "Copy Reference" chord), routed
    /// to edit.copyReference without collision; the title drops the "(current line)"
    /// qualifier now that the verb also covers a selected line-RANGE (TSK-942).
    func test_copyReference_cmdOptShiftC_routesToCopyReference_noCollision() {
        let map = CommandRegistry.builtIn.shortcutMap()
        let chord = Shortcut(key: "c", modifiers: [.command, .option, .shift])
        let cmd = CommandRegistry.builtIn.command(id: "edit.copyReference")
        XCTAssertEqual(cmd?.defaultShortcut, chord, "edit.copyReference must bind ⌘⌥⇧C")
        XCTAssertEqual(map[chord], "edit.copyReference",
                       "⌘⌥⇧C must route to Copy Reference (no collision stole it)")
        XCTAssertEqual(cmd?.title, "Copy Reference")
    }

    // MARK: - Natural tab-switch keybindings (TSK-328)

    /// Next/Previous Tab default to the natural macOS combos (⌘⇧] / ⌘⇧[),
    /// matching Safari/Terminal, and each routes to its own command without
    /// colliding with the ⌘⌥[ / ⌘⌥] Move-Tab bindings (shift vs option).
    func test_tabSwitch_naturalDefaults_routeWithoutCollision() {
        let map = CommandRegistry.builtIn.shortcutMap()
        let next = Shortcut(key: "]", modifiers: [.command, .shift])
        let prev = Shortcut(key: "[", modifiers: [.command, .shift])
        XCTAssertEqual(CommandRegistry.builtIn.command(id: "tabs.next")?.defaultShortcut, next)
        XCTAssertEqual(CommandRegistry.builtIn.command(id: "tabs.previous")?.defaultShortcut, prev)
        XCTAssertEqual(map[next], "tabs.next", "⌘⇧] must route to Next Tab")
        XCTAssertEqual(map[prev], "tabs.previous", "⌘⇧[ must route to Previous Tab")
        // The Move-Tab combos stay distinct (different modifier set).
        XCTAssertEqual(map[Shortcut(key: "[", modifiers: [.command, .option])], "tabs.moveLeft")
        XCTAssertEqual(map[Shortcut(key: "]", modifiers: [.command, .option])], "tabs.moveRight")
    }

    // MARK: - Command-palette VS Code parity (TSK-720)

    /// ⇧⌘P opens the command palette (VS Code parity), routed to nav.showPalette
    /// without collision; ⌘K is FREED for the terminal (TSK-709); plain ⌘P is
    /// left UNBOUND, reserved for the macOS-standard Print chord (Mac HIG).
    func test_commandPalette_shiftCmdP_routesToShowPalette_andPlainCmdPStaysFree() {
        let map = CommandRegistry.builtIn.shortcutMap()
        let shiftCmdP = Shortcut(key: "p", modifiers: [.command, .shift])
        XCTAssertEqual(CommandRegistry.builtIn.command(id: "nav.showPalette")?.defaultShortcut,
                       shiftCmdP)
        XCTAssertEqual(map[shiftCmdP], "nav.showPalette", "⇧⌘P must open the command palette")
        XCTAssertNil(map[Shortcut(key: "k", modifiers: [.command])],
                     "⌘K must be FREED for the terminal (TSK-709)")
        XCTAssertNil(map[Shortcut(key: "p", modifiers: [.command])],
                     "plain ⌘P must stay free for the standard Print chord (Mac HIG)")
    }

    // MARK: - Format Document binding (TSK-757)

    /// ⇧⌥F formats the document (VS Code parity), routed to lsp.format without
    /// collision; ⌘⌥F stays Find-and-Replace (distinct modifier set).
    func test_formatDocument_shiftOptF_routesToLspFormat_noCollision() {
        let map = CommandRegistry.builtIn.shortcutMap()
        let shiftOptF = Shortcut(key: "f", modifiers: [.option, .shift])
        XCTAssertEqual(CommandRegistry.builtIn.command(id: "lsp.format")?.defaultShortcut,
                       shiftOptF)
        XCTAssertEqual(map[shiftOptF], "lsp.format", "⇧⌥F must route to Format Document")
        // ⌘⌥F (find.replace) must be untouched — different modifiers.
        XCTAssertEqual(map[Shortcut(key: "f", modifiers: [.command, .option])], "find.replace",
                       "⌘⌥F stays Find and Replace")
    }

    // MARK: - Helpers

    private func duplicates(_ ids: [String]) -> [String] {
        var seen = Set<String>(), dupes = Set<String>()
        for id in ids where !seen.insert(id).inserted { dupes.insert(id) }
        return dupes.sorted()
    }
}
