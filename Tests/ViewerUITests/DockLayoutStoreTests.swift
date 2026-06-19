import XCTest
import Combine
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// UX-E / #227 — store-level tests for the docked-tool-window layout:
///
///   * fixed dock SIZE set/persist/clamp (brief items 1 + 2),
///   * the dock-ASSIGNMENT model: a panel's dock can change + persists,
///     and the right/bottom container resolution picks up the move,
///   * the narrow-observation invariant: the new `setDockSize` / `move`
///     mutations must NOT republish `DocumentModel` (same discipline as
///     `setEdge` / `toggle`, pinned by `PanelLayoutRepublishInvariantTests`).
///
/// Host-safe T1m (`HeadlessUITestCase` floor): pure @MainActor store logic,
/// no NSApplication, no window.
@MainActor
final class DockLayoutStoreTests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DockLayoutStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DockLayoutStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeStore() -> PanelLayoutStore {
        PanelLayoutStore(defaults: defaults)
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
        of model: DocumentModel, whileRunning mutate: () -> Void
    ) async -> Int {
        var count = 0
        let sub = model.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        mutate()
        await Task.yield()
        return count
    }

    // MARK: - fixed dock size: default, set, persist, clamp

    func test_dockSize_defaultsToPerEdgeDefault_notTiny() {
        let store = makeStore()
        XCTAssertEqual(store.dockSize(.git, on: .right), PanelDockLayout.defaultRightWidth)
        XCTAssertEqual(store.dockSize(.git, on: .bottom), PanelDockLayout.defaultBottomHeight)
    }

    func test_setDockSize_persistsThroughDefaults() async {
        let store = makeStore()
        store.setDockSize(360, for: .git, on: .right)
        await Task.yield()
        XCTAssertEqual(store.dockSize(.git, on: .right), 360)
        // "Relaunch": a brand-new store on the same suite must read it back.
        let reloaded = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(reloaded.dockSize(.git, on: .right), 360,
                       "Dock size must write through to defaults synchronously")
    }

    func test_setDockSize_clampsFloor_butHasNoUXMaximum() {
        let store = makeStore()
        store.setDockSize(10, for: .git, on: .right)
        XCTAssertEqual(store.dockSize(.git, on: .right), PanelDockLayout.minSize,
                       "Below-floor size clamps up to the minimum")
        // A genuinely large width is kept verbatim — NO maximum (brief #2).
        store.setDockSize(4000, for: .git, on: .right)
        XCTAssertEqual(store.dockSize(.git, on: .right), 4000)
    }

    // MARK: - dock-assignment model: move changes edge + persists

    func test_move_changesEdge_andPersists() async {
        let store = makeStore()
        XCTAssertEqual(store.edge(of: .git), .left)
        store.move(.git, to: .right)
        await Task.yield()
        XCTAssertEqual(store.edge(of: .git), .right)
        // Persisted.
        let reloaded = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(reloaded.edge(of: .git), .right,
                       "A redock must persist the new edge assignment")
    }

    func test_move_offLeft_forcesShown_soPanelMaterializes() {
        let store = makeStore()
        // .git starts .auto (no repo ⇒ would resolve hidden). Moving it to a
        // free-standing dock must surface it (else it silently vanishes).
        XCTAssertEqual(store.override(for: .git), .auto)
        store.move(.git, to: .right)
        XCTAssertEqual(store.override(for: .git), .shown,
                       "Dragging a panel onto a dock must force it shown")
        XCTAssertTrue(store.isVisible(.git, dataPresent: false))
    }

    func test_move_leavesExplicitHiddenAlone() {
        let store = makeStore()
        store.setOverride(.git, .hidden)
        store.move(.git, to: .right)
        XCTAssertEqual(store.override(for: .git), .hidden,
                       "Redock must not override an intentional .hidden")
    }

    func test_move_backToLeft_doesNotForceShown() {
        let store = makeStore()
        store.move(.git, to: .right)       // → .shown
        store.setOverride(.git, .auto)      // user resets
        store.move(.git, to: .left)         // back home
        XCTAssertEqual(store.edge(of: .git), .left)
        XCTAssertEqual(store.override(for: .git), .auto,
                       "Moving back to the accordion must not force shown")
    }

    func test_move_sameEdge_isNoOpEdgeChange() async {
        let store = makeStore()
        store.move(.git, to: .right)
        await Task.yield()
        var count = 0
        let sub = store.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        store.move(.git, to: .right)   // already there
        await Task.yield()
        XCTAssertEqual(count, 0, "Re-dropping on the same edge must be a no-op")
    }

    // MARK: - placement validation: illegal moves are rejected (TSK-495)

    func test_move_nonDockablePanel_isRejected() async {
        let store = makeStore()
        // FILES is not a free-standing tool window — moving it to a dock
        // must be rejected by the placement validator, not stored.
        store.move(.files, to: .right)
        await Task.yield()
        XCTAssertEqual(store.edge(of: .files), .left,
                       "A non-dockable panel must stay on .left")
        // And it must NOT have been force-shown by the rejected move.
        XCTAssertEqual(store.override(for: .files), .auto)
    }

    func test_move_nonDockablePanel_doesNotRepublish() async {
        let store = makeStore()
        var count = 0
        let sub = store.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        store.move(.files, to: .bottom)   // illegal ⇒ no-op
        await Task.yield()
        XCTAssertEqual(count, 0, "A rejected move must not republish the store")
    }

    func test_setEdge_nonDockablePanel_isRejected() {
        let store = makeStore()
        store.setEdge(.files, .right)   // illegal low-level setter call
        XCTAssertEqual(store.edge(of: .files), .left,
                       "setEdge must route through the validator too")
    }

    func test_setEdge_dockablePanel_isApplied() {
        let store = makeStore()
        store.setEdge(.git, .bottom)
        XCTAssertEqual(store.edge(of: .git), .bottom)
    }

    // MARK: - global default edge (TSK-495)

    func test_setDefaultEdge_movesUntouchedPanels_andPersists() async {
        let store = makeStore()
        XCTAssertEqual(store.edge(of: .git), .left)
        store.setDefaultEdge(.right)
        await Task.yield()
        // An untouched panel now resolves to the new default.
        XCTAssertEqual(store.edge(of: .git), .right)
        // FILES still resolves to the default too (the default applies to
        // every panel's absence) — but FILES is never *rendered* as a dock
        // (DockResolution filters non-dockable), and you still can't
        // explicitly move it off .left.
        let reloaded = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(reloaded.edge(of: .git), .right,
                       "Global default edge must persist across a relaunch")
    }

    func test_setDefaultEdge_sameValue_isNoOp() async {
        let store = makeStore()
        var count = 0
        let sub = store.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        store.setDefaultEdge(.left)   // already the default
        await Task.yield()
        XCTAssertEqual(count, 0, "Re-setting the same default edge is a no-op")
    }

    func test_setDefaultEdge_explicitOverrideStillWins() {
        let store = makeStore()
        store.setEdge(.git, .bottom)        // explicit override
        store.setDefaultEdge(.right)         // flip the global default
        XCTAssertEqual(store.edge(of: .git), .bottom,
                       "An explicit per-panel override beats the global default")
    }

    // MARK: - dock resolution: container picks up the moved panel

    func test_dockResolution_visiblePanels_reflectsMove() {
        let store = makeStore()
        let presence = SidebarDataPresence.evaluate(.init(hasRoot: true, hasRepo: true))
        // Before: nothing is right-docked.
        XCTAssertTrue(
            DockResolution.visiblePanels(on: .right, panelLayout: store, presence: presence).isEmpty
        )
        store.move(.git, to: .right)
        // After: git resolves visible on the right dock.
        XCTAssertEqual(
            DockResolution.visiblePanels(on: .right, panelLayout: store, presence: presence),
            [.git]
        )
        // And it is NO LONGER on the left rail set.
        XCTAssertFalse(store.railPanels(on: .left).contains(.git))
    }

    func test_dockResolution_filtersOutFiles() {
        let store = makeStore()
        // TSK-495: the assignment itself is now rejected at the model layer
        // (FILES is not dockable), so this setEdge is a no-op — FILES stays
        // on .left. The resolution filter is the SECOND, defense-in-depth
        // guard: even if a panel slipped through assignment, a non-dockable
        // kind is never a free-standing tool window.
        store.setEdge(.files, .bottom)
        XCTAssertEqual(store.edge(of: .files), .left,
                       "Assigning FILES to a dock must be rejected")
        store.setOverride(.files, .shown)
        let presence = SidebarDataPresence.evaluate(.init(hasRoot: true))
        XCTAssertFalse(
            DockResolution.visiblePanels(on: .bottom, panelLayout: store, presence: presence)
                .contains(.files)
        )
    }

    // MARK: - narrow-observation invariant (no DocumentModel republish)

    func test_setDockSize_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.panelLayout.setDockSize(340, for: .git, on: .right)
        }
        XCTAssertEqual(count, 0,
            "Dock resize must not republish DocumentModel (docked panes observe panelLayout directly)")
    }

    func test_move_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.panelLayout.move(.git, to: .right)
        }
        XCTAssertEqual(count, 0, "Redock must not republish DocumentModel")
    }

    func test_setDockSize_doesRepublishStore() async {
        let model = makeModel()
        var count = 0
        let sub = model.panelLayout.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        model.panelLayout.setDockSize(360, for: .git, on: .right)
        await Task.yield()
        XCTAssertGreaterThan(count, 0,
            "setDockSize must republish the store so the docked pane re-bodies")
    }

    func test_setDockSize_sameValue_isNoOpRepublish() async {
        let model = makeModel()
        model.panelLayout.setDockSize(360, for: .git, on: .right)
        await Task.yield()
        var count = 0
        let sub = model.panelLayout.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        model.panelLayout.setDockSize(360, for: .git, on: .right)  // identical
        await Task.yield()
        XCTAssertEqual(count, 0,
            "Re-setting the same dock size must be a no-op (equality-guarded)")
    }
}
