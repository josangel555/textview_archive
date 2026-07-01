import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-1303 — host-safe behavioural coverage for the image-edit-state capture /
/// restore MODEL layer behind "image edits survive a session switch". The on-disk
/// wire (`TabSnapshot.imageEditState`) is pinned in
/// `ViewerCoreTests.TabSnapshotImageEditStatePersistenceTests`; this file pins the
/// live-model pieces that move data in and out of it (mirrors `HotExitTests` for
/// the sibling unsaved-text machinery):
///
///   1. `dedupedSnapshotTabs` serializes a tab's `imageEditState` (the WRITE side
///      `makeSnapshot` runs).
///   2. `captureImageEditStateForAllTabs` folds the live `imageEditStateByURL`
///      onto each tab — the session-switch-drain-boundary capture.
///   3. `restoreImageEditState` seeds the live dict back from a materialized tab.
///   4. `imageEditState(for:)` prefers the live value, falls back to the tab (the
///      seed-race-free resolution the recreated editor VM reads at construction).
///
/// The view↔model binding (the image editor writing/reading the dict) is the VM
/// render tail. Filter: `swift test --filter ViewerUITests.ImageEditStatePersistenceTests`
@MainActor
final class ImageEditStatePersistenceTests: XCTestCase {
    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageEditStateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "ImageEditStateTests-\(UUID().uuidString)"
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
            preferences: PreferencesStore(defaults: defaults))
    }
    private func sampleState(_ brightness: Double = 0.5) -> ImageEditState {
        ImageEditState(brightness: brightness, contrast: 1.2, saturation: 0.8)
    }
    /// Append an image tab for `url`; return its index (robust to any initial blank tab).
    private func appendImageTab(_ url: URL, in model: DocumentModel,
                                imageEditState: ImageEditState? = nil) -> Int {
        var t = Tab(url: url, state: .empty, viewMode: .source)
        t.imageEditState = imageEditState
        model.tabCoordinator.append(t)
        return model.tabs.tabs.firstIndex(where: { $0.url == url })!
    }

    // MARK: - 1. dedupedSnapshotTabs carries imageEditState (write side)

    func test_dedupedSnapshotTabs_serializesImageEditState() {
        var edited = Tab(url: URL(fileURLWithPath: "/a/pic.png"), state: .empty, viewMode: .source)
        edited.imageEditState = sampleState()
        let clean = Tab(url: URL(fileURLWithPath: "/a/plain.md"), state: .empty, viewMode: .rendered)
        let (out, _) = SessionState.dedupedSnapshotTabs(from: [edited, clean], selectedIndex: nil)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].imageEditState, sampleState())
        XCTAssertNil(out[1].imageEditState, "an unedited tab persists no image edit state")
    }

    // MARK: - 2. captureImageEditStateForAllTabs (snapshot-boundary fold)

    func test_capture_foldsLiveEditState_ontoTab() {
        let url = URL(fileURLWithPath: "/a/pic.png")
        let model = makeModel()
        let idx = appendImageTab(url, in: model)
        model.rememberImageEditState(sampleState(), for: url)
        XCTAssertNil(model.tabs.tabs[idx].imageEditState, "not yet folded onto the tab")

        model.captureImageEditStateForAllTabs()
        XCTAssertEqual(model.tabs.tabs[idx].imageEditState, sampleState(),
                       "the live edit state is folded onto the tab at the boundary")
    }

    func test_capture_noLiveState_leavesTabNil() {
        let url = URL(fileURLWithPath: "/a/pic.png")
        let model = makeModel()
        let idx = appendImageTab(url, in: model)
        model.captureImageEditStateForAllTabs()
        XCTAssertNil(model.tabs.tabs[idx].imageEditState,
                     "no live edit state → nothing stamped (unedited image tab)")
    }

    // MARK: - 3. restoreImageEditState (materialize-time seed)

    func test_restore_seedsLiveDict_fromTab() {
        let url = URL(fileURLWithPath: "/a/pic.png")
        let model = makeModel()
        let idx = appendImageTab(url, in: model, imageEditState: sampleState())
        model.restoreImageEditState(forTabAt: idx)
        XCTAssertEqual(model.imageEditState(for: url), sampleState(),
                       "the persisted tab state is seeded back into the live dict")
    }

    // MARK: - 4. imageEditState(for:) prefers live, falls back to the tab

    func test_imageEditStateFor_prefersLive_thenFallsBackToTab() {
        let url = URL(fileURLWithPath: "/a/pic.png")
        let model = makeModel()
        _ = appendImageTab(url, in: model, imageEditState: sampleState(0.1))  // persisted (older)
        // No live entry yet → falls back to the tab's persisted value.
        XCTAssertEqual(model.imageEditState(for: url)?.brightness, 0.1)
        // A live edit takes precedence over the persisted fallback.
        model.rememberImageEditState(sampleState(0.9), for: url)
        XCTAssertEqual(model.imageEditState(for: url)?.brightness, 0.9)
    }

    func test_imageEditStateFor_nilURL_isNil() {
        XCTAssertNil(makeModel().imageEditState(for: nil))
    }

    // MARK: - 4b. the coordinator sequence: capture → snapshot-serialize

    /// The exact pre-`makeSnapshot` sequence `SessionsAppCoordinator` runs on
    /// detach / autosave / quit: `captureImageEditStateForAllTabs()` then the
    /// snapshot serialize (`dedupedSnapshotTabs`, which `makeSnapshot` uses). This
    /// is what the slice-1 capture-placement bug broke: capture MUST run before the
    /// serialize, else the snapshot carries no edit state (the edits are lost on a
    /// cold session restore / relaunch).
    func test_capture_thenSnapshotSerialize_carriesEditState() {
        let url = URL(fileURLWithPath: "/a/pic.png")
        let model = makeModel()
        _ = appendImageTab(url, in: model)
        model.rememberImageEditState(sampleState(), for: url)
        model.captureImageEditStateForAllTabs()                       // coordinator step 1
        let (snaps, _) = SessionState.dedupedSnapshotTabs(            // makeSnapshot's serialize core
            from: model.tabs.tabs, selectedIndex: nil)
        let snap = snaps.first(where: { $0.path == url.path })
        XCTAssertEqual(snap?.imageEditState, sampleState(),
                       "capture-before-serialize carries the edit state into the snapshot")
    }

    // MARK: - 5. round-trip: capture → (fresh session tab carries it) → restore

    func test_roundTrip_captureThenRestore_preservesEdit() {
        let url = URL(fileURLWithPath: "/a/pic.png")
        let model = makeModel()
        let idx = appendImageTab(url, in: model)
        model.rememberImageEditState(sampleState(0.7), for: url)
        model.captureImageEditStateForAllTabs()
        let captured = model.tabs.tabs[idx].imageEditState
        XCTAssertEqual(captured?.brightness, 0.7)

        // Fresh model (the switched-to session drained the live dict) + a
        // materialized tab carrying the persisted state (what
        // `appendLazyTab(imageEditState:)` sets on session restore).
        let model2 = makeModel()
        let idx2 = appendImageTab(url, in: model2, imageEditState: captured)
        model2.restoreImageEditState(forTabAt: idx2)
        XCTAssertEqual(model2.imageEditState(for: url)?.brightness, 0.7,
                       "the edit survives the capture → persist → restore round-trip")
    }
}
