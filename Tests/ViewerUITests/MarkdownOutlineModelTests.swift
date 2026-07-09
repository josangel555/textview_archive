import XCTest
@testable import ViewerUI
@testable import ViewerCore

/// TSK-1438 — the Markdown outline panel's view-model state machine (host).
/// The pure engine (`OutlineNavigation`) is tested in ViewerCoreTests; this
/// pins the ObservableObject glue: rebuild/clamp, the scroll-highlight no-op
/// guard, filter row indices, keyboard stepping, and click-to-line.
@MainActor
final class MarkdownOutlineModelTests: XCTestCase {

    private let doc = """
    # Intro
    text
    ## Setup
    more
    ## Résumé & Details
    body
    # Appendix
    end
    """

    private func loaded() -> MarkdownOutlineModel {
        let m = MarkdownOutlineModel()
        m.rebuild(fromSource: doc)
        return m
    }

    func test_rebuild_extractsHeadings() {
        let m = loaded()
        XCTAssertEqual(m.headings.map(\.title),
                       ["Intro", "Setup", "Résumé & Details", "Appendix"])
        XCTAssertFalse(m.isEmpty)
    }

    func test_rebuild_clampsStaleCurrentIndex() {
        let m = loaded()
        _ = m.select(index: 3)          // Appendix
        XCTAssertEqual(m.currentIndex, 3)
        m.rebuild(fromSource: "# Only\n")   // shorter doc
        XCTAssertEqual(m.currentIndex, 0, "stale index clamped into the new range")
        m.rebuild(fromSource: "no headings here")
        XCTAssertNil(m.currentIndex, "empty outline drops the selection")
    }

    func test_viewportChanged_followsScroll_withNoOpGuard() {
        let m = loaded()
        // Heading lines: Intro=1, Setup=3, Résumé=5, Appendix=7.
        m.viewportChanged(topLine: 1)
        XCTAssertEqual(m.currentIndex, 0)

        // A tick that stays inside the same section must NOT re-publish.
        var fires = 0
        let c = m.objectWillChange.sink { fires += 1 }
        m.viewportChanged(topLine: 2)          // still inside Intro
        XCTAssertEqual(m.currentIndex, 0)
        XCTAssertEqual(fires, 0, "no-op scroll tick must not churn observers")

        m.viewportChanged(topLine: 5)          // into Résumé
        XCTAssertEqual(m.currentIndex, 2)
        XCTAssertEqual(fires, 1, "a real section change fires once")
        c.cancel()
    }

    func test_visibleRows_filter_preservesOriginalIndex() {
        let m = loaded()
        m.filterQuery = "resume"               // diacritic-insensitive
        let rows = m.visibleRows
        XCTAssertEqual(rows.map(\.index), [2])
        XCTAssertEqual(rows.first?.heading.title, "Résumé & Details")

        m.filterQuery = ""
        XCTAssertEqual(m.visibleRows.count, 4)
    }

    func test_keyboardStepping_returnsJumpLines() {
        let m = loaded()
        XCTAssertEqual(m.selectNext(), 1)      // preamble → Intro (line 1)
        XCTAssertEqual(m.currentIndex, 0)
        XCTAssertEqual(m.selectNext(), 3)      // Setup (line 3)
        XCTAssertEqual(m.selectPrevious(), 1)  // back to Intro
        // Clamp at the ends.
        _ = m.select(index: 3)
        XCTAssertEqual(m.selectNext(), 7, "clamped at last (Appendix line 7)")
    }

    func test_select_returnsLine_andRejectsOutOfRange() {
        let m = loaded()
        XCTAssertEqual(m.select(index: 1), 3)  // Setup
        XCTAssertEqual(m.currentIndex, 1)
        XCTAssertNil(m.select(index: 99))
        XCTAssertEqual(m.currentIndex, 1, "a bad index leaves the selection intact")
    }
}
