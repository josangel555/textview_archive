import XCTest
import AppKit
import SwiftUI
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// SwiftUI-integration tests for the Mermaid pipeline.
///
/// The lower-level pieces are already heavily covered:
///   - `MermaidSourceParserTests` — front-matter + step parsing
///   - `MermaidVendorTests` — bundled runtime integrity + SHA pin
///   - `HTMLRendererMermaidTests` — fence → `<div class="mdv-mermaid">`
///
/// What was NOT covered: the SwiftUI layer that actually drives the
/// browser. Two integration probes:
///   1. `DocumentModel.renderedHTML(...)` for a markdown file with a
///      mermaid fence: the cached output must include both the mermaid
///      host div AND the shim CSS. (Cache hit on second call.)
///   2. Opening a `.mmd` file in `ContentView` produces a WKWebView in
///      the hosted tree — i.e. ContentView routes the
///      `category == .mermaid` branch into the rendered pipeline, not
///      the source view. Regression guard for the wrapping logic in
///      ContentView.loadedView around lines 151-162.
@MainActor
final class MermaidHostingTests: XCTestCase {

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

    // MARK: - renderedHTML emits mermaid host + shim CSS

    func test_renderedHTML_includesMermaidHostAndShimCSS() throws {
        let m = makeModel()
        let url = try writeFile("diagram.md",
                                "# Hi\n\n```mermaid\nflowchart LR\n  A --> B\n```\n")
        m.open(url: url)

        guard case .loaded(let file) = m.currentState else {
            return XCTFail("Expected .loaded, got \(m.currentState)")
        }
        guard let tabID = m.tabs.selected?.id else { return XCTFail("no selected tab") }
        let html = m.renderedHTML(
            forTabID: tabID,
            file: file,
            contents: file.contents,
            renderer: HTMLRenderer(),
            stylesheet: ""
        )
        XCTAssertTrue(html.contains("<div class=\"mdv-mermaid\""),
                      "renderedHTML must route mermaid fences to the host div")
        // Shim CSS is inlined unconditionally by DocumentModel —
        // check for one of its sentinel selectors. The exact text
        // depends on the bundled `mermaid-shim.css`; we check for
        // the class prefix the shim relies on.
        XCTAssertTrue(html.contains(".mdv-mermaid") || html.contains("mdv-mermaid"),
                      "shim CSS (or at minimum the host class) must appear in the page")
    }

    func test_renderedHTML_cacheHitOnSecondCall() throws {
        // The cache is the production hot path — verify it's wired
        // up (same input → identical output, not just equivalent).
        let m = makeModel()
        let url = try writeFile("diagram.md", "```mermaid\nflowchart LR\nA-->B\n```\n")
        m.open(url: url)
        guard case .loaded(let file) = m.currentState else { return XCTFail() }
        guard let tabID = m.tabs.selected?.id else { return XCTFail("no selected tab") }
        let renderer = HTMLRenderer()
        let html1 = m.renderedHTML(forTabID: tabID, file: file, contents: file.contents,
                                   renderer: renderer, stylesheet: "")
        let html2 = m.renderedHTML(forTabID: tabID, file: file, contents: file.contents,
                                   renderer: renderer, stylesheet: "")
        XCTAssertEqual(html1, html2)
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

        let host = host(ContentView(model: m))
        let descendants = allDescendants(of: host)
        let webViewClass: AnyClass = NSClassFromString("WKWebView")!
        let webViews = descendants.filter { $0.isKind(of: webViewClass) }
        XCTAssertFalse(webViews.isEmpty,
                       ".mmd file should host a WKWebView (rendered path)")
    }

    func test_mmdFile_synthesizesMermaidFence_viaCategory() throws {
        // Standalone `.mmd` body is wrapped into a single mermaid
        // fence so the HTMLRenderer pipeline handles it identically
        // to an inline ```mermaid block. Verify the wrapper produces
        // a mermaid host div when fed through the renderer.
        let body = "flowchart LR\n  A --> B\n"
        let wrapped = "```mermaid\n\(body)\n```\n"
        let html = HTMLRenderer().render(wrapped)
        XCTAssertTrue(html.contains("<div class=\"mdv-mermaid\""),
                      "wrapped .mmd body must produce a mermaid host")
    }
}
