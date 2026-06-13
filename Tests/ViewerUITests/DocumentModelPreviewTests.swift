import XCTest
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Host-tier behaviour tests for the sidebar preview-tab feature
/// (TSK-306 / TSK-272 — see `docs/PREVIEW_TAB_DESIGN.md`), exercised at the
/// `DocumentModel` boundary the SwiftUI triggers actually call.
///
/// The model core (`TabsState.openPreview/promoteTab`) is unit-tested in
/// `TabsStatePreviewTests`; these pin the DocumentModel forwarder +
/// auto-promote-on-edit wiring — i.e. that `openPreview(url:)` reuses ONE
/// ephemeral slot and that every promotion path (re-open / Enter via
/// `open(url:)` / editing the buffer) clears the flag. The actual SwiftUI
/// gesture routing + italic affordance are the VM-only render layer
/// (Phase 2/3); these cover the host-testable behaviour beneath them, so a
/// logic regression fails the headless gate even though the pixels are VM-only.
///
/// Tier: window-free (drives DocumentModel directly, no NSWindow) — host-safe,
/// same harness as `DocumentModelEditorForwarderTests`.
@MainActor
final class DocumentModelPreviewTests: XCTestCase {

    private var tmpDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentModelPreviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        suiteName = "DocumentModelPreviewTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpDir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeModel() -> DocumentModel {
        DocumentModel(
            controller: DocumentController(),
            history: HistoryStore(storeURL: tmpDir.appendingPathComponent("history.json")),
            sidebar: SidebarModel(),
            preferences: PreferencesStore(defaults: defaults)
        )
    }

    @discardableResult
    private func writeFile(_ name: String, _ contents: String = "x") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Tabs flagged ephemeral-preview, by title (stable, order-independent).
    private func previewTitles(_ model: DocumentModel) -> [String] {
        model.tabs.tabs.filter { $0.isPreview }.map { $0.title }
    }

    /// A `SourceScrollState` whose `topVisibleLine` resolves to `topLine`
    /// (1-based) — the inverse of the production capture math.
    private func scrollState(topLine: Int, lineCount: Int = 500,
                             lineHeight: CGFloat = 16, topInset: CGFloat = 10) -> SourceScrollState {
        SourceScrollState(
            offsetY: topInset + CGFloat(topLine - 1) * lineHeight,
            viewportHeight: 400, lineHeight: lineHeight,
            lineCount: lineCount, topInset: topInset)
    }

    func test_renderedScroll_remembersAndRestoresPerURL() throws {
        // TSK-821 (rendered channel): the model store for per-file rendered
        // WKWebView scroll. The view bridge (window.scrollY capture / scrollTo
        // restore) is the VM lane; this pins the store contract the bridge uses.
        let model = makeModel()
        let a = try writeFile("a.md", "# A")
        let b = try writeFile("b.md", "# B")

        XCTAssertNil(model.renderedScrollOffset(for: a), "never-scrolled file → top (nil)")
        XCTAssertNil(model.renderedScrollOffset(for: nil), "nil url → nil")

        model.rememberRenderedScroll(420, for: a)
        model.rememberRenderedScroll(90, for: b)
        XCTAssertEqual(model.renderedScrollOffset(for: a), 420, "A restores its own offset")
        XCTAssertEqual(model.renderedScrollOffset(for: b), 90, "B restores its own offset (isolation)")

        // Top (y<=0) is the default — must NOT overwrite a remembered offset,
        // else a no-op scroll report at the reload boundary would erase it.
        model.rememberRenderedScroll(0, for: a)
        XCTAssertEqual(model.renderedScrollOffset(for: a), 420,
                       "y<=0 must not overwrite a remembered offset")
    }

    func test_previewReturn_restoresSourceScrollPerFile() throws {
        // TSK-743 (source channel): the preview slot remembers each file's
        // SOURCE-view (NSTextView) top line by URL, so returning to a file you
        // scrolled restores its position — while a never-previewed file starts
        // at the top (isolation). The editor channel is covered by
        // test_previewReturn_restoresScrollAndCursorPerFile above.
        let model = makeModel()
        let a = try writeFile("a.txt", String(repeating: "alpha\n", count: 200))
        let b = try writeFile("b.txt", String(repeating: "bravo\n", count: 200))

        model.openPreview(url: a)
        let id = try XCTUnwrap(model.tabs.previewTabID)
        model.sourceScrollState = scrollState(topLine: 137)   // A scrolled to 137

        // Swap to B (never previewed) → captures A@137; B starts clean.
        model.openPreview(url: b)
        XCTAssertEqual(model.tabs.previewTabID, id, "same reused preview slot")
        XCTAssertNil(try XCTUnwrap(model.tabs.tabs.first { $0.id == id }).scrollTopLine,
                     "B was never previewed → starts at the top (isolation)")

        // B scrolled to 42; return to A → captures B@42, restores A@137.
        model.sourceScrollState = scrollState(topLine: 42)
        model.openPreview(url: a)
        XCTAssertEqual(try XCTUnwrap(model.tabs.tabs.first { $0.id == id }).scrollTopLine, 137,
                       "returning to A restores A's remembered source scroll")

        // A scrolled to 9; return to B → restores B@42.
        model.sourceScrollState = scrollState(topLine: 9)
        model.openPreview(url: b)
        XCTAssertEqual(try XCTUnwrap(model.tabs.tabs.first { $0.id == id }).scrollTopLine, 42,
                       "returning to B restores B's remembered source scroll")
    }

    // MARK: - openPreview creates / reuses ONE ephemeral slot

    func test_openPreview_createsOnePreviewTab() throws {
        let model = makeModel()
        let a = try writeFile("a.txt", "alpha")
        model.openPreview(url: a)
        XCTAssertEqual(model.tabs.tabs.count, 1, "first preview reuses the blank slot")
        XCTAssertEqual(previewTitles(model), ["a.txt"], "the one tab is flagged preview")
        XCTAssertEqual(model.tabs.selected?.title, "a.txt")
        XCTAssertNotNil(model.tabs.previewTabID)
    }

    func test_openPreview_secondFile_reusesOneSlot() throws {
        let model = makeModel()
        let a = try writeFile("a.txt", "alpha")
        let b = try writeFile("b.txt", "bravo")
        model.openPreview(url: a)
        let firstID = model.tabs.previewTabID
        model.openPreview(url: b)
        // VSCode "scrub": at most ONE preview tab — b replaces a in place.
        XCTAssertEqual(model.tabs.tabs.count, 1, "preview slot is reused, not appended")
        XCTAssertEqual(previewTitles(model), ["b.txt"])
        XCTAssertEqual(model.tabs.previewTabID, firstID,
                       "same tab id reused — content swapped in place, not a new tab")
        XCTAssertNil(model.tabs.tabs.first { $0.title == "a.txt" },
                     "the previewed a.txt was replaced, not left behind")
    }

    // MARK: - Promotion paths (all three commit gestures)

    func test_openPreview_sameFileAgain_promotes() throws {
        // Models the second click of a double-click: re-opening the already-
        // previewed file finds it open and reveals-as-permanent.
        let model = makeModel()
        let a = try writeFile("a.txt", "alpha")
        model.openPreview(url: a)
        XCTAssertEqual(previewTitles(model), ["a.txt"])
        model.openPreview(url: a)
        XCTAssertEqual(model.tabs.tabs.count, 1, "no duplicate tab on re-open")
        XCTAssertTrue(previewTitles(model).isEmpty, "re-opening the preview promotes it")
        XCTAssertNil(model.tabs.previewTabID)
    }

    func test_open_promotesPreview() throws {
        // Enter / double-click route through `open(url:)`, which must commit
        // the ephemeral tab to permanent (no second tab).
        let model = makeModel()
        let a = try writeFile("a.txt", "alpha")
        model.openPreview(url: a)
        XCTAssertEqual(previewTitles(model), ["a.txt"])
        model.open(url: a)
        XCTAssertEqual(model.tabs.tabs.count, 1)
        XCTAssertTrue(previewTitles(model).isEmpty, "open() promotes the preview to permanent")
    }

    func test_editingPreview_promotes() throws {
        // Editing a preview's buffer must promote it — a dirty buffer can't be
        // silently discarded by the next single-click reusing the slot.
        let model = makeModel()
        let a = try writeFile("a.swift", "let x = 1\n")
        model.openPreview(url: a)
        let id = try XCTUnwrap(model.tabs.previewTabID)
        _ = model.editorBuffer(forTabID: id)   // materialize the buffer
        model.updateEditorText("let x = 2\n", forTabID: id)
        XCTAssertTrue(previewTitles(model).isEmpty,
                      "an edit commits the preview tab to permanent")
        XCTAssertNil(model.tabs.previewTabID)
        XCTAssertTrue(model.tabs.tabs[0].isDirty, "the edit still marks the tab dirty")
    }

    // MARK: - Never preview a file that already has a permanent tab

    func test_openPreview_alreadyOpenPermanent_revealsNotPreviews() throws {
        let model = makeModel()
        let a = try writeFile("a.txt", "alpha")
        model.open(url: a)                     // permanent tab
        XCTAssertTrue(previewTitles(model).isEmpty)
        model.openPreview(url: a)              // single-click the same file
        XCTAssertEqual(model.tabs.tabs.count, 1, "no second tab")
        XCTAssertTrue(previewTitles(model).isEmpty,
                      "an already-permanent file is revealed, never demoted to preview")
    }

    // MARK: - Preview is per-model / never duplicated across two distinct files

    func test_openPreview_invariant_atMostOnePreview() throws {
        let model = makeModel()
        let a = try writeFile("a.txt", "alpha")
        let b = try writeFile("b.txt", "bravo")
        let c = try writeFile("c.txt", "charlie")
        model.open(url: a)            // permanent
        model.openPreview(url: b)     // preview b
        model.openPreview(url: c)     // scrub to c (reuse slot)
        XCTAssertLessThanOrEqual(previewTitles(model).count, 1,
                                 "invariant: never two preview tabs")
        XCTAssertEqual(previewTitles(model), ["c.txt"])
        XCTAssertEqual(model.tabs.tabs.count, 2, "a (permanent) + one preview slot")
    }

    // MARK: - Preview-slot reuse invalidates the prior file's editor state
    //         (TSK-742 buffer, TSK-743/744 scroll/cursor)

    func test_previewSwap_reseedsEditorBufferForNewFile() throws {
        // TSK-742: the preview slot reuses one tab id; the editor buffer is keyed
        // by that id and `ensureEditorBuffer` is idempotent, so before the fix
        // file B reused file A's stale buffer (editor pane kept showing A).
        let model = makeModel()
        let a = try writeFile("a.txt", "alpha")
        let b = try writeFile("b.txt", "bravo")
        model.openPreview(url: a)
        let id = try XCTUnwrap(model.tabs.previewTabID)
        XCTAssertEqual(model.editorBuffer(forTabID: id)?.text, "alpha", "buffer seeds from A")

        model.openPreview(url: b)   // same slot, new file
        XCTAssertEqual(model.tabs.previewTabID, id, "same preview tab id reused")
        XCTAssertEqual(model.editorBuffer(forTabID: id)?.text, "bravo",
                       "after the swap the editor buffer must reseed from B — not keep A's stale content")
    }

    func test_previewSwap_resetsScrollState() throws {
        // TSK-743/744: scroll/cursor are also keyed by the reused tab id, so A's
        // scroll leaked onto B (744) and A's position wasn't preserved per-file (743).
        let model = makeModel()
        let a = try writeFile("a.txt", "alpha\nbeta\ngamma\n")
        let b = try writeFile("b.txt", "bravo")
        model.openPreview(url: a)
        let id = try XCTUnwrap(model.tabs.previewTabID)
        _ = model.editorBuffer(forTabID: id)   // materialize A's editor state
        model.recordEditorScroll(
            CMScrollPosition(top: 500, left: 0, viewportFromLine: 40, viewportToLine: 60),
            forTabID: id)
        XCTAssertNotNil(model.editor.editorScrollByTab[id], "A's scroll recorded")

        model.openPreview(url: b)   // swap files in the reused slot
        XCTAssertNil(model.editor.editorScrollByTab[id],
                     "A's scroll must NOT leak onto B — the reused id's scroll is reset on swap")
    }

    func test_previewSwap_sameFile_keepsBuffer() throws {
        // Re-previewing the SAME file must NOT invalidate (it promotes, and the
        // url is unchanged) — guards against over-invalidation.
        let model = makeModel()
        let a = try writeFile("a.txt", "alpha")
        model.openPreview(url: a)
        let id = try XCTUnwrap(model.tabs.previewTabID)
        let buf = model.editorBuffer(forTabID: id)
        XCTAssertEqual(buf?.text, "alpha")
        model.openPreview(url: a)   // same file again → promotes, no file swap
        XCTAssertEqual(model.editorBuffer(forTabID: id)?.text, "alpha",
                       "same-file re-preview must keep the buffer")
    }

    func test_previewReturn_restoresScrollAndCursorPerFile() throws {
        // TSK-743 (the "preserve scroll state per file" wish, distinct from the
        // TSK-744 isolation defect above): the preview slot now REMEMBERS each
        // file's scroll/cursor by URL, so returning to a file you scrolled
        // earlier restores its position — while a never-before-previewed file
        // still starts clean (isolation preserved).
        let model = makeModel()
        let a = try writeFile("a.txt", "alpha\nbeta\ngamma\ndelta\n")
        let b = try writeFile("b.txt", "bravo\necho\n")
        model.openPreview(url: a)
        let id = try XCTUnwrap(model.tabs.previewTabID)
        _ = model.editorBuffer(forTabID: id)
        model.recordEditorScroll(
            CMScrollPosition(top: 500, left: 0, viewportFromLine: 40, viewportToLine: 60),
            forTabID: id)
        model.recordEditorCursor(
            CMCursorPosition(line: 3, column: 2, head: 17, rangeCount: 1), forTabID: id)

        // Swap to B (never previewed): isolation — A's state must NOT leak.
        model.openPreview(url: b)
        XCTAssertEqual(model.tabs.previewTabID, id, "same reused preview slot")
        XCTAssertNil(model.editor.editorScrollByTab[id],
                     "B starts clean — A's scroll does not leak (TSK-744)")
        XCTAssertNil(model.editor.editorCursorByTab[id],
                     "B starts clean — A's cursor does not leak (TSK-744)")

        // Return to A: its remembered scroll + cursor must be restored.
        model.openPreview(url: a)
        XCTAssertEqual(model.editor.editorScrollByTab[id]?.top, 500,
                       "returning to A restores A's remembered scroll (TSK-743)")
        XCTAssertEqual(model.editor.editorCursorByTab[id]?.head, 17,
                       "returning to A restores A's remembered cursor (TSK-743)")
    }
}
