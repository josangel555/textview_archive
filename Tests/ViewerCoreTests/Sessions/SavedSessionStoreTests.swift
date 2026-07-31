import XCTest
@testable import ViewerCore

/// Named session save points (2026-07-31, owner ask "Save and retrieve
/// session"). Store layer: `saved/<uuid>.json` under the Sessions dir —
/// immutable copies, isolated from the LIVE snapshot machinery so the
/// TSK-438 recovery self-heal can never adopt a save point as a session.
final class SavedSessionStoreTests: XCTestCase {

    private var tmp: URL!
    private var store: SessionStore!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SavedSessionStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = SessionStore(directory: tmp)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func snap(_ name: String, savedAt: Date = Date()) -> SessionSnapshot {
        SessionSnapshot(
            id: UUID(), displayName: name,
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: "/p", openTabs: [], selectedTabIndex: nil
        ).with(savedAt: savedAt)
    }

    func test_saveNamed_roundTrips() {
        let point = snap("release checkpoint")
        XCTAssertTrue(store.saveNamed(point))
        let back = store.loadSaved(id: point.id)
        XCTAssertEqual(back?.displayName, "release checkpoint")
        XCTAssertEqual(back?.id, point.id)
    }

    func test_savedSnapshots_listNewestFirst() {
        let old = snap("old", savedAt: Date(timeIntervalSince1970: 1_000))
        let new = snap("new", savedAt: Date(timeIntervalSince1970: 2_000))
        store.saveNamed(old)
        store.saveNamed(new)
        XCTAssertEqual(store.savedSnapshots().map(\.displayName), ["new", "old"])
    }

    func test_deleteSaved_removesExactlyThatPoint() {
        let a = snap("a"), b = snap("b")
        store.saveNamed(a)
        store.saveNamed(b)
        store.deleteSaved(id: a.id)
        XCTAssertEqual(store.savedSnapshots().map(\.id), [b.id])
        XCTAssertNil(store.loadSaved(id: a.id))
    }

    func test_corruptSaveFile_isSkippedNeverFatal() throws {
        store.saveNamed(snap("good"))
        let savedDir = tmp.appendingPathComponent("saved")
        try Data("{not json".utf8).write(
            to: savedDir.appendingPathComponent("\(UUID().uuidString).json"))
        XCTAssertEqual(store.savedSnapshots().map(\.displayName), ["good"],
                       "a corrupt save point must not take the list down")
    }

    /// THE isolation pin: save points live in a subdirectory precisely so
    /// the live-snapshot scan and the TSK-438 recovery self-heal cannot
    /// see them. If someone flattens the layout, sessions "recovered"
    /// from save points would resurrect on every index loss.
    func test_savePoints_areInvisibleToLiveScanAndRecovery() throws {
        let root = tmp.appendingPathComponent("realroot")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let point = SessionSnapshot(
            id: UUID(), displayName: "saved with tabs",
            createdAt: Date(), lastActiveAt: Date(),
            sidebarRootPath: root.path,
            openTabs: [TabSnapshot(path: root.appendingPathComponent("f.md").path,
                                   viewMode: "source")],
            selectedTabIndex: 0
        )
        store.saveNamed(point)
        XCTAssertTrue(store.liveSnapshotIDs().isEmpty,
                      "save points must never count as live sessions")
        XCTAssertTrue(store.recoverableSnapshots().isEmpty,
                      "recovery self-heal must never adopt a save point")
    }
}
