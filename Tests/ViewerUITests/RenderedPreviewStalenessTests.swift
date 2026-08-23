import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Owner 2026-08-22: "Markdown previews are not updating when files are
/// updated. Even right-click → reload doesn't update." The rendered lens
/// reads `renderedHTMLIfCached` keyed by (tabID, byteCount, mtime); the
/// spinner branch's `.task(id: key)` kicks the render. This suite drives
/// the exact model flow (external change → watcher/manual reload) and pins
/// every link the view depends on: the reload must land a NEW TextFile
/// (new key), the OLD cache entry must not satisfy the new key, and a
/// re-render request for the new key must produce updated HTML.
@MainActor
final class RenderedPreviewStalenessTests: XCTestCase {

    private var tmp: URL!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mdv-preview-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
    }

    private func loadedFile(_ model: DocumentModel, index: Int) -> TextFile? {
        guard case .loaded(let f) = model.tabs.tabs[index].state else { return nil }
        return f
    }

    func test_externalChange_reload_missesOldCache_andRerendersNewContent() async throws {
        let url = tmp.appendingPathComponent("doc.md")
        try "# Version ONE\n".write(to: url, atomically: true, encoding: .utf8)

        let model = DocumentModel()
        model.open(url: url)
        guard let f1 = loadedFile(model, index: 0) else { return XCTFail("not loaded") }
        let tabID = model.tabs.tabs[0].id

        // Render v1 into the cache (the spinner branch's request).
        let renderer = HTMLRenderer()
        _ = model.renderedHTML(forTabID: tabID, file: f1, contents: f1.contents,
                               renderer: renderer, stylesheet: "")
        XCTAssertNotNil(model.renderedHTMLIfCached(forTabID: tabID, file: f1))
        XCTAssertTrue(model.renderedHTMLIfCached(forTabID: tabID, file: f1)!
            .contains("Version ONE"))

        // EXTERNAL change (different byte count AND different mtime —
        // ensure the mtime tick even on coarse filesystems).
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try "# Version TWO — updated externally\n"
            .write(to: url, atomically: true, encoding: .utf8)

        // The right-click Refresh path (the watcher's clean-tab path funnels
        // into the same reload(url:at:)).
        model.refreshTab(at: 0)
        guard let f2 = loadedFile(model, index: 0) else { return XCTFail("not reloaded") }

        XCTAssertTrue(f2.contents.contains("Version TWO"),
            "the reload must land the new bytes in the tab")
        XCTAssertFalse(f2.byteCount == f1.byteCount && f2.modifiedTime == f1.modifiedTime,
            "the rendered-cache key must change (byteCount or mtime)")
        XCTAssertNil(model.renderedHTMLIfCached(forTabID: tabID, file: f2),
            "the NEW file must MISS the cache — a hit here means the view "
            + "keeps the stale page and never re-renders (the owner's bug)")

        // The spinner branch's request must fill the cache with V2 html.
        _ = model.renderedHTML(forTabID: tabID, file: f2, contents: f2.contents,
                               renderer: renderer, stylesheet: "")
        let html2 = model.renderedHTMLIfCached(forTabID: tabID, file: f2)
        XCTAssertNotNil(html2)
        XCTAssertTrue(html2!.contains("Version TWO"),
            "the re-render must reflect the external content")
    }

    /// Owner 2026-08-22 hole A: with the window SPLIT, the UNFOCUSED
    /// pane's visible file must be watched — an external change reloads
    /// its clean tab automatically (the selected tab keeps the main
    /// watcher). Pins the watcher SET sync + the reload-on-event handler
    /// behavior via the model seams.
    func test_unfocusedPaneFile_isWatched_andExternalChangeReloadsIt() async throws {
        let urlA = tmp.appendingPathComponent("a.md")
        let urlB = tmp.appendingPathComponent("b.md")
        try "# A one\n".write(to: urlA, atomically: true, encoding: .utf8)
        try "# B one\n".write(to: urlB, atomically: true, encoding: .utf8)

        let model = DocumentModel()
        model.open(url: urlA)
        model.open(url: urlB)                      // B selected
        model.tabCoordinator.splitFocusedPane(movingSelected: true)
        model.selectTab(at: model.tabs.tabs.firstIndex { $0.url == urlB } ?? 0)

        XCTAssertNotNil(model.paneFileWatchers[urlA],
            "the unfocused pane's front file (a.md) must be watched")
        XCTAssertNil(model.paneFileWatchers[urlB],
            "the focused pane's tab rides the main watcher, not a pane watcher")

        // External change to the UNFOCUSED pane's file → the watcher fires
        // and the clean tab reloads. Wait on the debounced FS event.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        try "# A two — external\n".write(to: urlA, atomically: true, encoding: .utf8)
        var reloaded = false
        for _ in 0..<40 {   // up to ~4s for FSEvents + debounce
            try await Task.sleep(nanoseconds: 100_000_000)
            if let idx = model.tabs.tabs.firstIndex(where: { $0.url == urlA }),
               case .loaded(let f) = model.tabs.tabs[idx].state,
               f.contents.contains("A two") { reloaded = true; break }
        }
        XCTAssertTrue(reloaded,
            "an external change to the unfocused pane's visible file must "
            + "auto-reload its clean tab")

        // Un-splitting drops the pane watcher.
        model.closePane(id: model.tabCoordinator.paneAssignment.panes[1].id)
        XCTAssertTrue(model.paneFileWatchers.isEmpty,
            "un-split ⇒ no pane watchers remain")
    }

    /// The SAME-byte-count external edit — the nastier key: only mtime
    /// distinguishes the versions. (An editor that rewrites "AAAA"→"BBBB"
    /// keeps byteCount identical.)
    func test_sameLengthExternalChange_stillMissesCache() async throws {
        let url = tmp.appendingPathComponent("same-len.md")
        try "# AAAA\n".write(to: url, atomically: true, encoding: .utf8)

        let model = DocumentModel()
        model.open(url: url)
        guard let f1 = loadedFile(model, index: 0) else { return XCTFail("not loaded") }
        let tabID = model.tabs.tabs[0].id
        let renderer = HTMLRenderer()
        _ = model.renderedHTML(forTabID: tabID, file: f1, contents: f1.contents,
                               renderer: renderer, stylesheet: "")

        try await Task.sleep(nanoseconds: 1_100_000_000)
        try "# BBBB\n".write(to: url, atomically: true, encoding: .utf8)
        model.refreshTab(at: 0)
        guard let f2 = loadedFile(model, index: 0) else { return XCTFail("not reloaded") }

        XCTAssertEqual(f1.byteCount, f2.byteCount, "fixture: same length")
        XCTAssertNil(model.renderedHTMLIfCached(forTabID: tabID, file: f2),
            "mtime alone must bust the rendered cache")
    }
}
