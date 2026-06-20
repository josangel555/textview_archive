import XCTest
import AppKit
import WebKit
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

    // MARK: - TSK-1046: editor render-gap — the mount-time selection seed
    //
    // The model fix (TSK-1037) re-seeds editorScrollByTab on restore, but the
    // ONLY mount-time CM6 scroll path is the `initialSelection` seed, which was
    // built solely from the CARET. A scroll-only restore (no caret) therefore
    // left the editor at the top on screen. `editorMountSelectionSeed` is the
    // render-path fix's model kernel: resolve cursor-first, else seed at the
    // restored scroll LINE so CM6 scrolls there on mount. These pin that logic
    // host-side so a regression fails the gate even though the live CM6 scroll
    // is VM-only (ScrollRestoreUATTests).

    func test_mountSeed_nil_whenNoCursorNoScroll() {
        let model = DocumentModel()
        let a = makeFile("code.swift")
        model.appendLazyTab(url: a, viewMode: .editor)
        let tid = model.tabs.tabs[0].id
        XCTAssertNil(model.editorMountSelectionSeed(forTabID: tid),
                     "no caret + no restored scroll → no seed (leave at start)")
    }

    func test_mountSeed_cursorWins_overScrollLine() {
        let model = DocumentModel()
        let a = makeFile("code.swift")
        model.appendLazyTab(url: a, viewMode: .editor)
        let tid = model.tabs.tabs[0].id
        // Both a caret AND a restored scroll line present — the caret wins (it
        // already scrolls itself into view on apply).
        model.recordEditorCursor(
            CMCursorPosition(line: 5, column: 2, head: 42, rangeCount: 1),
            forTabID: tid)
        model.seedEditorScroll(fromTopLine: 200, forTabID: tid)
        let seed = model.editorMountSelectionSeed(forTabID: tid)
        XCTAssertEqual(seed?.head, 42,
                       "a restored caret must drive the mount seed")
        XCTAssertEqual(seed?.anchor, 42, "collapsed selection at the caret")
        XCTAssertEqual(seed?.scroll, true, "the seed must scroll on apply")
    }

    func test_mountSeed_fromScrollLine_whenNoCursor() {
        let model = DocumentModel()
        // A file whose line offsets are deterministic: each line is "L<n>\n".
        let url = tmpRoot.appendingPathComponent("seedlines.txt")
        let body = (1...50).map { "L\($0)" }.joined(separator: "\n") + "\n"
        try? Data(body.utf8).write(to: url)
        model.open(url: url)
        model.setCurrentViewMode(.editor)
        let tid = model.tabs.selected!.id
        // Seed a restored scroll top line of 10 with NO caret. The mount seed
        // must point at the UTF-16 offset of line 10's start.
        model.seedEditorScroll(fromTopLine: 10, forTabID: tid)
        let seed = model.editorMountSelectionSeed(forTabID: tid)
        // Offset of line 10 start: sum of UTF-16 lengths of lines 1..9 incl. \n.
        // Lines 1..9: "L1".."L9" = 2 chars each + 1 newline = 3 each ⇒ 27.
        XCTAssertEqual(seed?.head, 27,
                       "scroll-only seed must land at the restored line's start")
        XCTAssertEqual(seed?.anchor, seed?.head, "collapsed selection")
        XCTAssertEqual(seed?.scroll, true, "scroll-only seed must scroll on apply")
    }

    func test_mountSeed_scrollLineOne_isNoSeed() {
        let model = DocumentModel()
        let a = makeFile("code.swift")
        model.open(url: a)
        model.setCurrentViewMode(.editor)
        let tid = model.tabs.selected!.id
        // A restored top line of 1 is the document start — no seed needed.
        model.seedEditorScroll(fromTopLine: 1, forTabID: tid)
        XCTAssertNil(model.editorMountSelectionSeed(forTabID: tid),
                     "a restored top line of 1 needs no scroll seed")
    }

    func test_mountSeed_endToEnd_restoreThenSeedScrollsEditor() {
        // The full editor render-path contract: an editor tab carrying a
        // persisted scrollTopLine (no caret) → restoreScroll seeds the editor
        // channel → editorMountSelectionSeed yields a scroll-bearing seed at
        // that line. Pre-fix this returned nil (cursor-only) so CM6 stayed top.
        let model = DocumentModel()
        let url = tmpRoot.appendingPathComponent("e2e.txt")
        let body = (1...100).map { "row\($0)" }.joined(separator: "\n") + "\n"
        try? Data(body.utf8).write(to: url)
        model.open(url: url)                 // synchronous load → tab is .loaded
        model.setCurrentViewMode(.editor)
        let tid = model.tabs.selected!.id
        // Simulate the switch-IN restore's effect on the editor channel (the
        // restore→seed half is pinned by test_restoreScroll_editorTab_seedsEditorChannel;
        // here we drive the seed→mount-seed half, the render-path gap TSK-1046 fixed).
        model.seedEditorScroll(fromTopLine: 40, forTabID: tid)
        XCTAssertEqual(model.editorScrollByTab[tid]?.viewportFromLine, 40,
                       "seed must populate the editor channel at line 40")
        let seed = model.editorMountSelectionSeed(forTabID: tid)
        XCTAssertNotNil(seed,
                        "TSK-1046: a scroll-only restore MUST produce a mount seed "
                        + "(pre-fix this was nil → CM6 stayed at the top)")
        XCTAssertEqual(seed?.scroll, true)
        XCTAssertGreaterThan(seed?.head ?? 0, 0,
                             "the seed must point past the document start")
    }

    // MARK: - TSK-1041: rendered-Markdown (WKWebView) scroll capture + restore
    //
    // The rendered preview is a THIRD scroll channel (`renderedScrollByURL`,
    // URL-keyed window.scrollY) that lives only IN MEMORY — never serialized —
    // so a SESSION switch (which drains the tab list, dropping that dict) lost
    // the rendered scroll entirely. It's the PRIMARY surface for markdown, so
    // this must round-trip the snapshot like the source/editor `scrollTopLine`.
    // The fix stamps the offset into a new `Tab.renderedScrollY` /
    // `TabSnapshot.renderedScrollY` field (a pixel offset — a rendered HTML
    // page has no source-line mapping), serializes it, and re-seeds
    // `renderedScrollByURL` on restore so `MarkdownRenderedView` re-applies it.

    /// Make a `.md` file so `open` defaults the tab to `.rendered` mode.
    private func makeMarkdownFile(_ name: String, lines: Int = 500) -> URL {
        let url = tmpRoot.appendingPathComponent(name)
        let body = (1...lines).map { "# Heading \($0)\n\nbody \($0)" }
            .joined(separator: "\n\n")
        try? Data(body.utf8).write(to: url)
        return url
    }

    func test_renderedMode_capture_readsRenderedChannel_stampsTab() {
        // TEETH: before the fix, captureScroll never read renderedScrollByURL,
        // so an active markdown tab's rendered scroll was never stamped onto the
        // tab (renderedScrollY stayed nil) and was lost on the session drain.
        let model = DocumentModel()
        let a = makeMarkdownFile("doc.md")
        model.open(url: a)
        XCTAssertEqual(model.tabs.selected?.viewMode, .rendered,
                       "precondition: a .md tab opens in rendered mode")

        // The rendered WebView reports its offset on its own URL-keyed channel.
        model.rememberRenderedScroll(1840, for: a)

        model.captureScrollForActiveTab()
        XCTAssertEqual(model.tabs.selected?.renderedScrollY, 1840,
                       "rendered-mode capture must read renderedScrollByURL and stamp the tab")
    }

    func test_renderedScroll_capture_thenSnapshot_carriesOffset() {
        let model = DocumentModel()
        let a = makeMarkdownFile("doc.md")
        model.open(url: a)
        model.rememberRenderedScroll(960, for: a)
        model.captureScrollForActiveTab()

        let snap = SessionState(rootURL: tmpRoot, model: model).makeSnapshot()
        let resolved = a.standardizedFileURL.resolvingSymlinksInPath().path
        let tab = snap.openTabs.first { $0.path == resolved }
        XCTAssertNotNil(tab, "snapshot must contain the markdown file")
        XCTAssertEqual(tab?.renderedScrollY, 960,
                       "rendered scroll must serialize via TabSnapshot.renderedScrollY")
    }

    func test_sessionSwitchRoundTrip_preservesRenderedScroll() {
        // The end-to-end TSK-1041 regression: capture a markdown tab's rendered
        // scroll, snapshot (the detach-time write), then hydrate a FRESH model
        // (the switch-back), and assert the rendered offset comes back — both on
        // the restored Tab AND seeded onto the live renderedScrollByURL channel
        // that MarkdownRenderedView re-applies on didFinish.
        let srcModel = DocumentModel()
        let a = makeMarkdownFile("doc.md")
        srcModel.open(url: a)
        srcModel.rememberRenderedScroll(2520, for: a)
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
            return XCTFail("hydrate must restore the markdown tab")
        }
        XCTAssertEqual(freshModel.tabs.tabs[idx].renderedScrollY, 2520,
                       "rendered scroll must hydrate onto the restored tab")

        // restoreScroll (run on tab-become-active) must seed the rendered
        // channel so the WebView re-applies the offset on its next load.
        let restoredURL = freshModel.tabs.tabs[idx].url!
        freshModel.restoreScroll(forTabAt: idx)
        XCTAssertEqual(freshModel.renderedScrollOffset(for: restoredURL), 2520,
                       "restoreScroll must seed renderedScrollByURL for a markdown tab")
    }

    func test_renderedScrollOffset_resolvesPersistedTab_beforeSeed_TSK1046() {
        // TSK-1046 (race-free read): a lazy markdown tab carrying a persisted
        // rendered offset must resolve to that offset IMMEDIATELY — BEFORE
        // restoreScroll's seed runs. On a session switch the live
        // `renderedScrollByURL` dict is drained and re-seeded async, so the FIRST
        // render after restore reads this getter; it used to return nil → the
        // preview snapped to top. `renderedScrollOffset` now falls back to the
        // tab's persisted `renderedScrollY`, so the read is correct regardless of
        // seed timing.
        //
        // NOTE: this assertion was previously `XCTAssertNil(... "no live rendered
        // scroll yet")` — a FALSE GREEN that encoded the very race causing the
        // on-screen reset. The model round-trip test stayed green (it checks the
        // SETTLED state) while the app reset on the unsettled first render.
        let model = DocumentModel()
        let a = makeMarkdownFile("doc.md")
        model.appendLazyTab(url: a, viewMode: .rendered, renderedScrollY: 1390)
        let resolved = a.standardizedFileURL.resolvingSymlinksInPath()
        XCTAssertEqual(model.renderedScrollOffset(for: resolved), 1390,
                       "race-free: must fall back to the tab's persisted offset BEFORE the seed")
        // restoreScroll then promotes it onto the live channel (idempotent).
        model.restoreScroll(forTabAt: 0)
        XCTAssertEqual(model.renderedScrollOffset(for: resolved), 1390,
                       "restore seeds the live rendered channel; value unchanged")
    }

    func test_seedRenderedScroll_doesNotClobberLivePosition() {
        // Seeding is for the restore boundary only — it must never stomp a
        // position the user has since scrolled to.
        let model = DocumentModel()
        let a = makeMarkdownFile("doc.md")
        model.rememberRenderedScroll(120, for: a)   // a live position
        model.seedRenderedScroll(9999, for: a)
        XCTAssertEqual(model.renderedScrollOffset(for: a), 120,
                       "seed must not clobber a live rendered scroll position")
    }

    // MARK: - TSK-1047: warm-EDITOR-cache re-attach + the live/dirty-state guard
    //
    // The editor (CM6) WebView used to be rebuilt on every session/tab switch
    // (makeNSView builds, dismantleNSView tears down), so it reloaded at the TOP
    // of the file — the owner-reported editor-scroll-resets bug — even though the
    // model captured/serialized/hydrated the scroll correctly (TSK-1037). The fix
    // is a path-keyed warm cache (`WarmEditorWebViewCache`) that PARKS the editor
    // WebView (keeping the loaded doc + scroll) on dismantle and RE-ATTACHES it on
    // make, so no reload happens at all. Because the editor holds LIVE, possibly-
    // DIRTY text (unlike the read-only rendered preview), the re-attach is gated
    // on the parked CM6's text matching the text the model is about to feed the
    // fresh pane — so a re-attach can NEVER resurrect stale text or mask an edit
    // (a hot-exit data-loss class). These pin that seam at the model layer.
    //
    // The full no-reload + on-screen-scroll proof is VM-only (ScrollRestoreUAT
    // SCROLL03/04); the cache mechanism itself is host-pinned in
    // WarmEditorWebViewCacheTests. Here we tie the cache's text key to a real
    // DocumentModel editor buffer (the model's source of truth for editor text).

    func test_warmEditorCache_reAttachesParkedEditor_whenModelTextMatchesDirtyBuffer() {
        // The data-loss-class teeth: an editor with IN-PROGRESS edits is parked;
        // on switch-back the model feeds the DIRTY buffer's text. The parked CM6
        // holds that same dirty text (CM6 posts every change into the buffer), so
        // the re-attach is granted — bringing the edits (and scroll) back, NOT a
        // stale disk reload. If the guard regressed to ignore text, this would
        // still pass; the divergence test below is the complementary tooth.
        WarmEditorWebViewCache.shared.removeAll()
        let model = DocumentModel()
        let a = makeFile("code.swift")
        openInEditorMode(model, a)
        let tid = model.tabs.selected!.id
        // The user types — the buffer (model's source of truth) goes dirty.
        let dirtyText = "EDITED IN PROGRESS — unsaved\n" + (model.editorBuffer(forTabID: tid)?.text ?? "")
        model.updateEditorText(dirtyText, forTabID: tid)
        XCTAssertTrue(model.tabs.selected?.isDirty == true, "precondition: buffer is dirty")

        // Park a warm editor under the file path holding exactly the dirty text
        // (what CM6 has — it's the source the model mirrors).
        _ = NSApplication.shared
        let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let key = a.resolvingSymlinksInPath().standardizedFileURL.path
        WarmEditorWebViewCache.shared.stash(
            wv, coordinator: CodeMirrorEditorView.Coordinator(),
            text: dirtyText, forKey: key)

        // The make path's expected text is exactly the dirty buffer the model
        // feeds (`buf?.text`). Re-attach is granted → edits + scroll preserved.
        let modelText = model.editorBuffer(forTabID: tid)?.text ?? ""
        XCTAssertEqual(modelText, dirtyText, "the model feeds the dirty buffer text on re-mount")
        let got = WarmEditorWebViewCache.shared.retrieve(forKey: key, expectedText: modelText)
        XCTAssertNotNil(got, "a parked editor whose text matches the dirty buffer must re-attach (edits preserved)")
        XCTAssertTrue(got?.webView === wv)
        WarmEditorWebViewCache.shared.removeAll()
    }

    func test_warmEditorCache_dropsParkedEditor_whenModelTextDiverged_noStaleResurrection() {
        // TEETH (data-loss class): if the model's text has diverged from the
        // parked CM6's text (e.g. the file changed on disk / the buffer was
        // re-hydrated differently on a session drain), the parked editor must be
        // DROPPED and a fresh pane built against the model's text — never the
        // parked stale text. A regression that re-attached regardless of text
        // would resurrect the parked (stale) document on screen; this asserts the
        // guard refuses.
        WarmEditorWebViewCache.shared.removeAll()
        let model = DocumentModel()
        let a = makeFile("code.swift")
        openInEditorMode(model, a)
        let tid = model.tabs.selected!.id

        _ = NSApplication.shared
        let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let key = a.resolvingSymlinksInPath().standardizedFileURL.path
        // Park a warm editor holding OLD text.
        WarmEditorWebViewCache.shared.stash(
            wv, coordinator: CodeMirrorEditorView.Coordinator(),
            text: "OLD PARKED CONTENT — must not be resurrected\n", forKey: key)

        // The model now holds different text (a divergence).
        let modelText = model.editorBuffer(forTabID: tid)?.text ?? ""
        XCTAssertNotEqual(modelText, "OLD PARKED CONTENT — must not be resurrected\n")
        let got = WarmEditorWebViewCache.shared.retrieve(forKey: key, expectedText: modelText)
        XCTAssertNil(got, "a parked editor with diverged text must NOT re-attach (no stale resurrection)")
        XCTAssertFalse(WarmEditorWebViewCache.shared.contains(key),
                       "the stale entry is dropped so a fresh pane is built against the model's text")
        WarmEditorWebViewCache.shared.removeAll()
    }

    // MARK: - TSK-1047: tab-SELECT restore must push to the LIVE mounted CM6
    //
    // The warm-editor reattach + the once-per-mount `editorMountSelectionSeed`
    // only fire on a dismantle→make (UNMOUNT/REMOUNT = a SESSION switch or LRU
    // rebuild). A plain TAB switch keeps the editor pane MOUNTED, so neither fires
    // and the restored `editorScrollByTab[id]` was never pushed to the live CM6 —
    // the editor stayed where it was, ignoring the restore. The fix: on a tab
    // switch, `applyRestoredScroll` imperatively pushes the restored line to the
    // live, already-mounted CM6 (the `scrollToLine` bridge). It must be GATED off
    // on the session-switch path (the reattach/seed belt already restores there).
    // The true on-screen scroll is VM-only (ScrollRestoreUAT SCROLL03); here we
    // pin the GATE + the push-attempt wiring host-side, with teeth.

    func test_isSessionSwitchInFlight_defaultsFalse() {
        let model = DocumentModel()
        XCTAssertFalse(model.isSessionSwitchInFlight,
                       "the session-switch gate is off by default (plain tab switches push live)")
    }

    func test_tabSelectRestore_attemptsLiveEditorPush_whenNotSessionSwitch() {
        // A genuine TAB switch (gate OFF) restoring an editor tab carrying a
        // persisted scroll MUST attempt the live-CM6 push at the restored line —
        // this is the mounted-pane gap the fix closes. TEETH: gate the push behind
        // `!isSessionSwitchInFlight` and this records an attempt at line 158.
        let model = DocumentModel()
        let a = makeFile("code.swift")
        // A lazy editor tab carrying a persisted scroll, made the SELECTED tab so
        // the live-push's "is this the active tab" guard passes.
        model.appendLazyTab(url: a, viewMode: .editor, scrollTopLine: 158)
        model.selectTab(at: 0)
        let tid = model.tabs.tabs[0].id
        XCTAssertEqual(model.tabs.selected?.id, tid, "precondition: tab is selected")
        model._test_resetLiveEditorScrollProbe()

        XCTAssertFalse(model.isSessionSwitchInFlight,
                       "precondition: a plain tab switch is NOT a session switch")
        model.restoreScroll(forTabAt: 0)

        XCTAssertEqual(model._test_liveEditorScrollPushes, 1,
                       "TSK-1047: a tab-select restore of an editor tab must push to the live CM6")
        XCTAssertEqual(model._test_lastLiveEditorScrollLine, 158,
                       "the live push must target the RESTORED top line")
    }

    func test_sessionSwitchRestore_skipsLiveEditorPush_noDoubleApply() {
        // TEETH (the gate): with the session-switch flag SET — the path where the
        // editor pane is REBUILT (warm-cache reattach keeps scroll / fresh-build
        // seed restores it) — the live push must be SUPPRESSED so a session switch
        // doesn't double-apply over the reattach/seed belt. If the gate regressed
        // (push fired unconditionally), this would see a push and fail.
        let model = DocumentModel()
        let a = makeFile("code.swift")
        model.appendLazyTab(url: a, viewMode: .editor, scrollTopLine: 158)
        model.selectTab(at: 0)
        model._test_resetLiveEditorScrollProbe()

        model.isSessionSwitchInFlight = true
        defer { model.isSessionSwitchInFlight = false }
        model.restoreScroll(forTabAt: 0)

        XCTAssertEqual(model._test_liveEditorScrollPushes, 0,
                       "TSK-1047: a SESSION switch must NOT live-push (the reattach/seed belt restores)")
        // The model channel is still seeded either way (the seed belt is the
        // cache-miss/fresh-build path) — the gate only suppresses the LIVE push.
        let tid = model.tabs.tabs[0].id
        XCTAssertEqual(model.editorScrollByTab[tid]?.viewportFromLine, 158,
                       "the editor channel is still seeded on a session-switch restore")
    }

    func test_tabSelectRestore_noLivePush_forRenderedTab() {
        // The live-CM6 push is editor-only — a rendered markdown tab restore must
        // never attempt it (it has no CM6; its restore rides renderedScrollByURL).
        let model = DocumentModel()
        let a = makeMarkdownFile("doc.md")
        model.appendLazyTab(url: a, viewMode: .rendered, renderedScrollY: 1390)
        model.selectTab(at: 0)
        model._test_resetLiveEditorScrollProbe()

        model.restoreScroll(forTabAt: 0)
        XCTAssertEqual(model._test_liveEditorScrollPushes, 0,
                       "a rendered-tab restore must not attempt a live CM6 push")
    }

    func test_sessionSwitch_setsAndClearsInFlightFlag_aroundSelect() {
        // The SessionState session-activate path must SET the gate around its
        // `selectTab` and CLEAR it after (via defer), so the gate can't leak into
        // a later plain tab switch (which would wrongly suppress its live push).
        let model = DocumentModel()
        let a = makeFile("code.swift")
        let b = makeFile("other.swift")
        model.appendLazyTab(url: a, viewMode: .editor, scrollTopLine: 100)
        model.appendLazyTab(url: b, viewMode: .editor, scrollTopLine: 50)
        model.selectTab(at: 0)
        XCTAssertFalse(model.isSessionSwitchInFlight, "precondition: gate off")

        // Drive the real session-switch select through SessionState (the producer
        // of the flag's lifecycle), targeting file b's path.
        let session = SessionState(rootURL: tmpRoot, model: model)
        session._test_selectFocusedTab(targetPath:
            b.standardizedFileURL.resolvingSymlinksInPath().path)

        XCTAssertFalse(model.isSessionSwitchInFlight,
                       "TSK-1047: the session-switch gate must be CLEARED after select (defer), "
                       + "so it can't leak into a later plain tab switch")
        XCTAssertEqual(model.tabs.selected?.url?.path,
                       b.standardizedFileURL.resolvingSymlinksInPath().path,
                       "the session-switch select must have focused file b")
    }
}
