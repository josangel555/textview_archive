import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// T1m tests for the source-view find bar.
///
/// The source view is pure SwiftUI now — there is no `NSTextView` to host
/// AppKit's native find bar, so Cmd+F routes to the SwiftUI
/// `MarkdownFindBar` (works in both rendered and source mode), gated by
/// `model.isRenderedFindBarPresented`. Every assertion here reads
/// `model.*` directly, so this is a pure model-level suite: no
/// `NSHostingView`, no live `WKWebView`, no `#192` gate, host-headless.
///
/// (History: this file used to carry `renderHost`/`hostedViews`/
/// `descendants` plumbing and a `WebViewTestTeardown.skipUnlessEnabled()`
/// gate from when it was a T2' suite. No test ever called the plumbing —
/// it was dead code paying the WebView-gate tax — so it was deleted in
/// the testing-pyramid migration, §3.2.)
@MainActor
final class FindBarTests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FindBar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "FindBar-\(UUID().uuidString)"
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

    func test_findBar_modelStateUpdatesForSourceView() throws {
        let model = makeModel()
        let url = tmpDir.appendingPathComponent("find.xml")
        try "<root>\n<a>findme</a>\n</root>\n".write(to: url, atomically: true, encoding: .utf8)
        model.open(url: url)
        XCTAssertFalse(model.isRenderedFindBarPresented)
        model.showRenderedFindBar()
        XCTAssertTrue(model.isRenderedFindBarPresented)
        model.renderedFindQuery = "findme"
        XCTAssertEqual(model.renderedFindQuery, "findme")
        model.dismissRenderedFindBar()
        XCTAssertFalse(model.isRenderedFindBarPresented)
        XCTAssertEqual(model.renderedFindQuery, "")
    }
}
