import Combine
import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// T1m behavior tests for the async rendered-HTML fill (TSK-611).
///
/// The cold markdown→HTML render (including per-language TreeSitter
/// `ts_query_new` compiles for code fences) used to run inline in
/// `ContentView.renderedMarkdownView`'s body — measured as a 927ms
/// main-thread hang at file open in the TSK-592 VM trace. The body now
/// only READS the cache (`renderedHTMLIfCached`) and kicks
/// `requestRenderedHTML`, which renders off-main and republishes when
/// the cache fills. These tests pin that model contract: miss → request
/// fills + republishes; duplicate/cached requests are no-ops; results
/// for closed tabs are dropped. Pure model/string layer — never hosts a
/// view, never mints a WKWebView; host-headless, part of the merge gate.
@MainActor
final class RenderedHTMLAsyncFillTests: HeadlessUITestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var historyStoreURL: URL!
    private var bookmarksStoreURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenderedHTMLAsyncFill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "RenderedHTMLAsyncFill-\(UUID().uuidString)"
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

    /// Opens a markdown file with a code fence (so the render exercises
    /// the TreeSitter tokenize path the hang came from) and returns the
    /// loaded (model, tabID, file) triple.
    private func openFencedMarkdown(
        _ name: String = "doc.md"
    ) throws -> (DocumentModel, UUID, TextFile) {
        let url = tmpDir.appendingPathComponent(name)
        try "# T\n\n```json\n{\"k\": 1}\n```\n"
            .write(to: url, atomically: true, encoding: .utf8)
        let m = makeModel()
        m.open(url: url)
        guard case .loaded(let file) = m.currentState else {
            throw XCTSkip("open did not load — environment problem, not the unit under test")
        }
        let tabID = try XCTUnwrap(m.tabs.selected?.id)
        return (m, tabID, file)
    }

    func test_ifCached_missThenRequestFillsAndRepublishes() async throws {
        let (m, tabID, file) = try openFencedMarkdown()
        XCTAssertNil(m.renderedHTMLIfCached(forTabID: tabID, file: file),
                     "no render yet — body must see a miss, not block")

        var republished = false
        let sub = m.objectWillChange.sink { republished = true }
        defer { sub.cancel() }

        let task = m.requestRenderedHTML(
            forTabID: tabID, file: file, contents: file.contents,
            renderer: HTMLRenderer(), stylesheet: ""
        )
        let kicked = try XCTUnwrap(task, "cache miss must kick a render task")
        await kicked.value

        let html = try XCTUnwrap(
            m.renderedHTMLIfCached(forTabID: tabID, file: file),
            "render result must land in the cache")
        XCTAssertTrue(html.contains("<pre><code"),
                      "the fenced block must be rendered")
        XCTAssertTrue(republished,
                      "the fill must republish so bodies re-evaluate onto the cache")
    }

    func test_request_dedupesInFlightAndSkipsCached() async throws {
        let (m, tabID, file) = try openFencedMarkdown()
        let renderer = HTMLRenderer()

        let first = m.requestRenderedHTML(
            forTabID: tabID, file: file, contents: file.contents,
            renderer: renderer, stylesheet: "")
        XCTAssertNotNil(first)
        // Same key while the first render is in flight → deduped.
        XCTAssertNil(m.requestRenderedHTML(
            forTabID: tabID, file: file, contents: file.contents,
            renderer: renderer, stylesheet: ""),
            "in-flight key must not kick a second render")

        await first?.value
        // Cache hit → no new task either.
        XCTAssertNil(m.requestRenderedHTML(
            forTabID: tabID, file: file, contents: file.contents,
            renderer: renderer, stylesheet: ""),
            "cached key must not kick a render")
    }

    func test_request_dropsResultForClosedTab() async throws {
        let (m, tabID, file) = try openFencedMarkdown()
        let task = try XCTUnwrap(m.requestRenderedHTML(
            forTabID: tabID, file: file, contents: file.contents,
            renderer: HTMLRenderer(), stylesheet: ""))
        // Close the tab while the render is in flight.
        if let idx = m.tabs.tabs.firstIndex(where: { $0.id == tabID }) {
            m.closeTab(at: idx)
        }
        await task.value
        XCTAssertNil(m.renderedHTMLIfCached(forTabID: tabID, file: file),
                     "a result landing after its tab closed must be dropped, "
                     + "not resurrect a purged cache entry")
    }

    func test_syncAndAsyncPathsShareTheCache() async throws {
        // The sync API (kept for warm fallbacks + existing callers) and
        // the async fill must agree: a sync render makes the async lookup
        // hit, and vice versa.
        let (m, tabID, file) = try openFencedMarkdown()
        let renderer = HTMLRenderer()
        let syncHTML = m.renderedHTML(
            forTabID: tabID, file: file, contents: file.contents,
            renderer: renderer, stylesheet: "")
        XCTAssertEqual(m.renderedHTMLIfCached(forTabID: tabID, file: file), syncHTML)
        XCTAssertNil(m.requestRenderedHTML(
            forTabID: tabID, file: file, contents: file.contents,
            renderer: renderer, stylesheet: ""),
            "sync render already cached this key — request must no-op")
    }
}
