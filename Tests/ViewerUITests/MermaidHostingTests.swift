import XCTest
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// T2' view-tree test for the Mermaid pipeline's SwiftUI hosting layer.
///
/// The lower-level pieces are already heavily covered:
///   - `MermaidSourceParserTests` — front-matter + step parsing
///   - `MermaidVendorTests` — bundled runtime integrity + SHA pin
///   - `HTMLRendererMermaidTests` — fence → `<div class="mdv-mermaid">`
///
/// After the §3.2 split, what stays here is the one probe that genuinely
/// needs a realized `NSHostingView` tree + a live `WKWebView`: opening a
/// `.mmd` file in `ContentView` mints a `WKWebView` (i.e. ContentView
/// routes the `category == .mermaid` branch into the rendered pipeline,
/// not the source view). It therefore keeps the `#192`
/// `MDV_RUN_WEBVIEW_TESTS` gate + `WebViewTestTeardown` graph-quiesce.
///
/// The string/cache asserts (`renderedHTML` emits the mermaid host + shim
/// CSS; cache hit on second call; the `.mmd`→fence synthesis) moved to the
/// UNGATED T1m `MermaidRenderModelTests` — they are pure `DocumentModel` /
/// `HTMLRenderer` string output and never host a view.
@MainActor
final class MermaidHostingTests: WebViewTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var historyStoreURL: URL!
    private var bookmarksStoreURL: URL!
    /// #192: every host(...) call that embeds a WKWebView is tracked so
    /// tearDown can dismantle it and reclaim the WebContent process.
    private var hostedViews: [NSView] = []

    override func setUp() async throws {
        // No super.setUp — @MainActor strict-concurrency.
        // #192: process-isolated — skipped in the bare sweep.
        try WebViewTestTeardown.skipUnlessEnabled()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MermaidHostingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "MermaidHostingTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        historyStoreURL = tmpDir.appendingPathComponent("history.json")
        bookmarksStoreURL = tmpDir.appendingPathComponent("bookmarks.json")
    }

    override func tearDown() async throws {
        // #192: dismantle any WKWebViews the test created before the
        // host trees are released, so the WebContent helper processes
        // are reclaimed deterministically instead of piling up.
        WebViewTestTeardown.teardown(hostedViews)
        hostedViews.removeAll()
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
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
    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func host<V: View>(_ view: V, size: NSSize = NSSize(width: 800, height: 600)) -> NSView {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        hostedViews.append(host)  // #192: track for WebView teardown
        return host
    }

    private func allDescendants(of view: NSView) -> [NSView] {
        var result: [NSView] = [view]
        for sub in view.subviews { result.append(contentsOf: allDescendants(of: sub)) }
        return result
    }

    // MARK: - .mmd file routes to the rendered pipeline

    func test_openMmdFile_hostsWKWebView() throws {
        let m = makeModel()
        let url = try writeFile("flow.mmd", "flowchart LR\n  A --> B\n")
        m.open(url: url)

        // A `.mmd` file's default view mode is `.rendered` (the
        // standalone-mermaid path in ViewModeOptions.defaultMode).
        // ContentView must therefore embed a WKWebView, not a source
        // view. Regression guard: if someone "fixes" the category ==
        // .mermaid branch in ContentView.loadedView, this catches it.
        XCTAssertEqual(m.currentViewMode, .rendered,
                       ".mmd files should open in rendered mode by default")

        // TSK-623: since TSK-611 the rendered branch shows a spinner
        // until the off-main render fills the cache — await the mount.
        let host = host(ContentView(model: m))
        let webViewClass: AnyClass = NSClassFromString("WKWebView")!
        var webViews: [NSView] = []
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            webViews = allDescendants(of: host).filter { $0.isKind(of: webViewClass) }
            if !webViews.isEmpty { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertFalse(webViews.isEmpty,
                       ".mmd file should host a WKWebView (rendered path) "
                       + "once the async fill lands (TSK-611 contract)")
    }
}
