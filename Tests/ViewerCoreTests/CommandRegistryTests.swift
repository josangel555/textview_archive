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
        ]
        for cmd in CommandRegistry.builtIn.commands {
            guard let verb = cmd.scriptVerb else { continue }
            let token = verb.split(separator: " ").first.map(String.init) ?? verb
            XCTAssertTrue(known.contains(token),
                          "\(cmd.id) uses unknown verb token '\(token)'")
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
        let original = CommandRegistry.builtIn.command(id: "view.quickOpen")!
        XCTAssertEqual(original.defaultShortcut, Shortcut(key: "k", modifiers: [.command]))

        let merged = CommandRegistry.builtIn.applying(
            overrides: ["view.quickOpen": Shortcut(key: "p", modifiers: [.command])])
        let after = merged.command(id: "view.quickOpen")!
        XCTAssertEqual(after.defaultShortcut, Shortcut(key: "p", modifiers: [.command]),
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

    // MARK: - Helpers

    private func duplicates(_ ids: [String]) -> [String] {
        var seen = Set<String>(), dupes = Set<String>()
        for id in ids where !seen.insert(id).inserted { dupes.insert(id) }
        return dupes.sorted()
    }
}
