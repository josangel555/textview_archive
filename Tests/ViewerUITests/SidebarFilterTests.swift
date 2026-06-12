import XCTest
import SwiftUI
import ViewerCore
@testable import ViewerUI

/// TSK-282 (mode A) — the headless half of the sidebar fuzzy filter:
/// ranking through the ROUTED engine, match-index → glyph mapping, the
/// result cap, empty-query passthrough, and the §2.5 routing pin. The
/// typed-latency / highlight pixels are the live half (the ticket's
/// long-standing live-validation flag).
@MainActor
final class SidebarFilterTests: HeadlessUITestCase {

    private func row(_ name: String, dir: Bool = false) -> SidebarModel.VisibleRow {
        SidebarModel.VisibleRow(
            node: FileNode(
                url: URL(fileURLWithPath: "/tmp/fixture/\(name)"),
                name: name, isDirectory: dir),
            depth: 1)
    }

    func test_ranksAndMapsMatchedIndices() throws {
        let rows = [row("CHANGELOG.md"), row("main.rs"), row("README.md")]
        let out = SidebarFilter.filter(rows, query: "rs")
        // "main.rs" must rank first ('.rs' is a word-boundary suffix hit);
        // its matched indices must point at the 'r' and 's' glyphs.
        let top = try XCTUnwrap(out.first)
        XCTAssertEqual(top.name, "main.rs")
        let chars = Array(top.name)
        XCTAssertEqual(top.matchedIndices.map { String(chars[$0]) }, ["r", "s"],
                       "matched indices must address the matched glyphs")
        // Non-matching rows are dropped entirely.
        XCTAssertFalse(out.contains { $0.name == "CHANGELOG.md" }
                        && out.count == rows.count)
    }

    func test_emptyAndWhitespaceQueries_returnEmpty_treePassthrough() {
        let rows = [row("a.txt"), row("b.txt")]
        XCTAssertEqual(SidebarFilter.filter(rows, query: ""), [])
        XCTAssertEqual(SidebarFilter.filter(rows, query: "   "), [])
    }

    func test_resultCap_bounds_the_list() {
        let rows = (0..<(SidebarFilter.resultCap + 100)).map { row("match-\($0).txt") }
        let out = SidebarFilter.filter(rows, query: "match")
        XCTAssertEqual(out.count, SidebarFilter.resultCap,
                       "the match list must never exceed the render cap")
    }

    func test_directoriesKeepTheirFlag_forActivationSemantics() {
        let rows = [row("src", dir: true), row("src.txt")]
        let out = SidebarFilter.filter(rows, query: "src")
        XCTAssertEqual(out.first { $0.name == "src" }?.isDirectory, true)
        XCTAssertEqual(out.first { $0.name == "src.txt" }?.isDirectory, false)
    }

    /// §2.5 routing pin: fuzzy is a PORTED engine — the filter must go
    /// through the adapter (rust by default), never grow a new direct
    /// consumer of the Swift twin. Source audit, the TSK-561 idiom.
    func test_filterRoutesTheAdapter_notTheSwiftTwin() throws {
        let src = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/ViewerUI/SidebarFilter.swift"),
            encoding: .utf8)
        XCTAssertTrue(src.contains("RustFuzzyAdapter.filterWithMatches"),
                      "SidebarFilter must route the ported engine (TSK-633)")
        XCTAssertFalse(src.contains("FuzzyMatcher.filterWithMatches"),
                       "new feature code must not consume the Swift twin (§2.5)")
    }

    func test_fuzzyHighlight_boldsExactlyTheMatchedGlyphs() {
        let attr = FuzzyHighlight.attributed(
            "main.rs", matchedIndices: [5, 6], size: 12,
            regular: .primary, highlight: .accentColor)
        // Walk the runs: characters 5,6 ('r','s') carry the accent color.
        var idx = 0
        var highlighted: [Int] = []
        var cur = attr.startIndex
        while cur < attr.endIndex {
            let next = attr.characters.index(after: cur)
            if attr[cur..<next].foregroundColor == .accentColor {
                highlighted.append(idx)
            }
            cur = next
            idx += 1
        }
        XCTAssertEqual(highlighted, [5, 6],
                       "exactly the matched glyphs are accent-highlighted")
    }
}
