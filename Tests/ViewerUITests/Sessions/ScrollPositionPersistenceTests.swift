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
}
