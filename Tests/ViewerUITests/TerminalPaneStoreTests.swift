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
}
