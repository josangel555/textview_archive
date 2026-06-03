import XCTest
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// T1m guard for the documented sessions TCC contract
/// (`docs/uat/smokes/sessions.md` §"Test scratch" + cross-cutting
/// "TCC-safe"): the coordinator deliberately refuses to re-root or persist
/// TCC-protected roots (`~/Documents`, `~/Desktop`, `~/Downloads`,
/// `~/Pictures`, iCloud Drive). `openFolder` against such a root must
/// silently no-op — no session pill is created and nothing reaches disk.
///
/// Regression: SESS-01 — the only `isUnderTCCProtectedRoot` guard used to
/// live in `bootstrap()`'s initialRoot seed, so the create-or-reveal
/// `openFolder` path (scripts / sidebar context menu / Go-to-path) created
/// AND persisted a `Documents` session.
///
/// Pure-logic; no NSApplication / NSWindow. Safe on host.
/// Filter: `swift test --filter ViewerUITests.SessionTCCGuard`
@MainActor
final class SessionTCCGuardTests: XCTestCase {

    private lazy var tmpRoot: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionTCCGuardTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }()

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    private func makeCoordinator() -> (SessionsAppCoordinator, SessionStore) {
        let storesDir = tmpRoot.appendingPathComponent("stores-\(UUID().uuidString)")
        let sessionsDir = storesDir.appendingPathComponent("Sessions")
        try? FileManager.default.createDirectory(
            at: sessionsDir, withIntermediateDirectories: true)
        let store = SessionStore(directory: sessionsDir)
        let coord = SessionsAppCoordinator(
            model: DocumentModel(), store: store, initialRoot: nil)
        coord.bootstrap()
        return (coord, store)
    }

    /// Each TCC-protected root is refused: no pill in the live list, no
    /// index/snapshot on disk. Covers the create path and the `forceNew`
    /// path (both must short-circuit before `core.openFolder`).
    func test_openFolder_underTCCProtectedRoot_silentlyNoOps() {
        let home = NSHomeDirectory()
        let protectedRoots = [
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/Downloads",
            "\(home)/Pictures",
            "\(home)/Library/Mobile Documents",
            // Nested under a protected root is equally refused.
            "\(home)/Documents/some/project",
        ]

        for path in protectedRoots {
            let (coord, store) = makeCoordinator()
            let url = URL(fileURLWithPath: path)

            coord.openFolder(url)
            coord.openFolder(url, forceNew: true)

            XCTAssertTrue(coord.core.sessions.isEmpty,
                "openFolder(\(path)) must not create a session pill")
            XCTAssertNil(coord.active,
                "no SessionState should mount for a TCC-protected root")

            // Drain the coalescing write queue, then assert nothing landed.
            coord.core.flushPersistenceSync()
            store.flushSync()
            XCTAssertNil(store.loadIndex(),
                "nothing should be persisted to index.json for \(path)")
        }
    }

    /// Control: a non-protected temp folder still opens + persists, so the
    /// guard isn't over-broad.
    func test_openFolder_underTempRoot_stillOpensAndPersists() {
        let (coord, store) = makeCoordinator()
        let folder = tmpRoot.appendingPathComponent("ProjectA", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)

        coord.openFolder(folder)

        XCTAssertEqual(coord.core.sessions.count, 1,
            "a non-TCC folder should create exactly one session")
        coord.core.flushPersistenceSync()
        store.flushSync()
        XCTAssertNotNil(store.loadIndex(),
            "a non-TCC session should be persisted")
    }
}
