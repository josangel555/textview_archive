import XCTest
@testable import ViewerCore

/// `MarkdownOutline.documentSymbols` (TSK-637): heading levels become the
/// LSP symbol tree the sidebar OUTLINE panel renders — markdown gets an
/// outline without an LSP server.
final class MarkdownOutlineSymbolsTests: XCTestCase {

    func test_levels_nest_into_a_tree_with_gaps_tolerated() {
        let md = """
        # One
        intro
        ## One.A
        ### One.A.i
        ## One.B
        # Two
        #### Two.deep
        """
        let syms = MarkdownOutline.documentSymbols(in: md)
        XCTAssertEqual(syms.map(\.name), ["One", "Two"])
        XCTAssertEqual(syms[0].children.map(\.name), ["One.A", "One.B"])
        XCTAssertEqual(syms[0].children[0].children.map(\.name), ["One.A.i"])
        // A level gap (H1 → H4) nests directly under the H1.
        XCTAssertEqual(syms[1].children.map(\.name), ["Two.deep"])
        XCTAssertEqual(syms[1].children[0].detail, "H4")
    }

    func test_lines_convert_to_zero_based_lsp_positions() {
        let md = "intro\n\n# Heading\n"
        let syms = MarkdownOutline.documentSymbols(in: md)
        XCTAssertEqual(syms.count, 1)
        XCTAssertEqual(syms[0].range.start.line, 2, "1-based line 3 → LSP line 2")
        XCTAssertEqual(syms[0].selectionRange.start.line, 2)
        XCTAssertEqual(syms[0].range.end.character, "Heading".utf16.count)
    }

    func test_sibling_after_deeper_subtree_pops_correctly() {
        let md = "## A\n### A.1\n## B\n"
        let syms = MarkdownOutline.documentSymbols(in: md)
        XCTAssertEqual(syms.map(\.name), ["A", "B"], "B must NOT nest under A")
        XCTAssertEqual(syms[0].children.map(\.name), ["A.1"])
    }

    func test_fenced_hashes_are_not_headings_inherited_from_extractor() {
        let md = "# Real\n```\n# fake\n```\n"
        let syms = MarkdownOutline.documentSymbols(in: md)
        XCTAssertEqual(syms.map(\.name), ["Real"])
    }

    func test_empty_and_headingless_docs_yield_empty() {
        XCTAssertTrue(MarkdownOutline.documentSymbols(in: "").isEmpty)
        XCTAssertTrue(MarkdownOutline.documentSymbols(in: "just prose\n").isEmpty)
    }
}
