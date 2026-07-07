import XCTest
import AppKit
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Headless (T1m, host-safe) coverage that the command palette's data
/// source IS the `CommandRegistry`, that it lists every registered
/// command, and that palette invocation dispatches through the pure
/// `ScriptVerb` surface. No window, no NSApp — a hermetic `DocumentModel`
/// + `SessionsAppCoordinator` pair, every persistence URL inside a temp
/// dir.
@MainActor
final class CommandPaletteRegistryTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        let id = UUID().uuidString
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdPalette-\(id)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "CmdPalette-\(id)"
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModelAndSessions() -> (DocumentModel, SessionsAppCoordinator) {
        let model = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            goToPathHistory: GoToPathHistoryStore(
                storeURL: tmpDir.appendingPathComponent("goto.json")),
            bookmarks: BookmarksStore(storeURL: tmpDir.appendingPathComponent("bookmarks.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
        let store = SessionStore(directory: tmpDir.appendingPathComponent("Sessions"))
        let sessions = SessionsAppCoordinator(
            model: model, store: store, initialRoot: nil, autosaveDebounce: 0)
        sessions.bootstrap()
        // Mirror the AppDelegate launch wiring (main.swift): give the model
        // the weak handle so palette command invocation can dispatch.
        model.sessionsCoordinator = sessions
        return (model, sessions)
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Palette lists every registered command

    func test_palette_listsEveryRegisteredCommand() {
        let (model, _) = makeModelAndSessions()
        // The palette's command-mode data source is exactly
        // `model.commandRegistry.commands` (see CommandPaletteView's
        // `recomputeFiltered` command branch). Assert it covers the whole
        // built-in catalog (the registry is the single source of truth).
        let paletteIDs = Set(model.commandRegistry.commands.map(\.id))
        let registryIDs = Set(CommandRegistry.builtIn.commands.map(\.id))
        XCTAssertEqual(paletteIDs, registryIDs)
        XCTAssertFalse(paletteIDs.isEmpty)
    }

    func test_palette_emptyQueryListsAll() {
        let (model, _) = makeModelAndSessions()
        // Empty query returns every item — the command list when the user
        // has typed only `>`. (Stage-B: routed via the rust-only adapter.)
        let all = RustFuzzyAdapter.filterWithMatches(
            model.commandRegistry.commands, query: "") { $0.title }
        XCTAssertEqual(all.count, model.commandRegistry.commands.count)
    }

    func test_palette_fuzzyFilterNarrows() {
        let (model, _) = makeModelAndSessions()
        let hits = RustFuzzyAdapter.filterWithMatches(
            model.commandRegistry.commands, query: "sidebar") { $0.title }
        XCTAssertFalse(hits.isEmpty)
        XCTAssertLessThan(hits.count, model.commandRegistry.commands.count)
        XCTAssertTrue(hits.contains { $0.item.id == "view.toggleSidebar" })
    }

    func test_caseTransforms_arePaletteListed() {
        // TSK-1186: edit.uppercase/lowercase/capitalize dispatch (verb-tested in
        // PaletteEditTransformVerbTests) but had NO palette descriptors — menu-only.
        // Now registered, so they appear in the command palette.
        let (model, _) = makeModelAndSessions()
        let ids = Set(model.commandRegistry.commands.map(\.id))
        XCTAssertTrue(ids.contains("edit.uppercase"), "Uppercase must be palette-listed")
        XCTAssertTrue(ids.contains("edit.lowercase"), "Lowercase must be palette-listed")
        XCTAssertTrue(ids.contains("edit.capitalize"), "Capitalize must be palette-listed")
    }

    // MARK: - Palette invocation dispatches through ScriptVerb

    // NOTE: `model.sessionsCoordinator` is `weak`; bind `sessions` (not `_`) and
    // keep it alive across the assertions, else it deallocs and invokeCommand
    // (which needs the coordinator to dispatch the ScriptVerb pair) returns false.
    func test_invokeCommand_togglesSidebar() {
        let (model, sessions) = makeModelAndSessions()
        let before = model.sidebar.isVisible
        let dispatched = model.invokeCommand(id: "view.toggleSidebar")
        XCTAssertTrue(dispatched)
        XCTAssertNotEqual(model.sidebar.isVisible, before)
        withExtendedLifetime(sessions) {}
    }

    func test_invokeCommand_showPalette_presentsOverlay() {
        let (model, sessions) = makeModelAndSessions()
        XCTAssertFalse(model.isPalettePresented)
        XCTAssertTrue(model.invokeCommand(id: "nav.showPalette"))
        XCTAssertTrue(model.isPalettePresented)
        withExtendedLifetime(sessions) {}
    }

    func test_invokeCommand_crossSearch_presentsOverlay() {
        let (model, sessions) = makeModelAndSessions()
        XCTAssertTrue(model.invokeCommand(id: "find.inFolder"))
        XCTAssertTrue(model.isCrossSearchPresented)
        withExtendedLifetime(sessions) {}
    }

    func test_invokeCommand_nonInvokableCommand_returnsFalse() {
        let (model, _) = makeModelAndSessions()
        // file.open is window-coupled (NSOpenPanel) — scriptVerb == nil.
        XCTAssertFalse(model.invokeCommand(id: "file.open"))
    }

    // MARK: - TSK-326: commands newly omni-invokable via `>`
    //
    // These four commands previously carried `scriptVerb == nil`, so the
    // palette greyed them out (menu-only). Each now routes through the SAME
    // pure model method its View/File-menu item calls. The tests drive the
    // exact palette path — `invokeCommand(id:)` → `ScriptVerb.apply` → model —
    // and pin the model-state OUTCOME so a logic regression fails the host gate
    // (the on-screen render is the VM tail).

    /// Regression guard: every command that this slice converted must now be
    /// palette-invokable. If a future edit drops a verb back to nil, this fails.
    func test_tsk326_newlyInvokableCommands_haveScriptVerb() {
        let nowInvokable = [
            "view.foldAll", "view.unfoldAll",
            "git.repoHistory", "file.clearRecents",
        ]
        for id in nowInvokable {
            let cmd = CommandRegistry.builtIn.command(id: id)
            XCTAssertNotNil(cmd, "\(id) missing from the registry")
            XCTAssertTrue(cmd?.isPaletteInvokable ?? false,
                          "\(id) must be omni-invokable (scriptVerb != nil)")
        }
    }

    func test_invokeCommand_foldAll_inSource_dispatchesFold() throws {
        let url = try writeFile("code.swift", "func f() {\n  let x = 1\n}\n")
        let (model, sessions) = makeModelAndSessions()
        model.open(url: url)
        model.setCurrentViewMode(.source)
        XCTAssertTrue(model.canFoldActiveDocument)
        XCTAssertNil(model.lastFoldDispatch)

        let dispatched = model.invokeCommand(id: "view.foldAll")
        XCTAssertTrue(dispatched, "fold-all verb recognised + applied")
        XCTAssertEqual(model.lastFoldDispatch?.command, .foldAll)
        XCTAssertEqual(model.lastFoldDispatch?.target, .source)
        withExtendedLifetime(sessions) {}
    }

    func test_invokeCommand_unfoldAll_inEditor_dispatchesFold() throws {
        let url = try writeFile("code.swift", "func f() {\n  let x = 1\n}\n")
        let (model, sessions) = makeModelAndSessions()
        model.open(url: url)
        model.setCurrentViewMode(.editor)

        let dispatched = model.invokeCommand(id: "view.unfoldAll")
        XCTAssertTrue(dispatched)
        XCTAssertEqual(model.lastFoldDispatch?.command, .unfoldAll)
        XCTAssertEqual(model.lastFoldDispatch?.target, .editor)
        withExtendedLifetime(sessions) {}
    }

    func test_invokeCommand_foldAll_inNonFoldableLens_isInertNoOp() throws {
        let url = try writeFile("doc.md", "# Title\n\nbody\n")
        let (model, sessions) = makeModelAndSessions()
        model.open(url: url)
        // Markdown defaults to .rendered — non-foldable.
        XCTAssertEqual(model.currentViewMode, .rendered)
        // The verb is still RECOGNISED (dispatched == true), but the model
        // method no-ops in a non-foldable lens — exactly the greyed-menu
        // behaviour, so a `>`-invoked Fold All here does nothing.
        XCTAssertTrue(model.invokeCommand(id: "view.foldAll"))
        XCTAssertNil(model.lastFoldDispatch,
                     "no fold dispatch recorded in a non-foldable lens")
        withExtendedLifetime(sessions) {}
    }

    func test_invokeCommand_repoHistory_opensGitPanelOnLogTab() {
        let (model, sessions) = makeModelAndSessions()
        let beforeNonce = model.gitPanelFocusRequest
        XCTAssertTrue(model.invokeCommand(id: "git.repoHistory"))
        XCTAssertEqual(model.gitPanelDesiredTab, .log,
                       "Show Repository History opens the Git panel on Log")
        XCTAssertEqual(model.gitPanelFocusRequest, beforeNonce + 1,
                       "the focus-request nonce bumps so the panel surfaces")
        withExtendedLifetime(sessions) {}
    }

    func test_invokeCommand_clearRecents_emptiesRecents() throws {
        let url = try writeFile("seen.md", "# Seen\n")
        let (model, sessions) = makeModelAndSessions()
        // Open a file so it lands in the recents/history store.
        model.open(url: url)
        XCTAssertFalse(model.recents.isEmpty,
                       "opening a file should populate recents")

        XCTAssertTrue(model.invokeCommand(id: "file.clearRecents"))
        XCTAssertTrue(model.recents.isEmpty,
                      "Clear Recent Files empties the recents list")
        withExtendedLifetime(sessions) {}
    }

    func test_invokeCommand_unknownID_returnsFalse() {
        let (model, _) = makeModelAndSessions()
        XCTAssertFalse(model.invokeCommand(id: "no.such.command"))
    }

    func test_invokeCommand_withoutSessionsCoordinator_returnsFalseNoCrash() {
        let model = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("h.json")),
            bookmarks: BookmarksStore(storeURL: tmpDir.appendingPathComponent("b.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
        // No sessionsCoordinator wired — must not crash, just decline.
        XCTAssertFalse(model.invokeCommand(id: "view.toggleSidebar"))
    }

    // MARK: - Keybinding override flows through to the model registry

    func test_loadKeybindings_overrideReachesModelRegistry() throws {
        let (model, _) = makeModelAndSessions()
        let keybindDir = tmpDir.appendingPathComponent("dotconfig")
        try FileManager.default.createDirectory(at: keybindDir, withIntermediateDirectories: true)
        let json = #"{ "view.quickOpen": "cmd+p" }"#
        try Data(json.utf8).write(to: keybindDir.appendingPathComponent("keybinding.json"))

        model.loadKeybindings(directory: keybindDir)
        let cmd = model.commandRegistry.command(id: "view.quickOpen")
        XCTAssertEqual(cmd?.defaultShortcut, Shortcut(key: "p", modifiers: [.command]))
    }
}
