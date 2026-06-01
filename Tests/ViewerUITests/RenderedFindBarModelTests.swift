import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// T1m model-state tests for the markdown rendered find bar, split out of
/// `RenderedFindBarTests` by the §3.2 migration.
///
/// These read `model.*` only — the find-bar presented flag, the query
/// clear-on-dismiss contract, and the next/prev request counters that the
/// `MarkdownRenderedView` representable observes. They never host a view,
/// never mint a `WKWebView`, so they DON'T pay the `#192`
/// `MDV_RUN_WEBVIEW_TESTS` gate the view-tree half (`RenderedFindBarTests`)
/// still needs. Host-headless, part of the merge gate.
@MainActor
final class RenderedFindBarModelTests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenderedFindBarModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "RenderedFindBarModel-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
        if let suiteName, let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        try await super.tearDown()
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("h.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    func test_showAndDismiss_togglesIsPresented() throws {
        let model = makeModel()
        XCTAssertFalse(model.isRenderedFindBarPresented)
        model.showRenderedFindBar()
        XCTAssertTrue(model.isRenderedFindBarPresented)
        model.dismissRenderedFindBar()
        XCTAssertFalse(model.isRenderedFindBarPresented)
    }

    func test_dismiss_clearsQuery() throws {
        let model = makeModel()
        model.showRenderedFindBar()
        model.renderedFindQuery = "needle"
        XCTAssertEqual(model.renderedFindQuery, "needle")
        model.dismissRenderedFindBar()
        XCTAssertEqual(model.renderedFindQuery, "")
    }

    func test_nextAndPrev_incrementCounters() throws {
        let model = makeModel()
        let n0 = model.renderedFindNextRequest
        let p0 = model.renderedFindPrevRequest
        model.renderedFindNext()
        model.renderedFindNext()
        model.renderedFindPrev()
        XCTAssertEqual(model.renderedFindNextRequest, n0 &+ 2)
        XCTAssertEqual(model.renderedFindPrevRequest, p0 &+ 1)
    }
}
