import XCTest
import Combine
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// PERF #1 invariant pin (2026-05-25).
///
/// Sidebar mutations must NOT fan out through `DocumentModel.
/// objectWillChange` anymore. The prior `objectWillChange` forwarder
/// in `DocumentModel.init` republished the whole document on every
/// sidebar tick (hover-driven `selectedURL`, FolderWatcher debounces,
/// 60s git poll, expand/collapse, sort-mode toggles). That cascade was
/// the dominant render cost for sidebar-driven lag — see
/// `docs/code-review/PERFORMANCE_2026-05-25.md` finding #1.
///
/// These tests assert the negative invariant: nothing the sidebar
/// changes should make `DocumentModel.objectWillChange` fire. Views
/// that *do* need sidebar state observe `sidebar` directly via
/// `@ObservedObject var sidebar: SidebarModel`.
@MainActor
final class SidebarRepublishInvariantTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidebarRepublishInvariantTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "SidebarRepublishInvariantTests-\(UUID().uuidString)"
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

    /// Helper: spin up a sink on `model.objectWillChange`, run `mutate`,
    /// allow Combine to drain, then return the number of times the
    /// publisher fired during `mutate`.
    private func countDocumentRepublishes(
        of model: DocumentModel,
        whileRunning mutate: () -> Void
    ) async -> Int {
        var count = 0
        let sub = model.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        mutate()
        // Drain the runloop so Combine has a chance to fire any
        // queued publishers before we count.
        await Task.yield()
        return count
    }

    // MARK: Visibility toggle

    func test_sidebar_isVisible_toggle_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        // Seed: ensure visibility starts at a known value so the toggle
        // is a real change.
        model.sidebar.isVisible = false
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.sidebar.isVisible = true
        }
        XCTAssertEqual(
            count, 0,
            "Sidebar isVisible must not republish DocumentModel; views observe sidebar directly"
        )
    }

    // MARK: Root URL change

    func test_sidebar_setRoot_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        let folder = tmpDir.appendingPathComponent("subfolder")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.sidebar.setRoot(folder)
        }
        XCTAssertEqual(
            count, 0,
            "Sidebar root change must not republish DocumentModel; views observe sidebar.rootURL directly"
        )
    }

    // MARK: Expansion churn (the worst offender in the prior design)

    func test_sidebar_expandedAssignment_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        let folder = tmpDir.appendingPathComponent("expand")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.sidebar.setRoot(folder)
        await Task.yield()
        // The FolderWatcher repath ends in `expanded = snapshot` (see
        // SidebarModel.onFolderChange). Force the same shape here.
        let count = await countDocumentRepublishes(of: model) {
            // Toggle expansion of an arbitrary URL — exercises the
            // @Published `expanded` publisher.
            model.sidebar.toggleExpansion(folder.appendingPathComponent("child"))
        }
        XCTAssertEqual(
            count, 0,
            "Sidebar expansion changes must not republish DocumentModel"
        )
    }

    // MARK: Sort mode / hidden toggle

    func test_sidebar_sortModeToggle_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.sidebar.sortMode = .modifiedDescending
        }
        XCTAssertEqual(
            count, 0,
            "Sidebar sortMode toggle must not republish DocumentModel"
        )
    }

    func test_sidebar_includeHiddenToggle_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.sidebar.includeHidden = true
        }
        XCTAssertEqual(
            count, 0,
            "Sidebar includeHidden toggle must not republish DocumentModel"
        )
    }

    // MARK: Selection moves (the hover-dwell hot path)

    func test_sidebar_selectURL_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        let folder = tmpDir.appendingPathComponent("sel")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.sidebar.setRoot(folder)
        await Task.yield()
        let target = folder.appendingPathComponent("a.md")
        let count = await countDocumentRepublishes(of: model) {
            model.sidebar.setSelected(target)
        }
        XCTAssertEqual(
            count, 0,
            "Sidebar selection moves must not republish DocumentModel"
        )
    }

    // MARK: Sanity — DocumentModel still republishes on its own mutations

    /// Negative-control: confirm the helper actually counts when
    /// DocumentModel itself changes. Guards against a silent
    /// "publisher disabled" regression where every test passes trivially.
    func test_documentModelOwnMutation_doesRepublish() async throws {
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("a.md")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.open(url: url)
        }
        XCTAssertGreaterThan(
            count, 0,
            "DocumentModel.open must still republish — otherwise every other test in this file is vacuously true"
        )
    }
}
