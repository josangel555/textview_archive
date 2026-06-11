import XCTest
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// TSK-372 — "close with just one tab, reopen and see two."
///
/// The owner-reported repro, driven through the REAL quit/relaunch
/// machinery at the model layer: `flushForTermination()` (the
/// `applicationWillTerminate` write) followed by a brand-new
/// `DocumentModel` + `SessionsAppCoordinator` over the SAME store
/// directory running `bootstrap()` (the launch restore). The tab COUNT
/// after relaunch must equal the count at quit — never more.
///
/// The dangerous histories pinned here:
///   - quit with a single never-changed tab (the literal report),
///   - a 2-tab disk snapshot that must be SUPERSEDED when the user
///     closes one tab and quits (a stale-write resurrection would show
///     2 tabs again — the report's most plausible mechanism),
///   - a pending (unfired) autosave debounce at quit — the final
///     termination write must win over the half-window timer's value.
///
/// Pure-logic, per-test store dirs, no NSWindow. Safe on host.
@MainActor
final class TabRestoreAfterQuitTests: XCTestCase {

    private lazy var tmpRoot: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabRestoreAfterQuit-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }()

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    private func makeWorkspace(files: [String]) -> (URL, [URL]) {
        let folder = tmpRoot.appendingPathComponent(
            "ws-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        var urls: [URL] = []
        for name in files {
            let url = folder.appendingPathComponent(name)
            try? Data("// \(name)\n".utf8).write(to: url)
            urls.append(url)
        }
        return (folder, urls)
    }

    private func makeSessionsDir() -> URL {
        let dir = tmpRoot.appendingPathComponent(
            "stores-\(UUID().uuidString)/Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// One "app process": a fresh model + coordinator over `sessionsDir`.
    /// `autosaveDebounce` defaults far in the future so a pending debounce
    /// can never fire mid-test — quit-time behavior must not depend on it.
    private func launch(sessionsDir: URL,
                        autosaveDebounce: TimeInterval = 999)
        -> SessionsAppCoordinator {
        let coord = SessionsAppCoordinator(
            model: DocumentModel(),
            store: SessionStore(directory: sessionsDir),
            initialRoot: nil,
            autosaveDebounce: autosaveDebounce)
        coord.bootstrap()
        return coord
    }

    // MARK: - The literal report

    func test_quitWithOneTab_relaunchRestoresExactlyOne() {
        let sessionsDir = makeSessionsDir()
        let (folder, files) = makeWorkspace(files: ["only.md"])

        let run1 = launch(sessionsDir: sessionsDir)
        run1.openFolder(folder, forceNew: true)
        run1.model.open(url: files[0])
        XCTAssertEqual(run1.model.tabs.tabs.count, 1)
        run1.flushForTermination()

        let run2 = launch(sessionsDir: sessionsDir)
        XCTAssertEqual(run2.model.tabs.tabs.count, 1,
            "closed with ONE tab — relaunch must show exactly one (TSK-372)")
        XCTAssertEqual(run2.model.tabs.tabs.first?.url?.lastPathComponent,
                       "only.md")
    }

    // MARK: - Stale 2-tab snapshot must be superseded

    func test_closeSecondTab_thenQuit_staleTwoTabSnapshotDoesNotResurrect() {
        let sessionsDir = makeSessionsDir()
        let (folder, files) = makeWorkspace(files: ["keep.md", "closed.md"])

        let run1 = launch(sessionsDir: sessionsDir)
        run1.openFolder(folder, forceNew: true)
        run1.model.open(url: files[0])
        run1.model.open(url: files[1])
        XCTAssertEqual(run1.model.tabs.tabs.count, 2)
        // Put a 2-tab snapshot ON DISK (a mid-session flush) — the stale
        // state a later quit write must beat.
        run1.flushForTermination()

        // User closes the second tab → exactly one remains → quits.
        if let idx = run1.model.tabs.tabs.firstIndex(where: {
            $0.url?.lastPathComponent == "closed.md" }) {
            run1.model.closeTab(at: idx)
        }
        XCTAssertEqual(run1.model.tabs.tabs.count, 1)
        run1.flushForTermination()

        let run2 = launch(sessionsDir: sessionsDir)
        XCTAssertEqual(run2.model.tabs.tabs.count, 1,
            "the earlier 2-tab disk snapshot resurrected — quit must "
            + "persist the close-time tab list (TSK-372)")
        XCTAssertEqual(run2.model.tabs.tabs.first?.url?.lastPathComponent,
                       "keep.md")
    }

    // MARK: - Pending debounce at quit must not win

    func test_pendingAutosaveAtQuit_doesNotOverrideFinalWrite() {
        let sessionsDir = makeSessionsDir()
        let (folder, files) = makeWorkspace(files: ["a.md", "b.md"])

        let run1 = launch(sessionsDir: sessionsDir)
        run1.openFolder(folder, forceNew: true)
        run1.model.open(url: files[0])
        run1.model.open(url: files[1])
        // Tab mutations above armed a debounce that (deliberately) never
        // fires. Close one tab — another pending tick — then quit
        // immediately: flushForTermination must cancel the timer and write
        // the LIVE 1-tab state.
        if let idx = run1.model.tabs.tabs.firstIndex(where: {
            $0.url?.lastPathComponent == "b.md" }) {
            run1.model.closeTab(at: idx)
        }
        XCTAssertEqual(run1.model.tabs.tabs.count, 1)
        run1.flushForTermination()

        let run2 = launch(sessionsDir: sessionsDir)
        XCTAssertEqual(run2.model.tabs.tabs.count, 1,
            "quit raced a pending autosave — the termination write must be "
            + "authoritative (TSK-372)")
        XCTAssertEqual(run2.model.tabs.tabs.first?.url?.lastPathComponent,
                       "a.md")
    }
}
