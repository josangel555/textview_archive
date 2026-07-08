import XCTest
@testable import ViewerCore

/// TSK-1438 — the outline panel's navigation model.
final class OutlineNavigationTests: XCTestCase {

    private let headings = [
        MarkdownHeading(level: 1, title: "Intro", line: 5),
        MarkdownHeading(level: 2, title: "Setup", line: 20),
        MarkdownHeading(level: 2, title: "Résumé & Details", line: 40),
        MarkdownHeading(level: 1, title: "Appendix", line: 100),
    ]

    // MARK: current section on scroll

    func test_currentSection_preamble_isNil() {
        XCTAssertNil(OutlineNavigation.currentHeadingIndex(topLine: 1, headings: headings))
        XCTAssertNil(OutlineNavigation.currentHeadingIndex(topLine: 4, headings: headings))
    }

    func test_currentSection_exactHeadingLine_andBetween() {
        XCTAssertEqual(OutlineNavigation.currentHeadingIndex(topLine: 5, headings: headings), 0,
                       "on the heading line itself → that section")
        XCTAssertEqual(OutlineNavigation.currentHeadingIndex(topLine: 19, headings: headings), 0)
        XCTAssertEqual(OutlineNavigation.currentHeadingIndex(topLine: 20, headings: headings), 1)
        XCTAssertEqual(OutlineNavigation.currentHeadingIndex(topLine: 99, headings: headings), 2)
        XCTAssertEqual(OutlineNavigation.currentHeadingIndex(topLine: 5000, headings: headings), 3,
                       "past the last heading → the last section")
    }

    func test_currentSection_emptyOutline() {
        XCTAssertNil(OutlineNavigation.currentHeadingIndex(topLine: 10, headings: []))
    }

    // MARK: keyboard stepping

    func test_next_entersAtFirst_stepsAndClamps() {
        XCTAssertEqual(OutlineNavigation.nextIndex(from: nil, count: 4), 0,
                       "↓ from the preamble enters the first heading")
        XCTAssertEqual(OutlineNavigation.nextIndex(from: 0, count: 4), 1)
        XCTAssertEqual(OutlineNavigation.nextIndex(from: 3, count: 4), 3, "clamped at the last")
        XCTAssertNil(OutlineNavigation.nextIndex(from: nil, count: 0), "no headings → nil")
    }

    func test_previous_stepsAndClamps() {
        XCTAssertEqual(OutlineNavigation.previousIndex(from: 2, count: 4), 1)
        XCTAssertEqual(OutlineNavigation.previousIndex(from: 0, count: 4), 0, "clamped at the first")
        XCTAssertNil(OutlineNavigation.previousIndex(from: nil, count: 4),
                     "↑ from the preamble stays in the preamble")
    }

    // MARK: filter box

    func test_filter_matchesCaseAndDiacriticInsensitive_preservesIndices() {
        let hits = OutlineNavigation.filter("resume", headings: headings)
        XCTAssertEqual(hits.map(\.index), [2], "Résumé matches 'resume' (diacritic-folded)")
        let se = OutlineNavigation.filter("SET", headings: headings)
        XCTAssertEqual(se.map(\.heading.title), ["Setup"])
        XCTAssertEqual(se.map(\.index), [1], "original index kept — the click still jumps right")
    }

    func test_filter_blankReturnsAll_noMatchReturnsEmpty() {
        XCTAssertEqual(OutlineNavigation.filter("  ", headings: headings).count, 4)
        XCTAssertTrue(OutlineNavigation.filter("zzz", headings: headings).isEmpty)
    }
}
