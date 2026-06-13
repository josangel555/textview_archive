import XCTest
import Combine
@testable import ViewerUI

/// Pure-logic state-machine coverage for `FindCoordinator`, mirroring
/// the gold-standard `TabsStateTests` pattern (Quality #E, 2026-05-25).
/// Three independent bags — rendered / source / editor — each with
/// show/dismiss, query state, next/prev/focus nonces, and (source-only)
/// match-set apply rules.
@MainActor
final class FindCoordinatorTests: XCTestCase {

    // MARK: Rendered

    func test_rendered_show_setsPresentedAndBumpsFocus() {
        let f = FindCoordinator()
        let n0 = f.renderedFocusRequest
        f.showRenderedBar()
        XCTAssertTrue(f.isRenderedBarPresented)
        XCTAssertEqual(f.renderedFocusRequest, n0 &+ 1)
    }

    func test_rendered_show_whileAlreadyPresented_bumpsFocusAgain() {
        let f = FindCoordinator()
        f.showRenderedBar()
        let n1 = f.renderedFocusRequest
        f.showRenderedBar()
        XCTAssertTrue(f.isRenderedBarPresented)
        XCTAssertEqual(f.renderedFocusRequest, n1 &+ 1)
    }

    func test_rendered_dismiss_clearsQueryAndMatched() {
        let f = FindCoordinator()
        f.showRenderedBar()
        f.renderedQuery = "needle"
        f.renderedMatched = false
        f.dismissRenderedBar()
        XCTAssertFalse(f.isRenderedBarPresented)
        XCTAssertEqual(f.renderedQuery, "")
        XCTAssertNil(f.renderedMatched)
    }

    func test_rendered_next_andPrev_bumpRequests() {
        let f = FindCoordinator()
        let n0 = f.renderedNextRequest
        let p0 = f.renderedPrevRequest
        f.renderedNext()
        f.renderedNext()
        f.renderedPrev()
        XCTAssertEqual(f.renderedNextRequest, n0 &+ 2)
        XCTAssertEqual(f.renderedPrevRequest, p0 &+ 1)
    }

    func test_rendered_matchSummary_dedupes() async {
        let f = FindCoordinator()
        var count = 0
        let sub = f.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        f.setRenderedMatchSummary("1/3")
        f.setRenderedMatchSummary("1/3")  // dedupe
        f.setRenderedMatchSummary("2/3")
        await Task.yield()
        // 2 publishes (initial set + change to 2/3), the duplicate suppressed
        XCTAssertEqual(count, 2)
    }

    // MARK: Source

    func test_source_show_setsPresentedAndBumpsFocus() {
        let f = FindCoordinator()
        let n0 = f.sourceFocusRequest
        f.showSourceBar()
        XCTAssertTrue(f.isSourceBarPresented)
        XCTAssertEqual(f.sourceFocusRequest, n0 &+ 1)
    }

    func test_source_dismiss_clearsQueryAndMatches() {
        let f = FindCoordinator()
        f.showSourceBar()
        f.sourceQuery = "needle"
        f.setSourceMatchSummary("3/12")
        f.setSourceMatches(lines: [1, 5, 9], currentIndex: 1)
        f.dismissSourceBar()
        XCTAssertFalse(f.isSourceBarPresented)
        XCTAssertEqual(f.sourceQuery, "")
        XCTAssertEqual(f.sourceMatchSummary, "")
        XCTAssertEqual(f.sourceMatchLines, [])
        XCTAssertNil(f.sourceCurrentMatchIndex)
    }

    func test_source_next_andPrev_bumpRequests() {
        let f = FindCoordinator()
        let n0 = f.sourceNextRequest
        let p0 = f.sourcePrevRequest
        f.sourceNext()
        f.sourcePrev()
        f.sourcePrev()
        XCTAssertEqual(f.sourceNextRequest, n0 &+ 1)
        XCTAssertEqual(f.sourcePrevRequest, p0 &+ 2)
    }

    func test_source_matchSet_dedupes_onEqualReapply() async {
        let f = FindCoordinator()
        f.setSourceMatches(lines: [1, 2, 3], currentIndex: 1)
        var count = 0
        let sub = f.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        // identical re-apply: should be silent
        f.setSourceMatches(lines: [1, 2, 3], currentIndex: 1)
        await Task.yield()
        XCTAssertEqual(count, 0,
            "Equal match-set must not republish — apply() runs on every TextDisplayView tick")
    }

    // MARK: Editor (CM6)

    func test_editor_show_setsPresentedAndBumpsFocus() {
        let f = FindCoordinator()
        let n0 = f.editorFocusRequest
        f.showEditorBar()
        XCTAssertTrue(f.isEditorBarPresented)
        XCTAssertEqual(f.editorFocusRequest, n0 &+ 1)
    }

    func test_editor_dismiss_clearsQueryAndSummary() {
        let f = FindCoordinator()
        f.showEditorBar()
        f.editorQuery = "needle"
        f.setEditorMatchSummary("3/12")
        f.dismissEditorBar()
        XCTAssertFalse(f.isEditorBarPresented)
        XCTAssertEqual(f.editorQuery, "")
        XCTAssertEqual(f.editorMatchSummary, "")
    }

    func test_editor_matchSummary_dedupes() async {
        let f = FindCoordinator()
        var count = 0
        let sub = f.objectWillChange.sink { _ in count += 1 }
        defer { sub.cancel() }
        f.setEditorMatchSummary("1/3")
        f.setEditorMatchSummary("1/3")  // dedupe
        await Task.yield()
        XCTAssertEqual(count, 1)
    }

    // MARK: Toggle — Cmd+F second press closes the bar (TSK-739)

    func test_toggleSource_opensWhenHidden_thenClosesOnSecondPress() {
        let f = FindCoordinator()
        XCTAssertFalse(f.isSourceBarPresented)
        f.toggleSourceBar()
        XCTAssertTrue(f.isSourceBarPresented, "first toggle opens")
        f.toggleSourceBar()
        XCTAssertFalse(f.isSourceBarPresented, "second toggle closes (the bug: it used to re-focus, never close)")
    }

    func test_toggleEditor_opensWhenHidden_thenClosesOnSecondPress() {
        let f = FindCoordinator()
        f.toggleEditorBar()
        XCTAssertTrue(f.isEditorBarPresented)
        f.toggleEditorBar()
        XCTAssertFalse(f.isEditorBarPresented)
    }

    func test_toggleRendered_opensWhenHidden_thenClosesOnSecondPress() {
        let f = FindCoordinator()
        f.toggleRenderedBar()
        XCTAssertTrue(f.isRenderedBarPresented)
        f.toggleRenderedBar()
        XCTAssertFalse(f.isRenderedBarPresented)
    }

    func test_toggleSource_whenOpen_dismissesAndClearsQuery() {
        let f = FindCoordinator()
        f.showSourceBar()
        f.sourceQuery = "needle"
        f.toggleSourceBar()
        XCTAssertFalse(f.isSourceBarPresented)
        XCTAssertEqual(f.sourceQuery, "", "toggle-closed goes through dismiss, which clears the query")
    }

    // MARK: Independence — each bag is isolated from the others

    func test_renderedQuery_change_doesNotMutateSourceOrEditor() {
        let f = FindCoordinator()
        f.sourceQuery = "src-query"
        f.editorQuery = "edt-query"
        f.renderedQuery = "rnd-query"
        XCTAssertEqual(f.sourceQuery, "src-query")
        XCTAssertEqual(f.editorQuery, "edt-query")
    }

    func test_sourceMatches_change_doesNotMutateRenderedOrEditor() {
        let f = FindCoordinator()
        f.renderedMatchSummary = "a"
        f.editorMatchSummary = "b"
        f.setSourceMatches(lines: [1], currentIndex: 0)
        XCTAssertEqual(f.renderedMatchSummary, "a")
        XCTAssertEqual(f.editorMatchSummary, "b")
    }
}
