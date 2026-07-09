import XCTest
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// TSK-1319 — the active-tab content-menu accessor: the model derives the dynamic
/// menu's title + actions from the current tab's category. The category→actions
/// mapping is pinned by ContentActionMenuTests; this pins the model wiring (the
/// live NSMenu build is the AppKit/render tail).
@MainActor
final class DocumentModelContentMenuTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ContentMenu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            history: HistoryStore(storeURL: tmp.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: UserDefaults(suiteName: "CM-\(UUID().uuidString)")!))
    }

    private func open(_ name: String, _ contents: String, in model: DocumentModel) {
        let url = tmp.appendingPathComponent(name)
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        model.open(url: url)
    }

    func test_markdownTab_hasMarkdownContentMenu() {
        let model = makeModel()
        open("note.md", "# Hi\n", in: model)
        let menu = model.activeContentMenu
        XCTAssertEqual(menu?.title, "Markdown")
        XCTAssertTrue(menu?.actions.map(\.verb).contains("lint-markdown") == true)
    }

    func test_csvTab_hasDataContentMenu() {
        let model = makeModel()
        open("data.csv", "a,b\n1,2\n", in: model)
        let menu = model.activeContentMenu
        XCTAssertEqual(menu?.title, "Data")
        XCTAssertTrue(menu?.actions.map(\.verb).contains("csv-summary") == true)
    }

    func test_imageTab_hasNoContentMenu() {
        let model = makeModel()
        open("pic.png", "", in: model)   // category is extension-derived
        XCTAssertEqual(model.currentCategory, .image)
        XCTAssertNil(model.activeContentMenu, "image tabs have no verb-based content menu")
    }

    func test_noTab_hasNoContentMenu() {
        XCTAssertNil(makeModel().activeContentMenu)
    }

    func test_openAsOverride_switchesTheContentMenu() throws {
        let model = makeModel()
        open("ambiguous.md", "# doc\n", in: model)
        XCTAssertEqual(model.activeContentMenu?.title, "Markdown")
        // Force "Open As… Code" — the content menu follows the category override.
        let url = try XCTUnwrap(model.currentURL)
        model.openAs(url: url, category: .code)
        XCTAssertEqual(model.activeContentMenu?.title, "Code")
    }
}
