import XCTest
import Combine
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Quality #1 invariant pin (2026-05-25).
///
/// Per-tab state (CSV filter, HEX width, language override,
/// formatted-flag set, formatted-text cache, editor buffers) moved
/// to `TabCoordinator`. Views that observe `tabCoordinator` directly
/// — or via the @Published properties on it — must NOT also force
/// `DocumentModel.objectWillChange` to fire. Otherwise the prior
/// republish-storm symptom returns: an editor keystroke or a CSV
/// filter-cell edit would re-render TabBar, Sidebar, StatusBar, the
/// whole content tree, etc.
///
/// Tests follow the same pattern as `FindRepublishInvariantTests`
/// and `SidebarRepublishInvariantTests`:
///   - mutate through the coordinator (or a DocumentModel forwarder
///     that bottoms out in the coordinator);
///   - assert `DocumentModel.objectWillChange` fires ZERO times;
///   - end with a negative-control test confirming the helper still
///     counts when DocumentModel itself mutates (guards against the
///     "publisher disabled" silent regression).
///
/// Tab-list and selection mutations (open / close / select) DO
/// republish DocumentModel because they cascade into `windowTitle`,
/// recents, diff-marks refresh, etc. — those run through
/// `updateDerived()` which writes a `@Published` on DocumentModel.
/// The "republish-or-not" boundary is the same as Find's: only the
/// coordinator-internal mutations are off-limits.
@MainActor
final class TabRepublishInvariantTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TabRepublishInvariantTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "TabRepublishInvariantTests-\(UUID().uuidString)"
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

    @discardableResult
    private func writeFile(_ name: String, _ contents: String = "x") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: CSV filter state

    func test_csvFilterState_change_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let id = UUID()
        let count = await countDocumentRepublishes(of: model) {
            var s = TabCoordinator.CSVFilterState()
            s.globalQuery = "needle"
            model.setCsvFilterState(s, forTabID: id)
        }
        XCTAssertEqual(count, 0,
            "CSV filter mutations must not republish DocumentModel; views observe tabCoordinator")
    }

    // MARK: HEX width

    func test_setHexWidth_doesNotRepublishDocumentModel() async {
        let model = makeModel()
        await Task.yield()
        let id = UUID()
        let count = await countDocumentRepublishes(of: model) {
            model.setHexWidth(32, forTabID: id)
        }
        XCTAssertEqual(count, 0,
            "HEX width edits must not republish DocumentModel")
    }

    // MARK: Language override

    func test_setCurrentLanguage_doesNotRepublishDocumentModel() async throws {
        let model = makeModel()
        let url = try writeFile("a.txt", "x")
        model.open(url: url)
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.setCurrentLanguage(.json)
        }
        XCTAssertEqual(count, 0,
            "language override flip must not republish DocumentModel")
    }

    // MARK: Formatted flag

    func test_toggleFormat_doesNotRepublishDocumentModel() async throws {
        let model = makeModel()
        let url = try writeFile("a.json", "{}")
        model.open(url: url)
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.toggleFormat()
        }
        XCTAssertEqual(count, 0,
            "format toggle is per-tab state; must not republish DocumentModel")
    }

    // MARK: Editor buffer

    func test_updateEditorText_doesNotRepublishDocumentModel() async throws {
        // The editor-text channel fires on every keystroke (debounced
        // to ~200 ms by the CM6 bridge). If it republished
        // DocumentModel, every typed character would force TabBar /
        // StatusBar / etc. to re-eval their bodies.
        let model = makeModel()
        let url = try writeFile("a.txt", "x")
        model.open(url: url)
        await Task.yield()
        let id = model.tabs.selected!.id
        // Make sure the buffer exists so the update path runs.
        _ = model.editorBuffer(forTabID: id)
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.updateEditorText("y", forTabID: id)
        }
        // Note: updateEditorText flips `Tab.isDirty` via
        // tabCoordinator.replace(...). That fires
        // `tabCoordinator.objectWillChange` but NOT
        // `model.objectWillChange` — DocumentModel observers don't
        // forward coordinator ticks.
        XCTAssertEqual(count, 0,
            "editor keystrokes must not republish DocumentModel")
    }

    // MARK: Split pane (forwarder)

    func test_openInSplit_doesNotRepublishDocumentModel() async throws {
        // splitURL lives on tabCoordinator; the DocumentModel
        // computed-property forwarder must NOT bridge into
        // model.objectWillChange.
        let model = makeModel()
        let url = try writeFile("a.md", "# a\n")
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.openInSplit(url)
        }
        XCTAssertEqual(count, 0,
            "splitURL mutations must not republish DocumentModel")
    }

    // MARK: Sanity — DocumentModel still republishes on its own mutations

    /// Negative-control: confirm the counter actually fires when
    /// DocumentModel itself changes. Same shape as
    /// `FindRepublishInvariantTests.test_documentModelOwnMutation_doesRepublish`.
    /// Without this, every test above would pass vacuously if the
    /// counting helper or the publisher were silently disabled.
    func test_documentModelOwnMutation_doesRepublish() async throws {
        let model = makeModel()
        let url = try writeFile("a.md", "x")
        await Task.yield()
        let count = await countDocumentRepublishes(of: model) {
            model.open(url: url)
        }
        XCTAssertGreaterThan(count, 0,
            "DocumentModel.open must still republish — otherwise every other test in this file is vacuously true")
    }

    /// Confirms that the tab coordinator DOES republish on its own
    /// mutation — same shape as FindCoordinator's
    /// `findCoordinator_doesRepublishOnFindChange`. Without this
    /// guard, a coordinator with a silently disabled @Published would
    /// make the perf tests above vacuously true.
    func test_tabCoordinator_doesRepublishOnTabMutation() async {
        let model = makeModel()
        var count = 0
        let sub = model.tabCoordinator.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        model.tabCoordinator.append(Tab())
        await Task.yield()
        XCTAssertGreaterThan(count, 0,
            "TabCoordinator.objectWillChange must fire on tab append")
    }
}
