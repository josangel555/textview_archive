import XCTest
@testable import ViewerCore

/// TSK-705 (slice 1) — the pure snippet-expansion parser. Pins the TextMate/LSP
/// placeholder syntax, the inserted plain text, the tab-stop visit order, and
/// the UTF-16 stop offsets the editor will use to place carets.
final class SnippetExpansionTests: XCTestCase {

    func test_plainLiteral_noStops() {
        let p = SnippetExpansion.parse("hello world")
        XCTAssertEqual(p.segments, [.literal("hello world")])
        XCTAssertEqual(p.plainText, "hello world")
        XCTAssertTrue(p.tabStopOrder.isEmpty)
    }

    func test_bareTabStops_fillEmpty() {
        let p = SnippetExpansion.parse("a$1b$2c")
        XCTAssertEqual(p.segments, [
            .literal("a"), .placeholder(index: 1, defaultText: ""),
            .literal("b"), .placeholder(index: 2, defaultText: ""),
            .literal("c"),
        ])
        XCTAssertEqual(p.plainText, "abc")
        XCTAssertEqual(p.tabStopOrder, [1, 2])
    }

    func test_placeholdersWithDefaults() {
        let p = SnippetExpansion.parse("for ${1:item} in ${2:items}:")
        XCTAssertEqual(p.plainText, "for item in items:")
        XCTAssertEqual(p.tabStopOrder, [1, 2])
        let stops = p.stops()
        // "for " = 4 → item@4(len4); " in " → items@12(len5).
        let s1 = stops.first { $0.index == 1 }!
        XCTAssertEqual(s1.offset, 4); XCTAssertEqual(s1.length, 4)
        let s2 = stops.first { $0.index == 2 }!
        XCTAssertEqual(s2.offset, 12); XCTAssertEqual(s2.length, 5)
    }

    func test_finalStopZero_visitedLast() {
        let p = SnippetExpansion.parse("$0 head $1 mid $2 tail")
        // 0 appears first in the body but must be visited LAST.
        XCTAssertEqual(p.tabStopOrder, [1, 2, 0])
    }

    func test_bracedNoDefault() {
        let p = SnippetExpansion.parse("x${1}y")
        XCTAssertEqual(p.segments, [
            .literal("x"), .placeholder(index: 1, defaultText: ""), .literal("y"),
        ])
        XCTAssertEqual(p.plainText, "xy")
    }

    func test_escapedDollar_isLiteral() {
        let p = SnippetExpansion.parse("price: \\$1.00")
        XCTAssertEqual(p.plainText, "price: $1.00", "escaped \\$ is a literal dollar, not a tab stop")
        XCTAssertTrue(p.tabStopOrder.isEmpty)
    }

    func test_escapedBraceInDefault() {
        let p = SnippetExpansion.parse("${1:a\\}b}")
        XCTAssertEqual(p.segments, [.placeholder(index: 1, defaultText: "a}b")])
        XCTAssertEqual(p.plainText, "a}b")
    }

    func test_loneDollar_keptLiteral() {
        let p = SnippetExpansion.parse("cost is $ and $x")
        XCTAssertEqual(p.plainText, "cost is $ and $x", "a lone $ / $-non-digit stays literal")
        XCTAssertTrue(p.tabStopOrder.isEmpty)
    }

    func test_unterminatedBrace_keptLiteral() {
        let p = SnippetExpansion.parse("${1:oops")
        XCTAssertEqual(p.plainText, "${1:oops", "an unterminated ${…} is not lost")
    }

    func test_repeatedIndex_orderHasNoDupes() {
        let p = SnippetExpansion.parse("$1 and ${1:x} again")
        XCTAssertEqual(p.tabStopOrder, [1], "a repeated tab-stop index appears once in the order")
        // Both occurrences still produce stops() entries (the editor mirrors them).
        XCTAssertEqual(p.stops().filter { $0.index == 1 }.count, 2)
    }

    func test_stops_utf16Offsets_withMultibyte() {
        // "é" is one UTF-16 unit; "🎉" is two. Offsets must be UTF-16, not Character.
        let p = SnippetExpansion.parse("é🎉$1")
        let s = p.stops().first { $0.index == 1 }!
        XCTAssertEqual(s.offset, 3, "é(1) + 🎉(2) = 3 UTF-16 units before the stop")
    }
}
