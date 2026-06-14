import XCTest
@testable import ViewerCore

/// TSK-719 (sticky scroll) — host coverage for the pure pin-computation. The
/// rendered pinned bar is the VM tail; this pins the logic that decides WHICH
/// enclosing headers show and resolves their text.
final class StickyScrollHeadersTests: XCTestCase {

    private func fold(_ s: Int, _ e: Int, _ k: FoldRegion.Kind) -> FoldRegion {
        FoldRegion(startLine: s, endLine: e, kind: k)
    }

    // MARK: - pinnedRegions

    func test_enclosingChain_outermostToInnermost() {
        // type(2..40) ⊃ function(5..30) ⊃ function(10..20); caret-top at line 15.
        let regions = [fold(2, 40, .type), fold(5, 30, .function), fold(10, 20, .function)]
        let pinned = StickyScrollHeaders.pinnedRegions(foldRegions: regions, viewportTopLine: 15)
        XCTAssertEqual(pinned.map(\.startLine), [2, 5, 10], "outermost → innermost")
    }

    func test_headerOnScreen_isNotPinned() {
        // The function's own header (line 5) IS the viewport top → nothing to pin
        // for it (you can already see it); the enclosing type (line 2) still pins.
        let regions = [fold(2, 40, .type), fold(5, 30, .function)]
        let pinned = StickyScrollHeaders.pinnedRegions(foldRegions: regions, viewportTopLine: 5)
        XCTAssertEqual(pinned.map(\.startLine), [2],
                       "a header at the viewport top isn't pinned; only the outer scope")
    }

    func test_nonHeaderKinds_excluded() {
        // An object/array/comment/string/fence enclosing the line is NOT a scope
        // header — only the function survives.
        let regions = [
            fold(2, 50, .function),
            fold(8, 30, .object),
            fold(12, 25, .comment),
            fold(14, 20, .array),
        ]
        let pinned = StickyScrollHeaders.pinnedRegions(foldRegions: regions, viewportTopLine: 18)
        XCTAssertEqual(pinned.map(\.kind), [.function])
    }

    func test_maxDepth_keepsOutermost() {
        let regions = [
            fold(1, 99, .type), fold(2, 98, .type), fold(3, 97, .function),
            fold(4, 96, .function), fold(5, 95, .function), fold(6, 94, .function),
        ]
        let pinned = StickyScrollHeaders.pinnedRegions(
            foldRegions: regions, viewportTopLine: 50, maxDepth: 3)
        XCTAssertEqual(pinned.map(\.startLine), [1, 2, 3],
                       "overflow keeps the outermost (the broad breadcrumb)")
    }

    func test_noEnclosing_returnsEmpty() {
        let regions = [fold(2, 10, .function)]
        XCTAssertTrue(StickyScrollHeaders.pinnedRegions(
            foldRegions: regions, viewportTopLine: 50).isEmpty,
            "line outside every region → nothing pinned")
    }

    func test_viewportTopZeroOrNegative_returnsEmpty() {
        let regions = [fold(2, 40, .type)]
        XCTAssertTrue(StickyScrollHeaders.pinnedRegions(foldRegions: regions, viewportTopLine: 0).isEmpty)
    }

    func test_tieOnStartLine_largerSpanIsOuter() {
        // Two regions starting on the same line — the wider span is outer.
        let regions = [fold(3, 20, .function), fold(3, 40, .type)]
        let pinned = StickyScrollHeaders.pinnedRegions(foldRegions: regions, viewportTopLine: 10)
        XCTAssertEqual(pinned.map(\.kind), [.type, .function])
    }

    // MARK: - headers (text resolution)

    func test_headers_resolveTrimmedLineText() {
        let text = """
        class Foo {
            func bar() {
                let x = compute()
                return x
            }
        }
        """
        // type(1..6) ⊃ function(2..5); top at line 3 → pin both, with text.
        let regions = [fold(1, 6, .type), fold(2, 5, .function)]
        let headers = StickyScrollHeaders.headers(
            foldRegions: regions, viewportTopLine: 3, documentText: text)
        XCTAssertEqual(headers.map(\.line), [1, 2])
        XCTAssertEqual(headers.map(\.text), ["class Foo {", "func bar() {"],
                       "header text is the trimmed source line")
        XCTAssertEqual(headers.map(\.kind), [.type, .function])
    }

    func test_headers_markdownHeadingPath() {
        let md = """
        # Title
        intro
        ## Section
        body line under section
        more body
        """
        // heading(1..5) ⊃ heading(3..5); top at line 4 → both headings pin.
        let regions = [fold(1, 5, .heading), fold(3, 5, .heading)]
        let headers = StickyScrollHeaders.headers(
            foldRegions: regions, viewportTopLine: 4, documentText: md)
        XCTAssertEqual(headers.map(\.text), ["# Title", "## Section"])
    }

    func test_headers_dropsOutOfRangeStartLine() {
        // Stale fold pointing past EOF → dropped, not a crash.
        let text = "line1\nline2\n"
        let regions = [fold(99, 200, .function)]
        let headers = StickyScrollHeaders.headers(
            foldRegions: regions, viewportTopLine: 150, documentText: text)
        XCTAssertTrue(headers.isEmpty)
    }

    // MARK: - lineText (single-pass extraction)

    func test_lineText_extractsRequestedLinesOnly() {
        let text = "a\nb\nc\nd\ne"
        let got = StickyScrollHeaders.lineText(for: [1, 3, 5], in: text)
        XCTAssertEqual(got, [1: "a", 3: "c", 5: "e"])
    }

    func test_lineText_trimsTrailingCR_forCRLF() {
        let text = "first\r\nsecond\r\n"
        let got = StickyScrollHeaders.lineText(for: [1, 2], in: text)
        XCTAssertEqual(got[1], "first", "CRLF carriage return is dropped")
        XCTAssertEqual(got[2], "second")
    }

    func test_lineText_finalLineWithoutNewline() {
        let text = "x\ny\nlast"
        XCTAssertEqual(StickyScrollHeaders.lineText(for: [3], in: text), [3: "last"])
    }

    func test_lineText_emptyRequest() {
        XCTAssertEqual(StickyScrollHeaders.lineText(for: [], in: "a\nb"), [:])
    }
}
