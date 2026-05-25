import XCTest
import Combine
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Quality #E + J invariant pin (2026-05-25).
///
/// Find state moved to `FindCoordinator` so views that observe
/// `DocumentModel` (TabBar, Sidebar, StatusBar, ModeBar) stop
/// re-rendering on every find-bar keystroke. This test pins the
/// invariant: any mutation through `FindCoordinator` (or via the
/// backwards-compat `DocumentModel.renderedFindQuery` forwarders)
/// must NOT fire `DocumentModel.objectWillChange`.
@MainActor
final class FindRepublishInvariantTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FindRepublishInvariantTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "FindRepublishInvariantTests-\(UUID().uuidString)"
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

    private func countDocumentRepublishes(
        of model: DocumentModel,
        whileRunning mutate: () -> Void
    ) async -> Int {
        var count = 0
        let sub = model.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        mutate()
        await Task.yield()
        return count
    }

    // MARK: Rendered

    func test_renderedFindQuery_change_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.find.renderedQuery = "needle"
        }
        XCTAssertEqual(
            count, 0,
            "Find query keystrokes must not republish DocumentModel; views observe model.find directly"
        )
    }

    func test_renderedFindQuery_throughForwarder_doesNotRepublishDocumentModel() async {
        // Backwards-compat: tests / scripts still poke `model.renderedFindQuery`.
        // The forwarder must route through `find` without firing model.objectWillChange.
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.renderedFindQuery = "needle"
        }
        XCTAssertEqual(count, 0)
    }

    func test_renderedFindBar_showDismiss_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.showRenderedFindBar()
            model.dismissRenderedFindBar()
        }
        XCTAssertEqual(count, 0)
    }

    func test_renderedFindNext_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.renderedFindNext()
            model.renderedFindNext()
            model.renderedFindPrev()
        }
        XCTAssertEqual(count, 0)
    }

    // MARK: Source

    func test_sourceFindQuery_change_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.find.sourceQuery = "needle"
        }
        XCTAssertEqual(count, 0)
    }

    func test_sourceFindMatchSet_apply_doesNotRepublishDocumentModel() async {
        // FindMatchSet apply runs on every TextDisplayView coordinator
        // tick. If THIS forwarded into model.objectWillChange, every
        // scroll/click in source mode would re-render TabBar etc.
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.setSourceFindMatches(lines: [1, 5, 9], currentIndex: 1)
            model.setSourceFindMatchSummary("1/3")
        }
        XCTAssertEqual(count, 0)
    }

    // MARK: Editor (CM6)

    func test_editorFindQuery_change_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.find.editorQuery = "needle"
        }
        XCTAssertEqual(count, 0)
    }

    func test_editorFindMatchSummary_set_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.setEditorFindMatchSummary("3/12")
        }
        XCTAssertEqual(count, 0)
    }

    // MARK: Sanity — negative-control matches SidebarRepublishInvariantTests pattern

    /// Confirms the counter actually fires when DocumentModel itself mutates.
    /// Guards against a silent regression where every other test passes
    /// vacuously because the helper isn't counting anything.
    func test_documentModelOwnMutation_doesRepublish() async throws {
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("a.md")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.open(url: url)
        }
        XCTAssertGreaterThan(count, 0)
    }

    /// Confirms that the find coordinator DOES republish on its own
    /// mutation — without this the perf tests above are vacuously true
    /// (a "publisher disabled" regression would hide).
    func test_findCoordinator_doesRepublishOnFindChange() async {
        let model = makeModel()
        var count = 0
        let sub = model.find.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        model.find.renderedQuery = "x"
        await Task.yield()
        XCTAssertGreaterThan(count, 0,
            "FindCoordinator.objectWillChange must fire on query change")
    }
}
