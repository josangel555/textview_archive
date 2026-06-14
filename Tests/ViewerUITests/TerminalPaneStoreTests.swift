import XCTest
import Combine
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Tier 1m coverage for the bottom terminal pane's observable store
/// (#226). Pins (a) the open/height behaviour + write-through
/// persistence, and (b) the narrow-observation invariant: toggling the
/// terminal must NOT republish `DocumentModel` (same discipline as
/// `PanelLayoutStore` — a terminal toggle must re-body only the directly-
/// observing `ContentView`/rail, never the whole content tree).
///
/// The LIVE shell (PTYProcess) is deliberately NOT spawned/exercised
/// here — these tests drive only the store's persisted state + lazy
/// model creation. The fork/exec path is not host-unit-testable.
@MainActor
final class TerminalPaneStoreTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalPaneStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "TerminalPaneStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    private func countDocumentRepublishes(
        of model: DocumentModel,
        whileRunning mutate: () -> Void
    ) async -> Int {
        var count = 0
        let sub = model.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        mutate()
        await Task.yield()
        return count
    }

    // MARK: - Defaults

    func test_freshStore_isClosed_noTerminalSpawned() {
        let store = TerminalPaneStore(defaults: defaults)
        XCTAssertFalse(store.isOpen)
        XCTAssertNil(store.terminal, "shell must spawn lazily, not at construction")
    }

    func test_open_createsTerminal() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)
        XCTAssertTrue(store.isOpen)
        XCTAssertNotNil(store.terminal, "opening creates the terminal model")
    }

    func test_toggle_flipsOpen() {
        let store = TerminalPaneStore(defaults: defaults)
        store.toggle()
        XCTAssertTrue(store.isOpen)
        store.toggle()
        XCTAssertFalse(store.isOpen)
    }

    func test_setHeight_clampsAndPersists() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setHeight(5)
        XCTAssertEqual(store.height, store.minHeight)
        store.setHeight(99999)
        XCTAssertEqual(store.height, store.maxHeight)
        store.setHeight(300)
        XCTAssertEqual(store.height, 300)
    }

    // MARK: - Pane dock edge + side width (TSK-491)

    func test_paneEdge_defaultsBottom_thenSetsAndPersists() {
        let store = TerminalPaneStore(defaults: defaults)
        XCTAssertEqual(store.paneEdge, .bottom)
        store.setPaneEdge(.right)
        XCTAssertEqual(store.paneEdge, .right)
        // "Relaunch" restores the new edge.
        let reloaded = TerminalPaneStore(defaults: defaults)
        XCTAssertEqual(reloaded.paneEdge, .right)
    }

    func test_setWidth_clampsAndPersists() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setWidth(5)
        XCTAssertEqual(store.sideWidth, store.minWidth)
        store.setWidth(99999)
        XCTAssertEqual(store.sideWidth, store.maxWidth)
        store.setWidth(420)
        XCTAssertEqual(store.sideWidth, 420)
        let reloaded = TerminalPaneStore(defaults: defaults)
        XCTAssertEqual(reloaded.sideWidth, 420)
    }

    // MARK: - Persistence

    func test_openAndHeight_persistThroughDefaults() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)
        store.setHeight(275)
        // "Relaunch" — a fresh store on the same suite restores state.
        let reloaded = TerminalPaneStore(defaults: defaults)
        XCTAssertTrue(reloaded.isOpen)
        XCTAssertEqual(reloaded.height, 275)
        // Restored-open store eagerly readies the terminal model.
        XCTAssertNotNil(reloaded.terminal)
    }

    // MARK: - Narrow observation (must NOT republish DocumentModel)

    func test_documentModel_ownsTerminalPane_fromInjectedDefaults() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)
        // A fresh model on the same suite must see the persisted open flag.
        let model = makeModel()
        XCTAssertTrue(model.terminalPane.isOpen,
                      "DocumentModel.terminalPane must load from the injected defaults suite")
    }

    func test_toggle_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.terminalPane.toggle()
        }
        XCTAssertEqual(count, 0,
            "Terminal toggle must not republish DocumentModel; ContentView/rail observe terminalPane directly")
    }

    func test_setHeight_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        model.terminalPane.setOpen(true)
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.terminalPane.setHeight(250)
        }
        XCTAssertEqual(count, 0, "Drag-resize must not republish DocumentModel")
    }

    // MARK: - Positive control

    func test_terminalPane_doesRepublishOnToggle() async {
        let model = makeModel()
        var count = 0
        let sub = model.terminalPane.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        model.terminalPane.toggle()
        await Task.yield()
        XCTAssertGreaterThan(count, 0,
            "TerminalPaneStore.objectWillChange must fire on toggle so ContentView/rail re-body")
    }

    // MARK: - Tabs

    func test_open_createsOneTab_selected() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)
        XCTAssertEqual(store.tabs.count, 1)
        XCTAssertEqual(store.selectedTabID, store.tabs.first?.id)
        XCTAssertEqual(store.tabs.first?.number, 1)
    }

    func test_addTab_appendsAndSelects() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)
        store.addTab()
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.selectedTabID, store.tabs[1].id, "new tab becomes selected")
        XCTAssertEqual(store.tabs.map(\.number), [1, 2])
    }

    func test_selectTab_switchesSelection() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)               // tab 1
        store.addTab()                    // tab 2 (selected)
        let first = store.tabs[0].id
        store.selectTab(first)
        XCTAssertEqual(store.selectedTabID, first)
        XCTAssertNotNil(store.terminal)
    }

    func test_closeTab_selectsNeighbor() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)               // 1
        store.addTab()                    // 2
        store.addTab()                    // 3 (selected)
        let middle = store.tabs[1].id
        store.selectTab(middle)
        store.closeTab(middle)
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertFalse(store.tabs.contains { $0.id == middle })
        XCTAssertNotNil(store.selectedTabID, "a neighbor is selected after closing the active tab")
        XCTAssertTrue(store.tabs.contains { $0.id == store.selectedTabID })
    }

    func test_closeLastTab_closesPane() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)
        let only = store.tabs[0].id
        store.closeTab(only)
        XCTAssertTrue(store.tabs.isEmpty)
        XCTAssertNil(store.selectedTabID)
        XCTAssertFalse(store.isOpen, "closing the last tab closes the whole pane")
    }

    func test_reopen_afterCloseAll_restartsNumberingAtOne() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)               // tab 1
        store.addTab()                    // tab 2
        store.closeTab(store.tabs[1].id)  // back to 1 tab
        store.closeTab(store.tabs[0].id)  // pane closes, numbering resets
        store.setOpen(true)               // fresh tab
        XCTAssertEqual(store.tabs.first?.number, 1)
    }

    func test_cycleTab_wrapsForwardAndBackward() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)               // tab 1 (selected)
        store.addTab()                    // tab 2
        store.addTab()                    // tab 3 (selected)
        let ids = store.tabs.map(\.id)
        XCTAssertEqual(store.selectedTabID, ids[2])
        store.cycleTab(forward: true)     // 3 -> wrap -> 1
        XCTAssertEqual(store.selectedTabID, ids[0])
        store.cycleTab(forward: true)     // 1 -> 2
        XCTAssertEqual(store.selectedTabID, ids[1])
        store.cycleTab(forward: false)    // 2 -> 1
        XCTAssertEqual(store.selectedTabID, ids[0])
        store.cycleTab(forward: false)    // 1 -> wrap -> 3
        XCTAssertEqual(store.selectedTabID, ids[2])
    }

    func test_cycleTab_singleTab_isNoOp() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)
        let only = store.selectedTabID
        store.cycleTab(forward: true)
        store.cycleTab(forward: false)
        XCTAssertEqual(store.selectedTabID, only)
    }

    // MARK: - Foreground gating (TSK-459)

    func test_open_selectedTabIsForeground() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)
        XCTAssertTrue(store.tabs[0].model.isForeground,
                      "the sole open tab is foreground")
    }

    func test_addTab_backgroundsPreviousSelection() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)               // tab 1 (selected, fg)
        store.addTab()                    // tab 2 (selected, fg) → tab 1 bg
        XCTAssertTrue(store.tabs[1].model.isForeground, "new selected tab is foreground")
        XCTAssertFalse(store.tabs[0].model.isForeground, "deselected tab is backgrounded")
    }

    func test_selectTab_movesForegroundToSelection() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)               // tab 1
        store.addTab()                    // tab 2 (selected)
        store.selectTab(store.tabs[0].id) // back to tab 1
        XCTAssertTrue(store.tabs[0].model.isForeground)
        XCTAssertFalse(store.tabs[1].model.isForeground)
    }

    func test_cycleTab_movesForeground() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)               // 1
        store.addTab()                    // 2
        store.addTab()                    // 3 (selected, fg)
        store.cycleTab(forward: true)     // wrap → 1 fg
        XCTAssertTrue(store.tabs[0].model.isForeground)
        XCTAssertFalse(store.tabs[1].model.isForeground)
        XCTAssertFalse(store.tabs[2].model.isForeground)
    }

    func test_closePane_backgroundsEveryTab() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)               // 1
        store.addTab()                    // 2 (selected)
        // Capture models before closing (closeTab on the last tab clears tabs).
        let models = store.tabs.map(\.model)
        store.setOpen(false)              // pane hidden → nothing is visible
        for m in models {
            XCTAssertFalse(m.isForeground, "a hidden pane has no foreground shell")
        }
    }

    func test_reopen_restoresForegroundOnSelectedTab() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)
        let model = store.tabs[0].model
        store.setOpen(false)
        XCTAssertFalse(model.isForeground)
        store.setOpen(true)
        XCTAssertTrue(model.isForeground, "reopening the pane re-foregrounds the selected shell")
    }

    func test_closeActiveTab_foregroundsTheNeighbor() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)               // 1
        store.addTab()                    // 2
        store.addTab()                    // 3 (selected)
        store.closeTab(store.tabs[2].id)  // neighbor (tab 2) becomes selected
        let selected = store.tabs.first { $0.id == store.selectedTabID }
        XCTAssertNotNil(selected)
        XCTAssertTrue(selected!.model.isForeground)
        XCTAssertFalse(store.tabs[0].model.isForeground, "non-selected tab stays backgrounded")
    }

    // MARK: - Idempotence

    func test_setOpen_sameValue_isNoOpRepublish() async {
        let model = makeModel()
        model.terminalPane.setOpen(false)   // already closed
        var count = 0
        let sub = model.terminalPane.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        model.terminalPane.setOpen(false)
        await Task.yield()
        XCTAssertEqual(count, 0, "setOpen with the same value must be a no-op")
    }

    // MARK: - Tab rename (TSK-771)

    func test_renameTab_setsCustomLabelAndTitle() {
        let store = TerminalPaneStore(defaults: defaults)
        store.addTab()
        let tab = store.tabs[0]
        // Default before any rename: bare number in the chip, "Terminal N" title.
        XCTAssertEqual(store.tabLabel(for: tab), "\(tab.number)")
        XCTAssertEqual(store.tabTitle(for: tab), "Terminal \(tab.number)")

        store.renameTab(tab.id, to: "build")
        XCTAssertEqual(store.tabLabel(for: tab), "build")
        XCTAssertEqual(store.tabTitle(for: tab), "build")
        XCTAssertEqual(store.customNames[tab.id], "build")
    }

    func test_renameTab_trimsSurroundingWhitespace() {
        let store = TerminalPaneStore(defaults: defaults)
        store.addTab()
        let tab = store.tabs[0]
        store.renameTab(tab.id, to: "  logs  ")
        XCTAssertEqual(store.tabLabel(for: tab), "logs")
    }

    func test_renameTab_emptyOrBlank_clearsBackToDefault() {
        let store = TerminalPaneStore(defaults: defaults)
        store.addTab()
        let tab = store.tabs[0]
        store.renameTab(tab.id, to: "x")
        XCTAssertEqual(store.customNames[tab.id], "x")
        store.renameTab(tab.id, to: "   ")   // blank → clear
        XCTAssertNil(store.customNames[tab.id])
        XCTAssertEqual(store.tabLabel(for: tab), "\(tab.number)")
        XCTAssertEqual(store.tabTitle(for: tab), "Terminal \(tab.number)")
    }

    func test_renameTab_unknownID_isNoOp() {
        let store = TerminalPaneStore(defaults: defaults)
        store.addTab()
        store.renameTab(UUID(), to: "nope")
        XCTAssertTrue(store.customNames.isEmpty, "an unknown id must not create a name entry")
    }

    func test_closeTab_dropsOnlyItsOwnName() {
        let store = TerminalPaneStore(defaults: defaults)
        store.addTab()  // number 1
        store.addTab()  // number 2
        let t1 = store.tabs[0], t2 = store.tabs[1]
        store.renameTab(t1.id, to: "one")
        store.renameTab(t2.id, to: "two")
        store.closeTab(t1.id)
        XCTAssertNil(store.customNames[t1.id], "the closed tab's name is dropped (no leak)")
        XCTAssertEqual(store.customNames[t2.id], "two", "the surviving tab keeps its name")
    }

    func test_closingLastTab_clearsAllNames() {
        let store = TerminalPaneStore(defaults: defaults)
        store.setOpen(true)            // ensures one tab
        let tab = store.tabs[0]
        store.renameTab(tab.id, to: "solo")
        store.closeTab(tab.id)         // last tab → pane closes, names cleared
        XCTAssertTrue(store.customNames.isEmpty)
    }

    // MARK: - Open Terminal Here (TSK-769)

    func test_addTab_withWorkingDirectory_seedsModelInitialCwd() {
        let store = TerminalPaneStore(defaults: defaults)
        let cwd = URL(fileURLWithPath: "/tmp/work", isDirectory: true)
        store.addTab(workingDirectory: cwd)
        XCTAssertEqual(store.tabs.last?.model.initialWorkingDirectory, cwd)
    }

    func test_addTab_noWorkingDirectory_leavesInitialCwdNil() {
        let store = TerminalPaneStore(defaults: defaults)
        store.addTab()
        XCTAssertNil(store.tabs.last?.model.initialWorkingDirectory)
    }

    func test_openTerminalHere_noFocusedFile_opensPaneWithExactlyOneTab() {
        let model = makeModel()
        XCTAssertFalse(model.terminalPane.isOpen)
        model.openTerminalHere()       // no focused file → home fallback
        XCTAssertTrue(model.terminalPane.isOpen, "opens the terminal pane")
        // The load-bearing assertion: addTab BEFORE setOpen, so ensureTerminal
        // doesn't ALSO spawn a default home tab (would be 2).
        XCTAssertEqual(model.terminalPane.tabs.count, 1, "exactly one tab, no extra default")
        XCTAssertNil(model.terminalPane.tabs.last?.model.initialWorkingDirectory,
            "no focused file → nil cwd (the shell falls back to home)")
    }
}
