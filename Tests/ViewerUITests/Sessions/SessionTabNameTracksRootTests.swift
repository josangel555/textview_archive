import XCTest
import Combine
@testable import ViewerCore
@testable import ViewerUI

/// TSK-1016 — the session tab name tracks the current root folder and
/// auto-updates when the root changes, UNLESS the user manually renamed the
/// session (a manual rename wins and is never clobbered by a later root change).
///
/// These exercise the FULL coordinator path the SessionTabBar consumes: the
/// strip renders `SessionsCoordinator.sessions[i].displayName`, so we assert on
/// the value-level snapshot in `coord.core.sessions` after a root change /
/// rename — that is the data the cell actually shows. The pixel/strip redraw
/// itself is the VM tail; this pins the model that drives it.
///
/// Host-safe: builds the coordinator + a temp-dir `SessionStore` directly (no
/// NSApplication). Instant debounce + `flushAutosaveNow()` so we never sleep.
@MainActor
final class SessionTabNameTracksRootTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionTabName-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeFolder(_ name: String) throws -> URL {
        let dir = tmp.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeBootedCoordinator(root folder: URL)
        -> (SessionsAppCoordinator, SessionStore) {
        let storeDir = tmp.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let store = SessionStore(directory: storeDir)
        let coord = SessionsAppCoordinator(model: DocumentModel(),
                                           store: store,
                                           initialRoot: nil,
                                           autosaveDebounce: 0)
        coord.bootstrap()
        coord.openFolder(folder, forceNew: false)
        coord.flushForTermination()
        return (coord, store)
    }

    private func snap(_ coord: SessionsAppCoordinator, _ id: UUID) -> SessionSnapshot? {
        coord.core.sessions.first(where: { $0.id == id })
    }

    // MARK: new session derives its title from the folder ------------

    func test_newSession_titleIsFolderName() throws {
        let folder = try makeFolder("MyProject")
        let (coord, _) = makeBootedCoordinator(root: folder)
        XCTAssertEqual(coord.core.active?.displayName, "MyProject")
        XCTAssertNil(coord.core.active?.displayNameIsUserSet,
            "a fresh folder-derived session must not be flagged user-set")
    }

    // MARK: root change relabels the strip's snapshot ----------------

    func test_rootChange_relabelsTabName() throws {
        let alpha = try makeFolder("alpha")
        let beta = try makeFolder("beta")
        let (coord, _) = makeBootedCoordinator(root: alpha)
        let id = coord.active!.id
        XCTAssertEqual(snap(coord, id)?.displayName, "alpha")

        // Re-root the shared sidebar (DocumentModel.openFolder is the live
        // gesture; here we drive the same sidebar mutation). The `$rootURL`
        // publisher feeds the autosave, which re-snapshots through
        // `replaceSnapshot` → the value-level `sessions` list the strip shows.
        coord.model.openFolder(beta)
        coord.flushAutosaveNow()

        XCTAssertEqual(snap(coord, id)?.displayName, "beta",
            "the strip's snapshot must relabel to the new root folder name")
    }

    // MARK: a manual rename is never clobbered by a later root change -

    func test_manualRename_survivesLaterRootChange() throws {
        let alpha = try makeFolder("alpha")
        let beta = try makeFolder("beta")
        let (coord, _) = makeBootedCoordinator(root: alpha)
        let id = coord.active!.id

        // User renames the session.
        coord.rename(id: id, to: "My Work")
        XCTAssertEqual(snap(coord, id)?.displayName, "My Work")
        XCTAssertEqual(snap(coord, id)?.displayNameIsUserSet, true)
        XCTAssertTrue(coord.active?.displayNameIsUserSet ?? false,
            "the live SessionState mirrors the user-set flag so the next autosave won't re-derive")

        // Now the root changes — the manual name MUST stick.
        coord.model.openFolder(beta)
        coord.flushAutosaveNow()
        XCTAssertEqual(snap(coord, id)?.displayName, "My Work",
            "a manual rename wins — root change must not auto-relabel it back to the folder name")
        XCTAssertEqual(snap(coord, id)?.displayNameIsUserSet, true)
    }

    // MARK: the user-set flag survives a persistence round-trip ------

    func test_userSetFlag_survivesReload() throws {
        let alpha = try makeFolder("alpha")
        let beta = try makeFolder("beta")
        let (coord, store) = makeBootedCoordinator(root: alpha)
        let id = coord.active!.id
        coord.rename(id: id, to: "Pinned Name")
        coord.flushForTermination()

        // Reload from disk in a fresh coordinator (relaunch simulation).
        let coord2 = SessionsAppCoordinator(model: DocumentModel(),
                                            store: store,
                                            initialRoot: nil,
                                            autosaveDebounce: 0)
        coord2.bootstrap()
        XCTAssertEqual(coord2.core.active?.id, id)
        XCTAssertEqual(coord2.core.active?.displayName, "Pinned Name")
        XCTAssertEqual(coord2.core.active?.displayNameIsUserSet, true,
            "the manual-rename flag must survive a relaunch")
        XCTAssertTrue(coord2.active?.displayNameIsUserSet ?? false,
            "the restored live SessionState carries the flag (hydrate)")

        // Post-reload root change must still keep the pinned name.
        coord2.model.openFolder(beta)
        coord2.flushAutosaveNow()
        XCTAssertEqual(coord2.core.active?.displayName, "Pinned Name",
            "after relaunch a root change still must not clobber the manual name")
    }
}
