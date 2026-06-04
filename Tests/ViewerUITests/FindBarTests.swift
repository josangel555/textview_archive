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

    // MARK: - UX-G: editor find-and-replace state

    /// The editor find bar is the only editable surface, so it owns the
    /// replace row state. Cmd+Option+F opens it pre-expanded; Cmd+F
    /// opens it find-only.
    func test_editorReplaceBar_opensExpanded() {
        let model = makeModel()
        XCTAssertFalse(model.isEditorFindBarPresented)
        XCTAssertFalse(model.find.editorReplaceVisible)

        // Plain find: bar visible, replace row collapsed.
        model.showEditorFindBar()
        XCTAssertTrue(model.isEditorFindBarPresented)
        XCTAssertFalse(model.find.editorReplaceVisible)

        // Find & Replace: bar visible AND replace row expanded.
        model.showEditorReplaceBar()
        XCTAssertTrue(model.isEditorFindBarPresented)
        XCTAssertTrue(model.find.editorReplaceVisible)
    }

    /// Replace next/all are command nonces (bump-counter), so a repeated
    /// action always re-fires even with unchanged strings — the same
    /// pattern as find-next/prev.
    func test_editorReplace_requestsAreNonces() {
        let model = makeModel()
        let next0 = model.editorReplaceNextRequest
        let all0 = model.editorReplaceAllRequest

        model.editorReplaceNext()
        model.editorReplaceNext()
        model.editorReplaceAll()

        XCTAssertEqual(model.editorReplaceNextRequest, next0 + 2)
        XCTAssertEqual(model.editorReplaceAllRequest, all0 + 1)
    }

    /// Dismissing the editor bar must clear the replacement string and
    /// collapse the replace row, so a fresh Cmd+F doesn't resurrect a
    /// stale replacement.
    func test_editorReplace_dismissClearsState() {
        let model = makeModel()
        model.showEditorReplaceBar()
        model.editorFindQuery = "foo"
        model.editorFindReplacement = "bar"
        XCTAssertEqual(model.editorFindReplacement, "bar")

        model.dismissEditorFindBar()
        XCTAssertFalse(model.isEditorFindBarPresented)
        XCTAssertEqual(model.editorFindQuery, "")
        XCTAssertEqual(model.editorFindReplacement, "")
        XCTAssertFalse(model.find.editorReplaceVisible)
    }

    /// Read-only surfaces (rendered / source) have no replace state —
    /// guard that no replace plumbing accidentally got wired onto them.
    /// (Compile-time guarantee really; this documents the intent.)
    func test_replace_isEditorOnly() {
        let model = makeModel()
        // The editor coordinator carries replace state.
        model.find.editorReplacement = "x"
        XCTAssertEqual(model.find.editorReplacement, "x")
        // No equivalent exists on the rendered/source bags — verified by
        // the absence of `find.renderedReplacement` / `sourceReplacement`
        // symbols (would fail to compile if referenced).
    }

    // MARK: - G3: match-count / current-position summary ("n of N")

    /// The find bar shows "current/total" so the user knows which of N
    /// matches they're on. `summarize` is the pure-logic source of that
    /// string (consumed by `FindBar`'s `.countOnly` mode). 1-based.
    func test_summarize_currentPositionAndTotal() {
        // First of three.
        XCTAssertEqual(TextDisplayView.summarize(matchCount: 3, current: 0), "1/3")
        // Third of twelve — the "3 of 12" UAT example.
        XCTAssertEqual(TextDisplayView.summarize(matchCount: 12, current: 2), "3/12")
        // Last of N.
        XCTAssertEqual(TextDisplayView.summarize(matchCount: 5, current: 4), "5/5")
    }

    /// Empty string when there are no matches or no current index, so
    /// the bar falls through to its "No results"/blank rendering rather
    /// than printing a nonsensical "0/0" or "1/0".
    func test_summarize_emptyWhenNoMatches() {
        XCTAssertEqual(TextDisplayView.summarize(matchCount: 0, current: nil), "")
        XCTAssertEqual(TextDisplayView.summarize(matchCount: 0, current: 0), "")
        XCTAssertEqual(TextDisplayView.summarize(matchCount: 4, current: nil), "")
    }

    // MARK: - G2: find-match highlight color is a tuned bright blue

    /// The find highlight must be a tuned bright blue (≈ #1E6FFF),
    /// NOT pure blue (#0000FF) which is too dark/saturated to read text
    /// through. Pin the sRGB components so a regression back to pure
    /// blue (or the old pink/purple) is caught headlessly.
    func test_findHighlightColor_isTunedBrightBlue_notPureBlue() throws {
        let base = try XCTUnwrap(
            Palette.findHighlightBlueColor.usingColorSpace(.sRGB)
        )
        // Blue channel is fully on; red is low-but-nonzero and green is
        // a clear mid value — this is the #1E6FFF tone, distinct from
        // pure blue (r==0, g==0).
        XCTAssertEqual(base.blueComponent, 1.0, accuracy: 0.001)
        XCTAssertEqual(base.redComponent, 0.118, accuracy: 0.01)
        XCTAssertEqual(base.greenComponent, 0.435, accuracy: 0.01)
        // Guard against a pure-blue regression explicitly.
        XCTAssertGreaterThan(base.greenComponent, 0.2,
            "green channel collapsed — find highlight regressed toward pure blue")
        XCTAssertGreaterThan(base.redComponent, 0.05,
            "red channel collapsed — find highlight regressed toward pure blue")
    }

    /// The current match must read stronger than a non-current match so
    /// the active hit pops against the field of other matches.
    func test_findHighlightColor_currentIsStrongerThanInactive() throws {
        let current = try XCTUnwrap(
            Palette.findHighlightCurrent.usingColorSpace(.sRGB))
        let inactive = try XCTUnwrap(
            Palette.findHighlightInactive.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(current.alphaComponent, inactive.alphaComponent)
        // Both are washes (translucent) so text reads through them.
        XCTAssertLessThan(current.alphaComponent, 1.0)
        XCTAssertGreaterThan(inactive.alphaComponent, 0.0)
    }
}
