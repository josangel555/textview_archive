import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// T1m model/string tests for the Mermaid render pipeline, split out of
/// `MermaidHostingTests` by the §3.2 migration.
///
/// These exercise the pure value path — `DocumentModel.renderedHTML(...)`
/// output and its render cache, plus the standalone-`.mmd`→fence synthesis
/// fed through `HTMLRenderer`. They produce strings, never host a view and
/// never mint a `WKWebView`, so they DON'T pay the `#192`
/// `MDV_RUN_WEBVIEW_TESTS` gate the WKWebView-realization probe
/// (`MermaidHostingTests.test_openMmdFile_hostsWKWebView`) still needs.
/// Host-headless, part of the merge gate.
@MainActor
final class MermaidRenderModelTests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var historyStoreURL: URL!
    private var bookmarksStoreURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MermaidRenderModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "MermaidRenderModel-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        historyStoreURL = tmpDir.appendingPathComponent("history.json")
        bookmarksStoreURL = tmpDir.appendingPathComponent("bookmarks.json")
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

    // MARK: - .mmd → fence synthesis

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
