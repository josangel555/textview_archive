import XCTest
import Foundation
import ViewerCore
@testable import ViewerUI

/// Owner rework 2026-08-09 — the terminal is a REGULAR tool window
/// (`SidebarPanelKind.terminal`): docked/moved/toggled through the unified
/// panel model with ZERO special handling. Pins the default placement, the
/// user-summoned visibility semantics, the legacy-state migration, and the
/// last-tab-closed → hide bridge.
@MainActor
final class TerminalPanelTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "TerminalPanelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() async throws {
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
    }

    // MARK: - Default placement + visibility semantics

    func test_terminal_defaultsToBottomRail_hidden() {
        let store = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(store.edge(of: .terminal), .bottom,
                       "the terminal's per-panel default edge is the bottom dock")
        XCTAssertTrue(store.railPanels(on: .bottom).contains(.terminal),
                      "the bottom rail carries the terminal's toggle button")
        XCTAssertFalse(store.railPanels(on: .left).contains(.terminal))
        XCTAssertFalse(store.isVisible(.terminal, dataPresent: false),
                       "a fresh install shows NO terminal (user-summoned)")
    }

    func test_terminal_presenceIsAlwaysFalse_userSummoned() {
        // Presence false ⇒ `.auto` resolves hidden; only the explicit toggle
        // shows it. A presence heuristic flipping true would auto-open a
        // shell pane for every user — pin against that.
        let presence = SidebarDataPresence.evaluate(
            .init(hasRoot: true, hasRepo: true, hasLSPLanguage: true,
                  claudeHasTranscripts: true, hasRecents: true, hasMarkdownFile: true))
        XCTAssertEqual(presence[.terminal], false,
                       "the terminal is never data-driven")
    }

    func test_toggle_showsAndHides_likeAnyPanel() {
        let store = PanelLayoutStore(defaults: defaults)
        store.toggle(.terminal, dataPresent: false)
        XCTAssertTrue(store.isVisible(.terminal, dataPresent: false),
                      "the rail button / ⌃` menu toggle summons the terminal")
        store.toggle(.terminal, dataPresent: false)
        XCTAssertFalse(store.isVisible(.terminal, dataPresent: false))
    }

    func test_terminal_isDockableToEveryShoulder() {
        for edge in PanelEdge.allCases {
            XCTAssertTrue(PanelPlacement.isLegal(.terminal, to: edge),
                          "the terminal docks anywhere, like any panel (\(edge))")
        }
    }

    func test_move_terminal_behavesLikeAnyPanel_andNormalizesToItsDefault() {
        let store = PanelLayoutStore(defaults: defaults)
        store.move(.terminal, to: .right)
        XCTAssertEqual(store.edge(of: .terminal), .right)
        XCTAssertTrue(store.isVisible(.terminal, dataPresent: false),
                      "a drag onto a dock surfaces the panel (forceShown)")
        // Back to its own default (.bottom, NOT the global .left default) —
        // the per-panel preferred default wins in normalization too.
        store.move(.terminal, to: .bottom)
        XCTAssertEqual(store.edge(of: .terminal), .bottom)
        let reloaded = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(reloaded.edge(of: .terminal), .bottom,
                       "the normalized (default-edge) assignment survives a relaunch")
    }

    func test_registry_coversTerminal() {
        XCTAssertTrue(SidebarPanelRegistry.coversAllCases)
        XCTAssertTrue(SidebarPanelRegistry.defaultOrder.contains(.terminal))
    }

    // MARK: - Legacy-state migration (TerminalPanelMigration)

    func test_migration_keys_areStable() {
        XCTAssertEqual(TerminalPanelMigration.markerKey, "MarkdownViewer.terminal.migratedToPanel")
        XCTAssertEqual(TerminalPanelMigration.legacyOpenKey, "MarkdownViewer.terminal.isOpen")
        XCTAssertEqual(TerminalPanelMigration.legacyPaneEdgeKey, "MarkdownViewer.terminal.paneEdge")
    }

    func test_migration_openBottomPane_becomesShownBottomPanel() {
        defaults.set(true, forKey: TerminalPanelMigration.legacyOpenKey)
        let store = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(store.edge(of: .terminal), .bottom)
        XCTAssertTrue(store.isVisible(.terminal, dataPresent: false),
                      "a user who had the pane open keeps it open")
        XCTAssertTrue(defaults.bool(forKey: TerminalPanelMigration.markerKey))
    }

    func test_migration_legacySideEdge_mapsToPanelEdge() {
        defaults.set(true, forKey: TerminalPanelMigration.legacyOpenKey)
        defaults.set("right", forKey: TerminalPanelMigration.legacyPaneEdgeKey)
        let store = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(store.edge(of: .terminal), .right,
                       "the legacy side dock carries over")
        XCTAssertTrue(store.isVisible(.terminal, dataPresent: false))
    }

    func test_migration_closedPane_staysHidden() {
        defaults.set(false, forKey: TerminalPanelMigration.legacyOpenKey)
        let store = PanelLayoutStore(defaults: defaults)
        XCTAssertFalse(store.isVisible(.terminal, dataPresent: false),
                       "a closed legacy pane must not surface the panel")
        XCTAssertTrue(defaults.bool(forKey: TerminalPanelMigration.markerKey),
                      "the migration still stamps so it never re-runs")
    }

    func test_migration_runsExactlyOnce_userChoiceWinsAfter() {
        defaults.set(true, forKey: TerminalPanelMigration.legacyOpenKey)
        let first = PanelLayoutStore(defaults: defaults)
        XCTAssertTrue(first.isVisible(.terminal, dataPresent: false))
        // The user hides it after migrating…
        first.setOverride(.terminal, .hidden)
        // …and a relaunch must RESPECT that, not re-migrate the stale legacy key.
        let second = PanelLayoutStore(defaults: defaults)
        XCTAssertFalse(second.isVisible(.terminal, dataPresent: false),
                       "migration is one-shot — it must not clobber a later user choice")
    }

    func test_freshInstall_noLegacyKeys_noMigration() {
        XCTAssertNil(TerminalPanelMigration.pendingMigration(in: defaults),
                     "no legacy state ⇒ nothing to migrate")
    }

    // MARK: - Last-tab-closed → hide bridge

    func test_closingLastTab_firesHideCallback() {
        let store = TerminalPaneStore(defaults: defaults)
        defer { store.shutdown() }
        var hideFired = 0
        store.onLastTabClosed = { hideFired += 1 }
        store.setOpen(true)                       // seeds one tab
        XCTAssertEqual(store.tabs.count, 1)
        store.closeTab(store.tabs[0].id)
        XCTAssertEqual(hideFired, 1,
                       "closing the LAST tab must ask the panel layer to hide the tool window")
        XCTAssertFalse(store.isOpen)
    }

    func test_closingNonLastTab_doesNotFireHideCallback() {
        let store = TerminalPaneStore(defaults: defaults)
        defer { store.shutdown() }
        var hideFired = 0
        store.onLastTabClosed = { hideFired += 1 }
        store.setOpen(true)
        store.addTab()
        XCTAssertEqual(store.tabs.count, 2)
        store.closeTab(store.tabs[0].id)
        XCTAssertEqual(hideFired, 0, "a surviving tab keeps the tool window up")
    }

    func test_documentModel_wiresLastTabClosed_toPanelHide() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalPanelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let model = DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmp.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults))
        defer { model.terminalPane.shutdown() }
        model.panelLayout.toggle(.terminal, dataPresent: false)   // summon
        model.terminalPane.setOpen(true)
        XCTAssertTrue(model.panelLayout.isVisible(.terminal, dataPresent: false))
        model.terminalPane.closeTab(model.terminalPane.tabs[0].id)
        XCTAssertFalse(model.panelLayout.isVisible(.terminal, dataPresent: false),
                       "closing the last shell tab hides the terminal tool window")
    }
}
