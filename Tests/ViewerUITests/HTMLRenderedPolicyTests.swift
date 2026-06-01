import XCTest
import WebKit
@testable import ViewerUI
@testable import ViewerCore
@testable import ViewerKit

/// Host-safe coverage for the raw-HTML render path's PER-TAB JavaScript
/// opt-in (the L2 default-deny contract) and the `HTMLRenderedView`
/// coordinator's default state. No `WKWebView` is instantiated — the
/// `WebKit` import is only for type availability where needed. The live
/// render is the VM-only visual residue; the policy regressions are
/// caught here.
@MainActor
final class HTMLRenderedPolicyTests: XCTestCase {

    private var tmpRoot: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var historyStoreURL: URL!
    private var bookmarksStoreURL: URL!

    override func setUp() async throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HTMLRenderedPolicyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        suiteName = "HTMLRenderedPolicyTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        historyStoreURL = tmpRoot.appendingPathComponent("history.json")
        bookmarksStoreURL = tmpRoot.appendingPathComponent("bookmarks.json")
    }

    override func tearDown() async throws {
        if let tmpRoot { try? FileManager.default.removeItem(at: tmpRoot) }
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: historyStoreURL),
            bookmarks: BookmarksStore(storeURL: bookmarksStoreURL),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String = "<h1>hi</h1>\n") throws -> URL {
        let url = tmpRoot.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - L2: per-tab JS opt-in defaults OFF

    func test_htmlJS_defaultsOff_perTab() throws {
        let m = makeModel()
        let url = try writeFile("page.html")
        m.open(url: url)
        let id = m.tabs.selected!.id
        XCTAssertFalse(m.htmlJavaScriptEnabled(forTabID: id),
                       "raw-HTML JS must default OFF for a fresh tab")
        XCTAssertFalse(m.currentHTMLJavaScriptEnabled)
    }

    func test_htmlJS_optInThenOff() throws {
        let m = makeModel()
        let url = try writeFile("page.html")
        m.open(url: url)
        let id = m.tabs.selected!.id

        m.setHTMLJavaScriptEnabled(true, forTabID: id)
        XCTAssertTrue(m.htmlJavaScriptEnabled(forTabID: id))
        XCTAssertTrue(m.currentHTMLJavaScriptEnabled)

        m.setHTMLJavaScriptEnabled(false, forTabID: id)
        XCTAssertFalse(m.htmlJavaScriptEnabled(forTabID: id),
                       "turning the opt-in off must return to the secure default")
    }

    func test_htmlJS_toggleCurrent() throws {
        let m = makeModel()
        let url = try writeFile("page.html")
        m.open(url: url)
        let id = m.tabs.selected!.id

        XCTAssertFalse(m.htmlJavaScriptEnabled(forTabID: id))
        m.toggleCurrentHTMLJavaScript()
        XCTAssertTrue(m.htmlJavaScriptEnabled(forTabID: id))
        m.toggleCurrentHTMLJavaScript()
        XCTAssertFalse(m.htmlJavaScriptEnabled(forTabID: id))
    }

    func test_htmlJS_isPerTab_doesNotBleed() throws {
        let m = makeModel()
        let url = try writeFile("page.html")
        m.open(url: url)
        let firstID = m.tabs.selected!.id

        m.openInNewTab(url)
        let secondID = m.tabs.selected!.id
        XCTAssertNotEqual(firstID, secondID)

        // Opt the second tab in; the first stays OFF.
        m.setHTMLJavaScriptEnabled(true, forTabID: secondID)
        XCTAssertTrue(m.htmlJavaScriptEnabled(forTabID: secondID))
        XCTAssertFalse(m.htmlJavaScriptEnabled(forTabID: firstID),
                       "JS opt-in must not bleed across tabs")
    }

    func test_htmlJS_clearedOnTabClose() throws {
        // The opt-in set is pruned on close so a recycled UUID can't
        // inherit a stale "JS on" decision.
        let m = makeModel()
        let url = try writeFile("page.html")
        m.open(url: url)
        // Open a 2nd tab so closing the first leaves the model alive.
        m.openInNewTab(url)
        let firstIdx = 0
        let firstID = m.tabs.tabs[firstIdx].id
        m.setHTMLJavaScriptEnabled(true, forTabID: firstID)
        XCTAssertTrue(m.htmlJavaScriptEnabled(forTabID: firstID))

        m.closeTab(at: firstIdx)
        // After close the opt-in for that id must be gone (fail-closed).
        XCTAssertFalse(m.htmlJavaScriptEnabled(forTabID: firstID))
    }

    func test_htmlJS_noSelectedTab_failsClosed() {
        let m = makeModel()
        // No file open → no selected tab → current opt-in is OFF.
        XCTAssertFalse(m.currentHTMLJavaScriptEnabled)
        m.toggleCurrentHTMLJavaScript() // no-op, must not crash
        XCTAssertFalse(m.currentHTMLJavaScriptEnabled)
    }

    // MARK: - Toggle visibility gating

    func test_showsHTMLJavaScriptToggle_onlyForHTMLRendered() throws {
        let m = makeModel()
        let url = try writeFile("page.html")
        m.open(url: url)
        // Default mode for .html is .source — toggle hidden there.
        XCTAssertEqual(m.currentViewMode, .source)
        XCTAssertFalse(m.showsHTMLJavaScriptToggle)

        // Switch to rendered → toggle shown.
        m.setCurrentViewMode(.rendered)
        XCTAssertTrue(m.showsHTMLJavaScriptToggle)
    }

    func test_showsHTMLJavaScriptToggle_hiddenForMarkdown() throws {
        let m = makeModel()
        let url = try writeFile("README.md", "# hi\n")
        m.open(url: url)
        // Markdown defaults to rendered, but the HTML JS toggle is
        // HTML-only — it must NOT appear for markdown.
        XCTAssertEqual(m.currentViewMode, .rendered)
        XCTAssertFalse(m.showsHTMLJavaScriptToggle)
    }

    // MARK: - HTMLRenderedView.Coordinator default state (L2)

    func test_coordinator_lastDocument_startsNil() {
        let c = HTMLRenderedView.Coordinator()
        XCTAssertNil(c.lastDocument)
    }

    func test_coordinator_lastJSEnabled_startsNil() {
        // Nil means "no load applied yet" — the first load is forced.
        let c = HTMLRenderedView.Coordinator()
        XCTAssertNil(c.lastJSEnabled)
    }

    func test_coordinator_didFinishFirstLoad_startsFalse() {
        // Bootstrap-permissive: the first `.other` load is the document
        // paint, allowed by `decideSubresource(isInitialDocumentLoad:)`.
        let c = HTMLRenderedView.Coordinator()
        XCTAssertFalse(c.didFinishFirstLoad)
    }

    // MARK: - View carries the default-off JS flag

    func test_view_defaultInit_javaScriptOff() {
        // The representable's default initializer must leave JS OFF —
        // a wiring regression that defaults it on would be a silent
        // security hole.
        let v = HTMLRenderedView(
            rawHTML: "<h1>x</h1>",
            documentURL: URL(fileURLWithPath: "/tmp/x.html")
        )
        XCTAssertFalse(v.javaScriptEnabled)
    }
}
