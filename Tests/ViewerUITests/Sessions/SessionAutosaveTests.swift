import XCTest
import Combine
@testable import ViewerCore
@testable import ViewerUI

/// Coverage for the debounced incremental autosave (item7 / §5.4 crash
/// recovery). Asserts BOTH halves of the contract:
///   1. a real persisted-state change schedules a write (the debounce fires),
///   2. a no-op / equal-value re-publish does NOT spam the write queue
///      (the equality guard).
///
/// Host-safe: constructs the coordinator + a temp-dir `SessionStore`
/// directly (no NSApplication). Uses `autosaveDebounce: 0` + the
/// `flushAutosaveNow()` test hook so we never sleep on wall-clock time, and
/// `core.flushPersistenceSync()` to drain the coalescing write queue before
/// reading the on-disk snapshot. Run with a class filter.
@MainActor
final class SessionAutosaveTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionAutosave-\(UUID().uuidString)")
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

    private func makeFile(_ dir: URL, _ name: String, _ body: String = "x") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Build a coordinator with an instant debounce and bootstrap a session
    /// rooted at `folder`.
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
        coord.flushForTermination()   // baseline: get the empty session on disk
        return (coord, store)
    }

    private func persisted(_ store: SessionStore, _ id: UUID) -> SessionSnapshot? {
        store.flushSync()
        return store.load(id: id)
    }

    // A real change (opening a file → new tab) must reach disk through the
    // debounced autosave, without a clean quit.
    func test_autosave_persistsTabOpenWithoutQuit() throws {
        let folder = try makeFolder("Proj")
        let file = try makeFile(folder, "doc.md", "# hi")
        let (coord, store) = makeBootedCoordinator(root: folder)
        let id = coord.active!.id

        let before = persisted(store, id)
        XCTAssertEqual(before?.openTabs.count, 0, "baseline session has no tabs")

        // Mutate live state — this is the kind of change a crash would
        // otherwise lose. The `tabCoordinator.$tabs` publisher fires.
        coord.model.open(url: file)
        coord.flushAutosaveNow()
        store.flushSync()

        let after = store.load(id: id)
        XCTAssertEqual(after?.openTabs.map(\.path).map { ($0 as NSString).lastPathComponent },
                       ["doc.md"],
                       "autosave must persist the newly-opened tab without a clean quit")
    }

    // A no-op re-publish (equal value) must NOT write — the equality guard
    // collapses it so a publish storm doesn't spam the disk.
    func test_autosave_equalValueChange_doesNotWrite() throws {
        let folder = try makeFolder("Proj2")
        let file = try makeFile(folder, "a.md", "# a")
        let (coord, store) = makeBootedCoordinator(root: folder)
        let id = coord.active!.id

        // Make one real change + persist it so there's a stable baseline.
        coord.model.open(url: file)
        coord.flushAutosaveNow()
        let baseline = persisted(store, id)
        XCTAssertEqual(baseline?.openTabs.count, 1)
        let baselineSavedAt = baseline!.savedAt

        // Re-publish equal values: assigning a @Published its own value still
        // fires the publisher, but the snapshot is unchanged.
        coord.model.zoom = coord.model.zoom
        coord.model.sourceWordWrap = coord.model.sourceWordWrap
        coord.flushAutosaveNow()
        store.flushSync()

        let after = store.load(id: id)
        XCTAssertEqual(after?.savedAt, baselineSavedAt,
            "an equal-value re-publish must NOT produce a new write (equality guard)")
    }

    // A second real change after a no-op still writes (guard doesn't get
    // stuck).
    func test_autosave_realChangeAfterNoOp_writes() throws {
        let folder = try makeFolder("Proj3")
        let f1 = try makeFile(folder, "one.md", "1")
        let f2 = try makeFile(folder, "two.md", "2")
        let (coord, store) = makeBootedCoordinator(root: folder)
        let id = coord.active!.id

        coord.model.open(url: f1)
        coord.flushAutosaveNow()
        _ = persisted(store, id)

        // no-op
        coord.model.zoom = coord.model.zoom
        coord.flushAutosaveNow()

        // real change
        coord.model.open(url: f2)
        coord.flushAutosaveNow()
        store.flushSync()

        let after = store.load(id: id)
        XCTAssertEqual(after?.openTabs.count, 2,
            "a real change after a no-op must still persist")
    }
}

// MARK: - TSK-607: periodic safety-net flush (scroll-only drift)

extension SessionAutosaveTests {

    /// Scroll position deliberately never ticks the autosave publishers
    /// (REPUB-1), so before TSK-607 a "scroll, then crash" lost it. The
    /// periodic tick must capture and persist it with NO publisher tick
    /// and NO quit.
    func test_periodicFlush_persistsScrollOnlyDrift() throws {
        let folder = try makeFolder("ProjScroll")
        let file = try makeFile(folder, "long.md",
                                Array(repeating: "line", count: 300).joined(separator: "\n"))
        let storeDir = tmp.appendingPathComponent("store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let store = SessionStore(directory: storeDir)
        let coord = SessionsAppCoordinator(model: DocumentModel(),
                                           store: store,
                                           initialRoot: nil,
                                           autosaveDebounce: 0,
                                           periodicFlushInterval: 0)  // tick driven by hand
        coord.bootstrap()
        coord.openFolder(folder, forceNew: false)
        coord.model.open(url: file)
        coord.flushAutosaveNow()
        coord.flushForTermination()   // baseline on disk, scroll at top
        let id = coord.active!.id

        // Scroll-only mutation: rides SourceViewChannel, ticks nothing.
        coord.model.sourceView.sourceScrollState = SourceScrollState(
            offsetY: 1280, viewportHeight: 600, lineHeight: 16,
            lineCount: 300, topInset: 10)

        coord.periodicFlushTick()
        store.flushSync()

        let snap = store.load(id: id)
        let line = snap?.openTabs.first?.scrollTopLine ?? 0
        XCTAssertGreaterThan(line, 0,
            "the periodic flush must capture + persist scroll-only drift "
            + "(no publisher tick, no quit) — got scrollTopLine=\(line)")
    }

    /// An idle tick (nothing changed since the last write) must not write —
    /// the periodic timer reuses the same equality guard as the debounce.
    func test_periodicFlush_idleTick_doesNotWrite() throws {
        let folder = try makeFolder("ProjIdle")
        let file = try makeFile(folder, "a.md", "# a")
        let (coord, store) = makeBootedCoordinator(root: folder)
        let id = coord.active!.id

        coord.model.open(url: file)
        coord.flushAutosaveNow()
        store.flushSync()
        let savedAtAfterChange = store.load(id: id)?.savedAt

        coord.periodicFlushTick()
        store.flushSync()
        XCTAssertEqual(store.load(id: id)?.savedAt, savedAtAfterChange,
                       "an idle periodic tick must be equality-guarded to a no-op write")
    }
}
