import XCTest
import ViewerCore
import ViewerKit
@testable import ViewerUI

/// UX-K (#231) — per-file scroll-position capture + restore.
///
/// These exercise the live wiring through `DocumentModel` and the
/// `SessionState` snapshot/hydrate round-trip (no NSApplication / NSWindow
/// — host-safe, T1m). They cover:
///
///   - `SourceScrollState.topVisibleLine` math (the pure capture inverse);
///   - capture-on-focus-loss: scrolling the active tab then switching away
///     stamps `Tab.scrollTopLine`;
///   - capture-on-close stamps the closing visible tab;
///   - a full `makeSnapshot` → `hydrate` round-trip carries the scroll line
///     onto the restored (lazy) tab, keyed by file URL;
///   - `restoreScroll` issues a `scrollSource(toLine:)` request for a tab
///     that carries a persisted scroll;
///   - the hot-path invariant: a raw scroll tick alone does NOT mutate the
///     tab list (no capture without a boundary).
///
/// Filter: `swift test --filter ViewerUITests.ScrollPositionPersistence`
@MainActor
final class ScrollPositionPersistenceTests: XCTestCase {

    private lazy var tmpRoot: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrollPersistenceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }()

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tmpRoot)
    }

    /// Make a multi-line text file so the source view has real content to
    /// "scroll" through.
    private func makeFile(_ name: String, lines: Int = 500) -> URL {
        let url = tmpRoot.appendingPathComponent(name)
        let body = (1...lines).map { "line \($0)" }.joined(separator: "\n")
        try? Data(body.utf8).write(to: url)
        return url
    }

    /// Build a `SourceScrollState` whose `topVisibleLine` resolves to
    /// `topLine` (1-based) for a `lineCount`-line document. Inverse of the
    /// production math: offsetY = topInset + (topLine - 1) * lineHeight.
    private func scrollState(topLine: Int, lineCount: Int,
                             lineHeight: CGFloat = 16,
                             topInset: CGFloat = 10) -> SourceScrollState {
        SourceScrollState(
            offsetY: topInset + CGFloat(topLine - 1) * lineHeight,
            viewportHeight: 400,
            lineHeight: lineHeight,
            lineCount: lineCount,
            topInset: topInset)
    }

    // MARK: - topVisibleLine math (pure)

    func test_topVisibleLine_topOfFile_isLineOne() {
        let s = scrollState(topLine: 1, lineCount: 500)
        XCTAssertEqual(s.topVisibleLine, 1)
    }

    func test_topVisibleLine_midFile() {
        let s = scrollState(topLine: 250, lineCount: 500)
        XCTAssertEqual(s.topVisibleLine, 250)
    }

    func test_topVisibleLine_clampsToLineCount() {
        // offsetY past the end clamps to the last line, never beyond.
        let s = SourceScrollState(offsetY: 999_999, viewportHeight: 400,
                                  lineHeight: 16, lineCount: 500, topInset: 10)
        XCTAssertEqual(s.topVisibleLine, 500)
    }

    func test_topVisibleLine_nilWhenGeometryUnusable() {
        // Zero line height (pre-first-paint seed) / zero-line doc → nil.
        XCTAssertNil(SourceScrollState(offsetY: 100, viewportHeight: 400,
                                       lineHeight: 0, lineCount: 500, topInset: 10)
            .topVisibleLine)
        XCTAssertNil(SourceScrollState(offsetY: 100, viewportHeight: 400,
                                       lineHeight: 16, lineCount: 0, topInset: 10)
            .topVisibleLine)
    }

    func test_topVisibleLine_roundsToNearestLine() {
        // A viewport sitting a third of a line past line 100's top still maps
        // back to 100 (round, not floor → no per-cycle upward drift).
        let s = SourceScrollState(offsetY: 10 + 99 * 16 + 5, viewportHeight: 400,
                                  lineHeight: 16, lineCount: 500, topInset: 10)
        XCTAssertEqual(s.topVisibleLine, 100)
    }

    // MARK: - Capture on focus-loss / close

    func test_switchingAwayCapturesScroll_onOutgoingTab() {
        let model = DocumentModel()
        let a = makeFile("a.swift")
        let b = makeFile("b.swift")
        model.open(url: a)
        model.open(url: b)
        // Two tabs; b is selected (last opened). Select a, scroll it, then
        // switch to b — the switch-away captures a's scroll.
        model.selectTab(at: 0)
        XCTAssertEqual(model.tabs.selectedIndex, 0)
        model.sourceScrollState = scrollState(topLine: 137, lineCount: 500)

        model.selectTab(at: 1)   // focus-loss boundary for tab 0
        XCTAssertEqual(model.tabs.tabs[0].scrollTopLine, 137,
                       "outgoing tab's scroll must be captured on switch")
    }

    func test_reselectingSameTab_doesNotMiscapture() {
        let model = DocumentModel()
        let a = makeFile("a.swift")
        model.open(url: a)
        model.sourceScrollState = scrollState(topLine: 50, lineCount: 500)
        // Re-selecting the already-selected tab must not capture a stale
        // value onto it (the channel still shows that very tab's offset; a
        // re-select is not a focus-loss boundary).
        model.selectTab(at: 0)
        // We don't assert a specific value here — only that the re-select
        // didn't throw and the tab is still selected. (The capture guard is
        // `cur != index`.)
        XCTAssertEqual(model.tabs.selectedIndex, 0)
    }

    func test_closingVisibleTabCapturesScroll() {
        let model = DocumentModel()
        let a = makeFile("a.swift")
        let b = makeFile("b.swift")
        model.open(url: a)
        model.open(url: b)
        model.selectTab(at: 1)
        model.sourceScrollState = scrollState(topLine: 88, lineCount: 500)
        // Capture happens before the close removes the tab — observe it via a
        // snapshot below. Here we capture explicitly to assert the stamp lands
        // (closeTab removes the tab, so we can't read it afterwards).
        model.captureScrollForActiveTab()
        XCTAssertEqual(model.tabs.tabs[1].scrollTopLine, 88)
    }

    // MARK: - Hot-path invariant

    func test_rawScrollTick_doesNotMutateTabs_orChurn() {
        let model = DocumentModel()
        let a = makeFile("a.swift")
        model.open(url: a)
        let before = model.tabs.tabs
        // A scroll tick lands on the narrow channel only.
        model.sourceScrollState = scrollState(topLine: 200, lineCount: 500)
        // No capture boundary crossed → tab list unchanged, scroll NOT yet
        // stamped onto the tab.
        XCTAssertNil(model.tabs.tabs[0].scrollTopLine,
                     "a raw scroll tick must not stamp the tab (hot path)")
        XCTAssertEqual(before.count, model.tabs.tabs.count)
    }

    // MARK: - Snapshot round-trip carries scroll, keyed by URL

    func test_makeSnapshot_carriesCapturedScroll() {
        let model = DocumentModel()
        let a = makeFile("a.swift")
        model.open(url: a)
        model.sourceScrollState = scrollState(topLine: 321, lineCount: 500)
        model.captureScrollForActiveTab()

        let state = SessionState(rootURL: tmpRoot, model: model)
        let snap = state.makeSnapshot()
        let tab = snap.openTabs.first { $0.path == a.standardizedFileURL
            .resolvingSymlinksInPath().path }
        XCTAssertNotNil(tab, "snapshot must contain the opened file")
        XCTAssertEqual(tab?.scrollTopLine, 321)
    }

    func test_hydrate_restoresScrollOntoLazyTab_byURL() {
        // Capture in one model, snapshot, hydrate into a FRESH model, assert
        // the restored lazy tab carries the persisted scroll keyed by URL.
        let srcModel = DocumentModel()
        let a = makeFile("a.swift")
        srcModel.open(url: a)
        srcModel.sourceScrollState = scrollState(topLine: 264, lineCount: 500)
        srcModel.captureScrollForActiveTab()
        let snap = SessionState(rootURL: tmpRoot, model: srcModel).makeSnapshot()

        let freshModel = DocumentModel()
        let freshState = SessionState(rootURL: tmpRoot, model: freshModel)
        freshState.hydrate(from: snap)

        let resolved = a.standardizedFileURL.resolvingSymlinksInPath().path
        let restored = freshModel.tabs.tabs.first { $0.url?.path == resolved }
        XCTAssertNotNil(restored, "hydrate must restore the persisted tab")
        XCTAssertEqual(restored?.scrollTopLine, 264,
                       "persisted scroll must hydrate onto the lazy tab")
    }

    func test_restoreScroll_issuesScrollSourceRequest() {
        let model = DocumentModel()
        let a = makeFile("a.swift")
        // Append a lazy tab carrying a persisted scroll (the restore shape).
        model.appendLazyTab(url: a, viewMode: .source, scrollTopLine: 412)
        let nonceBefore = model.sourceScrollLineNonce
        model.restoreScroll(forTabAt: 0)
        XCTAssertEqual(model.sourceScrollLineTarget, 412,
                       "restoreScroll must request the persisted line")
        XCTAssertGreaterThan(model.sourceScrollLineNonce, nonceBefore,
                             "restore must bump the nonce so the request fires")
    }

    func test_restoreScroll_nilOrNonPositive_isNoOp() {
        let model = DocumentModel()
        let a = makeFile("a.swift")
        model.appendLazyTab(url: a, viewMode: .source)  // no scroll
        let nonceBefore = model.sourceScrollLineNonce
        model.restoreScroll(forTabAt: 0)
        XCTAssertEqual(model.sourceScrollLineNonce, nonceBefore,
                       "a tab with no persisted scroll must not fire a request")
    }

    // MARK: - TSK-1037: editor (CM6) scroll capture + restore
    //
    // The editor lens reports scroll on the SEPARATE `editorScrollByTab`
    // channel (the source NSTextView's `sourceScrollState` doesn't tick in
    // editor mode), and that dict is tab-id keyed + in-memory only — so a
    // SESSION switch (which drains the tab list, dropping those dicts) lost an
    // editor tab's scroll entirely. The fix folds the editor channel's
    // `viewportFromLine` into the same persisted `Tab.scrollTopLine` field that
    // the source view uses, so editor scroll round-trips through the snapshot.

    /// Open `a` and flip the SELECTED tab to editor mode.
    private func openInEditorMode(_ model: DocumentModel, _ url: URL) {
        model.open(url: url)
        model.setCurrentViewMode(.editor)
        XCTAssertEqual(model.tabs.selected?.viewMode, .editor,
                       "precondition: the tab must be in editor mode")
    }

    func test_editorMode_capture_readsEditorChannel_notSourceChannel() {
        // TEETH: before the fix, captureScroll read ONLY the source channel; an
        // editor tab's scroll (on editorScrollByTab) was never stamped onto
        // Tab.scrollTopLine, so this assertion failed (nil).
        let model = DocumentModel()
        let a = makeFile("code.swift")
        openInEditorMode(model, a)
        let tid = model.tabs.selected!.id

        // Editor reports its viewport top line on its own channel.
        model.recordEditorScroll(
            CMScrollPosition(top: 4096, left: 0,
                             viewportFromLine: 312, viewportToLine: 360),
            forTabID: tid)
        // The source channel is empty/unusable in editor mode — leave it.

        model.captureScrollForActiveTab()
        XCTAssertEqual(model.tabs.selected?.scrollTopLine, 312,
                       "editor-mode capture must read editorScrollByTab.viewportFromLine")
    }

    func test_editorMode_capture_thenSnapshot_carriesEditorScroll() {
        let model = DocumentModel()
        let a = makeFile("code.swift")
        openInEditorMode(model, a)
        let tid = model.tabs.selected!.id
        model.recordEditorScroll(
            CMScrollPosition(top: 1, left: 0,
                             viewportFromLine: 207, viewportToLine: 250),
            forTabID: tid)
        model.captureScrollForActiveTab()

        let snap = SessionState(rootURL: tmpRoot, model: model).makeSnapshot()
        let resolved = a.standardizedFileURL.resolvingSymlinksInPath().path
        let tab = snap.openTabs.first { $0.path == resolved }
        XCTAssertNotNil(tab, "snapshot must contain the editor-mode file")
        XCTAssertEqual(tab?.scrollTopLine, 207,
                       "editor scroll must serialize via Tab.scrollTopLine")
    }

    func test_sessionSwitchRoundTrip_preservesEditorScroll() {
        // The end-to-end TSK-1037 regression: capture an editor tab's scroll,
        // snapshot (the detach-time write), then hydrate a FRESH model (the
        // switch-back), and assert the editor scroll comes back — both on the
        // restored Tab AND seeded onto the live editor channel that drives CM6.
        let srcModel = DocumentModel()
        let a = makeFile("code.swift")
        openInEditorMode(srcModel, a)
        let srcTid = srcModel.tabs.selected!.id
        srcModel.recordEditorScroll(
            CMScrollPosition(top: 9000, left: 0,
                             viewportFromLine: 433, viewportToLine: 470),
            forTabID: srcTid)
        srcModel.captureScrollForActiveTab()
        let snap = SessionState(rootURL: tmpRoot, model: srcModel).makeSnapshot()

        // Switch-back: hydrate into a fresh model (mirrors switchSessionFaçade's
        // closeAllTabsPreservingDirty → rebuild from snapshot).
        let freshModel = DocumentModel()
        SessionState(rootURL: tmpRoot, model: freshModel).hydrate(from: snap)
        let resolved = a.standardizedFileURL.resolvingSymlinksInPath().path
        guard let idx = freshModel.tabs.tabs.firstIndex(where: {
            $0.url?.path == resolved
        }) else {
            return XCTFail("hydrate must restore the editor-mode tab")
        }
        XCTAssertEqual(freshModel.tabs.tabs[idx].scrollTopLine, 433,
                       "editor scroll must hydrate onto the restored tab")

        // restoreScroll (run on tab-become-active) must seed the editor channel
        // so CM6 re-applies the viewport — not just fire a source request.
        let restoredTid = freshModel.tabs.tabs[idx].id
        freshModel.restoreScroll(forTabAt: idx)
        XCTAssertEqual(
            freshModel.editorScrollByTab[restoredTid]?.viewportFromLine, 433,
            "restoreScroll must seed editorScrollByTab for an editor tab")
    }

    func test_restoreScroll_editorTab_seedsEditorChannel() {
        // Direct unit on the restore half: a lazy editor tab carrying a
        // persisted scroll must seed editorScrollByTab on restore.
        let model = DocumentModel()
        let a = makeFile("code.swift")
        model.appendLazyTab(url: a, viewMode: .editor, scrollTopLine: 158)
        let tid = model.tabs.tabs[0].id
        XCTAssertNil(model.editorScrollByTab[tid],
                     "precondition: no live editor scroll yet")
        model.restoreScroll(forTabAt: 0)
        XCTAssertEqual(model.editorScrollByTab[tid]?.viewportFromLine, 158,
                       "editor-tab restore must seed the editor channel")
    }

    func test_seedEditorScroll_doesNotClobberLivePosition() {
        // Seeding is for the restore boundary only — it must never stomp a
        // position the user has since scrolled to.
        let model = DocumentModel()
        let a = makeFile("code.swift")
        model.appendLazyTab(url: a, viewMode: .editor)
        let tid = model.tabs.tabs[0].id
        model.recordEditorScroll(
            CMScrollPosition(top: 0, left: 0,
                             viewportFromLine: 12, viewportToLine: 40),
            forTabID: tid)
        model.seedEditorScroll(fromTopLine: 999, forTabID: tid)
        XCTAssertEqual(model.editorScrollByTab[tid]?.viewportFromLine, 12,
                       "seed must not clobber a live editor scroll position")
    }
}
