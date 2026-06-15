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

    func test_editor_dismiss_keepsQuery_clearsSummary() {
        // TSK-770: dismiss PRESERVES the search text (Cmd+F reopen restores it —
        // "keeping prev text"); only the transient match summary clears. CM6
        // highlights clear by bar visibility (ContentView gates findQuery on
        // isEditorBarPresented), so the preserved query leaves no stale
        // highlights while hidden.
        let f = FindCoordinator()
        f.showEditorBar()
        f.editorQuery = "needle"
        f.setEditorMatchSummary("3/12")
        f.dismissEditorBar()
        XCTAssertFalse(f.isEditorBarPresented)
        XCTAssertEqual(f.editorQuery, "needle", "TSK-770: prior search text survives dismiss")
        XCTAssertEqual(f.editorMatchSummary, "", "the transient match summary still clears")
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

    // MARK: Cross-bar next/prev router (⌘G / ⌥⌘G, TSK-946)

    func test_router_noBarOpen_isNoOp() {
        let f = FindCoordinator()
        XCTAssertFalse(f.isAnyBarPresented)
        let e0 = f.editorNextRequest, r0 = f.renderedNextRequest, s0 = f.sourceNextRequest
        let ep0 = f.editorPrevRequest, rp0 = f.renderedPrevRequest, sp0 = f.sourcePrevRequest
        f.next()
        f.prev()
        // ⌘G with nothing open must not bump any bag.
        XCTAssertEqual(f.editorNextRequest, e0)
        XCTAssertEqual(f.renderedNextRequest, r0)
        XCTAssertEqual(f.sourceNextRequest, s0)
        XCTAssertEqual(f.editorPrevRequest, ep0)
        XCTAssertEqual(f.renderedPrevRequest, rp0)
        XCTAssertEqual(f.sourcePrevRequest, sp0)
    }

    func test_router_editorBarOpen_routesToEditor() {
        let f = FindCoordinator()
        f.showEditorBar()
        let n0 = f.editorNextRequest, p0 = f.editorPrevRequest
        let r0 = f.renderedNextRequest, s0 = f.sourceNextRequest
        f.next()
        f.prev()
        XCTAssertEqual(f.editorNextRequest, n0 &+ 1)
        XCTAssertEqual(f.editorPrevRequest, p0 &+ 1)
        XCTAssertEqual(f.renderedNextRequest, r0, "editor open ⇒ rendered bag untouched")
        XCTAssertEqual(f.sourceNextRequest, s0, "editor open ⇒ source bag untouched")
    }

    func test_router_renderedBarOpen_routesToRendered() {
        let f = FindCoordinator()
        f.showRenderedBar()
        let n0 = f.renderedNextRequest, p0 = f.renderedPrevRequest
        let e0 = f.editorNextRequest, s0 = f.sourceNextRequest
        f.next()
        f.prev()
        XCTAssertEqual(f.renderedNextRequest, n0 &+ 1)
        XCTAssertEqual(f.renderedPrevRequest, p0 &+ 1)
        XCTAssertEqual(f.editorNextRequest, e0)
        XCTAssertEqual(f.sourceNextRequest, s0)
    }

    func test_router_sourceBarOpen_routesToSource() {
        let f = FindCoordinator()
        f.showSourceBar()
        let n0 = f.sourceNextRequest, p0 = f.sourcePrevRequest
        let e0 = f.editorNextRequest, r0 = f.renderedNextRequest
        f.next()
        f.prev()
        XCTAssertEqual(f.sourceNextRequest, n0 &+ 1)
        XCTAssertEqual(f.sourcePrevRequest, p0 &+ 1)
        XCTAssertEqual(f.editorNextRequest, e0)
        XCTAssertEqual(f.renderedNextRequest, r0)
    }

    func test_router_editorWinsWhenMultiplePresented() {
        // Defensive: bars are mutually exclusive in practice, but if more
        // than one flag is set the router must pick deterministically
        // (editor → rendered → source), never bump two bags at once.
        let f = FindCoordinator()
        f.showEditorBar()
        f.showRenderedBar()
        f.showSourceBar()
        let e0 = f.editorNextRequest, r0 = f.renderedNextRequest, s0 = f.sourceNextRequest
        f.next()
        XCTAssertEqual(f.editorNextRequest, e0 &+ 1)
        XCTAssertEqual(f.renderedNextRequest, r0)
        XCTAssertEqual(f.sourceNextRequest, s0)
    }

    func test_isAnyBarPresented_reflectsState() {
        let f = FindCoordinator()
        XCTAssertFalse(f.isAnyBarPresented)
        f.showSourceBar()
        XCTAssertTrue(f.isAnyBarPresented)
        f.dismissSourceBar()
        XCTAssertFalse(f.isAnyBarPresented)
    }
}
