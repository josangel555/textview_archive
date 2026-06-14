import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-671 — per-type default view mode, end-to-end at the model layer. Pinning
/// a category's default (via the bottom type-menu's "Default view" section,
/// which calls `setDefaultViewMode`) must change the mode a FRESHLY-opened file
/// of that category lands in — killing the "click Editor every time" annoyance
/// where Markdown forces Rendered and CSV forces Table on every open.
///
/// Host-safe (T1m): drives `DocumentModel.open` with an injected throwaway
/// `PreferencesStore`; reads the resulting tab's `currentViewMode`. No window.
///
/// TEETH: the no-pin control pins the built-in defaults (.md→Rendered,
/// .csv→Table); each "pinned" test fails if `resolveOpenMode` ignores the pref.
@MainActor
final class DefaultViewModePerTypeTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DefaultViewMode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DefaultViewMode-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults { defaults.removePersistentDomain(forName: suiteName) }
        try await super.tearDown()
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            bookmarks: BookmarksStore(storeURL: tmpDir.appendingPathComponent("bookmarks.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    private func write(_ contents: String, named name: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: No-pin control — built-in defaults intact

    func test_noPin_markdownOpensRendered_csvOpensTable() throws {
        let md = try write("# Title\n\nbody\n", named: "doc.md")
        let csv = try write("a,b,c\n1,2,3\n", named: "data.csv")

        let m1 = makeModel(); m1.open(url: md)
        XCTAssertEqual(m1.currentViewMode, .rendered,
                       "without a pin, Markdown keeps its built-in Rendered default")

        let m2 = makeModel(); m2.open(url: csv)
        XCTAssertEqual(m2.currentViewMode, .table,
                       "without a pin, CSV keeps its built-in Table default")
    }

    // MARK: Pinned defaults change the landing mode

    func test_pinMarkdownToSource_opensSource() throws {
        let md = try write("# Title\n\nbody\n", named: "doc.md")
        let m = makeModel()
        m.setDefaultViewMode(.source, for: .markdown)
        m.open(url: md)
        XCTAssertEqual(m.currentViewMode, .source,
                       "pinning Markdown→Source must open the .md in Source, not Rendered")
    }

    func test_pinPlainTextToSource_csvOpensSource() throws {
        // CSV classifies as .plainText; pinning that category to Source must
        // beat the Table default.
        let csv = try write("a,b,c\n1,2,3\n", named: "data.csv")
        let m = makeModel()
        m.setDefaultViewMode(.source, for: .plainText)
        m.open(url: csv)
        XCTAssertEqual(m.currentViewMode, .source,
                       "pinning Plain Text→Source must open the .csv in Source, not Table")
    }

    // MARK: Accessor get / set / clear

    func test_setGetClear_accessor() throws {
        let m = makeModel()
        XCTAssertNil(m.defaultViewMode(for: .markdown))
        m.setDefaultViewMode(.source, for: .markdown)
        XCTAssertEqual(m.defaultViewMode(for: .markdown), .source)
        m.setDefaultViewMode(nil, for: .markdown)
        XCTAssertNil(m.defaultViewMode(for: .markdown))
    }

    func test_pinPersistsThroughModelPreferences() throws {
        // The model writes through to the injected PreferencesStore, so a second
        // model over the same defaults honors the pin on its own opens.
        let first = makeModel()
        first.setDefaultViewMode(.source, for: .markdown)

        let md = try write("# Title\n", named: "doc.md")
        let second = makeModel()
        XCTAssertEqual(second.defaultViewMode(for: .markdown), .source,
                       "the pin must survive across model instances (persisted)")
        second.open(url: md)
        XCTAssertEqual(second.currentViewMode, .source)
    }
}
