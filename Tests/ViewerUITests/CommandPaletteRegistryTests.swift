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
        // FuzzyMatcher with an empty query returns every item — the
        // command list when the user has typed only `>`.
        let all = FuzzyMatcher.filterWithMatches(
            model.commandRegistry.commands, query: "") { $0.title }
        XCTAssertEqual(all.count, model.commandRegistry.commands.count)
    }

    func test_palette_fuzzyFilterNarrows() {
        let (model, _) = makeModelAndSessions()
        let hits = FuzzyMatcher.filterWithMatches(
            model.commandRegistry.commands, query: "sidebar") { $0.title }
        XCTAssertFalse(hits.isEmpty)
        XCTAssertLessThan(hits.count, model.commandRegistry.commands.count)
        XCTAssertTrue(hits.contains { $0.item.id == "view.toggleSidebar" })
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
