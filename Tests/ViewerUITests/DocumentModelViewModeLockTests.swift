import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-1152 — the per-filename "Lock View As" affordance's MODEL action. The
/// FileRowContextMenu Lock/Unlock buttons call these DocumentModel methods
/// (lockViewMode / unlockViewMode / viewModeIsLocked). The ViewModeLockStore
/// itself is host-tested in ViewModeLockStoreTests; this pins the DocumentModel
/// wiring the menu is bound to (lock → isLocked + recorded mode; unlock →
/// cleared; re-lock overwrites). The menu's on-screen appearance is the
/// standard-SwiftUI tail; the action is what this proves.
@MainActor
final class DocumentModelViewModeLockTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMLock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "VMLock-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await super.tearDown()
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            bookmarks: BookmarksStore(storeURL: tmpDir.appendingPathComponent("bookmarks.json")),
            viewModeLocks: ViewModeLockStore(
                storeURL: tmpDir.appendingPathComponent("view-mode-locks.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    func test_lockViewMode_thenIsLocked_recordsTheMode() {
        let m = makeModel()
        let url = tmpDir.appendingPathComponent("notes.txt")
        XCTAssertFalse(m.viewModeIsLocked(url))
        m.lockViewMode(url, to: .source)
        XCTAssertTrue(m.viewModeIsLocked(url))
        XCTAssertEqual(m.viewModeLocks.lockedMode(for: url), .source)
    }

    func test_unlockViewMode_clearsTheLock() {
        let m = makeModel()
        let url = tmpDir.appendingPathComponent("readme.md")
        m.lockViewMode(url, to: .rendered)
        XCTAssertTrue(m.viewModeIsLocked(url))
        m.unlockViewMode(url)
        XCTAssertFalse(m.viewModeIsLocked(url))
        XCTAssertNil(m.viewModeLocks.lockedMode(for: url))
    }

    func test_lockViewMode_overwritesPriorLock() {
        let m = makeModel()
        let url = tmpDir.appendingPathComponent("notes.txt")
        m.lockViewMode(url, to: .source)
        m.lockViewMode(url, to: .rendered)
        XCTAssertEqual(m.viewModeLocks.lockedMode(for: url), .rendered)
    }
}
