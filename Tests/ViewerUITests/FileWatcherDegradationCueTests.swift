import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-185 — FileWatcher construction failure must SURFACE, not silently
/// disable external-edit detection. The audited bug: a throwing
/// `FileWatcher` init left `fileWatcher` nil with no fallback and no
/// signal — live reload (and the save-time conflict reconcile it feeds)
/// was invisibly off for the file's whole session. The fix publishes
/// `liveReloadUnavailable` (+ an Obs emit) from the construction catch.
///
/// Driven through the REAL open path via the
/// `FileWatcher.forceConstructionFailure` seam — descriptor exhaustion /
/// kqueue pressure (the production failure modes) can't be staged in a
/// test.
@MainActor
final class FileWatcherDegradationCueTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FWDegradationCue-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "FWDegradationCue-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        FileWatcher.forceConstructionFailure = false
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

    private func writeFile(_ name: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try "content\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_watcherConstructionFailure_surfacesCue_andRecovers() throws {
        let model = makeModel()

        FileWatcher.forceConstructionFailure = true
        model.open(url: try writeFile("a.md"))
        XCTAssertTrue(model.liveReloadUnavailable,
            "a failed watcher construction must publish the degradation cue "
            + "— a silent nil watcher is the audited bug (TSK-185)")

        // Recovery: the next successful watch clears the cue (the fix's
        // other half — no stale 'unavailable' badge after a good attach).
        FileWatcher.forceConstructionFailure = false
        model.open(url: try writeFile("b.md"))
        XCTAssertFalse(model.liveReloadUnavailable,
                       "a successful (re)watch must clear the cue")
    }

    func test_deliberatePause_isNotAFailure() throws {
        let model = makeModel()
        FileWatcher.forceConstructionFailure = true
        model.open(url: try writeFile("c.md"))
        XCTAssertTrue(model.liveReloadUnavailable)

        // Session detach pauses watching on purpose — that must not leave
        // a stale failure cue showing while the session is backgrounded.
        model.pauseFileWatcher()
        XCTAssertFalse(model.liveReloadUnavailable,
                       "a deliberate pause is not a failure")
    }
}
