import XCTest
@testable import ViewerCore

/// Host tests for the Universal-Paste table detection + extraction slice
/// (TSK-958). Pure `[[String]]` grid assertions — no clipboard, no UI.
final class ClipboardTableExtractorTests: XCTestCase {

    // MARK: - detectTable

    func test_detectTable_true_for_basic_table() {
        XCTAssertTrue(ClipboardTableExtractor.detectTable(
            html: "<table><tr><td>a</td></tr></table>"))
    }

    func test_detectTable_true_case_insensitive_and_with_attrs() {
        XCTAssertTrue(ClipboardTableExtractor.detectTable(
            html: "<div><TABLE class=\"grid\" border=1><tr><th>H</th></tr></TABLE></div>"))
    }

    func test_detectTable_false_for_non_table_html() {
        XCTAssertFalse(ClipboardTableExtractor.detectTable(
            html: "<div><p>Just a paragraph with the word table in it.</p></div>"))
    }

    func test_detectTable_false_for_plain_text() {
        XCTAssertFalse(ClipboardTableExtractor.detectTable(html: "a,b,c\n1,2,3"))
    }

    func test_detectTable_false_for_word_boundary_lookalike() {
        // `<tablerow>` / `<tabledata>` must NOT trip the `<table>` match.
        XCTAssertFalse(ClipboardTableExtractor.detectTable(
            html: "<tablerow><tabledata>x</tabledata></tablerow>"))
    }

    func test_detectTable_empty_is_false() {
        XCTAssertFalse(ClipboardTableExtractor.detectTable(html: ""))
    }

    // MARK: - htmlTableToRows: structure

    func test_html_simple_grid() {
        let html = "<table><tr><td>1</td><td>2</td></tr><tr><td>3</td><td>4</td></tr></table>"
        XCTAssertEqual(ClipboardTableExtractor.htmlTableToRows(html),
                       [["1", "2"], ["3", "4"]])
    }

    func test_html_header_row_th_then_td() {
        // A header row of <th> followed by data <td> rows — both are cells; the
        // header is just row 0 (the CSV viewer treats it as the header).
        let html = """
        <table>
          <tr><th>Name</th><th>Age</th></tr>
          <tr><td>Alice</td><td>30</td></tr>
          <tr><td>Bob</td><td>25</td></tr>
        </table>
        """
        XCTAssertEqual(ClipboardTableExtractor.htmlTableToRows(html),
                       [["Name", "Age"], ["Alice", "30"], ["Bob", "25"]])
    }

    func test_html_thead_tbody_wrappers_are_transparent() {
        // <thead>/<tbody> are not <tr>/<td>, so they're simply skipped over by
        // the row/cell scan — the grid is still header + body.
        let html = """
        <table>
          <thead><tr><th>A</th><th>B</th></tr></thead>
          <tbody><tr><td>1</td><td>2</td></tr></tbody>
        </table>
        """
        XCTAssertEqual(ClipboardTableExtractor.htmlTableToRows(html),
                       [["A", "B"], ["1", "2"]])
    }

    // MARK: - htmlTableToRows: cell content

    func test_html_nested_formatting_in_cells_is_stripped() {
        let html = """
        <table><tr>
          <td><b>Bold</b> and <i>italic</i></td>
          <td><a href="https://x">link <span>text</span></a></td>
        </tr></table>
        """
        XCTAssertEqual(ClipboardTableExtractor.htmlTableToRows(html),
                       [["Bold and italic", "link text"]])
    }

    func test_html_entities_decoded_in_cells() {
        let html = "<table><tr><td>a &amp; b</td><td>&lt;tag&gt;</td>"
                 + "<td>it&#39;s</td></tr></table>"
        XCTAssertEqual(ClipboardTableExtractor.htmlTableToRows(html),
                       [["a & b", "<tag>", "it's"]])
    }

    func test_html_br_becomes_space_and_whitespace_collapsed() {
        let html = "<table><tr><td>line1<br>line2</td>"
                 + "<td>  lots   of\n\twhitespace  </td></tr></table>"
        XCTAssertEqual(ClipboardTableExtractor.htmlTableToRows(html),
                       [["line1 line2", "lots of whitespace"]])
    }

    func test_html_quote_inside_attribute_does_not_truncate_cell() {
        // A `>` inside a quoted attribute value must NOT end the tag early —
        // otherwise the cell text would leak the attribute tail.
        let html = "<table><tr><td><span title=\"a>b\">value</span></td></tr></table>"
        XCTAssertEqual(ClipboardTableExtractor.htmlTableToRows(html),
                       [["value"]])
    }

    // MARK: - htmlTableToRows: colspan / rowspan (ignored-but-safe)

    func test_html_colspan_is_ignored_but_safe() {
        // colspan=2 yields a SINGLE cell (no phantom cells, no crash); the row
        // is simply narrower than its visual span. Downstream padding handles it.
        let html = """
        <table>
          <tr><td colspan="2">Merged</td></tr>
          <tr><td>L</td><td>R</td></tr>
        </table>
        """
        XCTAssertEqual(ClipboardTableExtractor.htmlTableToRows(html),
                       [["Merged"], ["L", "R"]])
    }

    func test_html_rowspan_attribute_is_ignored_but_safe() {
        let html = """
        <table>
          <tr><td rowspan="2">Tall</td><td>a</td></tr>
          <tr><td>b</td></tr>
        </table>
        """
        XCTAssertEqual(ClipboardTableExtractor.htmlTableToRows(html),
                       [["Tall", "a"], ["b"]])
    }

    // MARK: - htmlTableToRows: edge cases

    func test_html_no_table_returns_empty() {
        XCTAssertEqual(ClipboardTableExtractor.htmlTableToRows("<p>no table</p>"),
                       [])
    }

    func test_html_only_first_table_is_read() {
        let html = "<table><tr><td>first</td></tr></table>"
                 + "<table><tr><td>second</td></tr></table>"
        XCTAssertEqual(ClipboardTableExtractor.htmlTableToRows(html),
                       [["first"]])
    }

    func test_html_unclosed_cells_still_split() {
        // Missing </td> — the next <td> terminates the previous cell.
        let html = "<table><tr><td>a<td>b<td>c</tr></table>"
        XCTAssertEqual(ClipboardTableExtractor.htmlTableToRows(html),
                       [["a", "b", "c"]])
    }

    func test_html_missing_close_table_reads_to_end() {
        let html = "<table><tr><td>x</td></tr><tr><td>y</td></tr>"
        XCTAssertEqual(ClipboardTableExtractor.htmlTableToRows(html),
                       [["x"], ["y"]])
    }

    func test_html_empty_cells_preserved() {
        let html = "<table><tr><td>a</td><td></td><td>c</td></tr></table>"
        XCTAssertEqual(ClipboardTableExtractor.htmlTableToRows(html),
                       [["a", "", "c"]])
    }

    func test_html_caps_rows() {
        let body = String(repeating: "<tr><td>x</td></tr>", count: 50)
        let html = "<table>\(body)</table>"
        let rows = ClipboardTableExtractor.htmlTableToRows(
            html, limits: .init(maxRows: 10))
        XCTAssertEqual(rows.count, 10)
    }

    func test_html_caps_cell_chars() {
        let big = String(repeating: "z", count: 100)
        let html = "<table><tr><td>\(big)</td></tr></table>"
        let rows = ClipboardTableExtractor.htmlTableToRows(
            html, limits: .init(maxCellChars: 10))
        XCTAssertEqual(rows, [[String(repeating: "z", count: 10) + "…"]])
    }

    // MARK: - tsvToRows

    func test_tsv_basic() {
        let tsv = "a\tb\tc\n1\t2\t3\n4\t5\t6"
        XCTAssertEqual(ClipboardTableExtractor.tsvToRows(tsv),
                       [["a", "b", "c"], ["1", "2", "3"], ["4", "5", "6"]])
    }

    func test_tsv_includes_header_row_in_grid() {
        // The grid is [header] + rows so it composes with htmlTableToRows.
        let grid = ClipboardTableExtractor.tsvToRows("h1\th2\nv1\tv2")
        XCTAssertEqual(grid.first, ["h1", "h2"])
        XCTAssertEqual(grid.count, 2)
    }

    func test_tsv_honors_quoting_embedded_tab() {
        // A quoted field containing a literal tab must stay one cell.
        let tsv = "name\tnote\n\"a\tb\"\tok"
        XCTAssertEqual(ClipboardTableExtractor.tsvToRows(tsv),
                       [["name", "note"], ["a\tb", "ok"]])
    }

    func test_tsv_honors_quoting_embedded_newline() {
        let tsv = "a\tb\n\"line1\nline2\"\tx"
        let grid = ClipboardTableExtractor.tsvToRows(tsv)
        XCTAssertEqual(grid, [["a", "b"], ["line1\nline2", "x"]])
    }

    func test_tsv_doubled_quotes() {
        let tsv = "a\tb\n\"He said \"\"hi\"\"\"\tok"
        XCTAssertEqual(ClipboardTableExtractor.tsvToRows(tsv).last,
                       ["He said \"hi\"", "ok"])
    }

    func test_tsv_empty_is_empty_grid() {
        XCTAssertEqual(ClipboardTableExtractor.tsvToRows(""), [])
    }

    func test_tsv_single_column() {
        // No tabs at all — each line is one cell.
        XCTAssertEqual(ClipboardTableExtractor.tsvToRows("only\nrows\nhere"),
                       [["only"], ["rows"], ["here"]])
    }

    // MARK: - Composition with downstream CSV consumers

    func test_extracted_html_grid_round_trips_through_csv_convert() {
        // Proves the slice's output is exactly what CSVConvert/CSVTableView
        // consume: header + rows. Acts as the integration assertion that the
        // "feed the CSV viewer" half is wired to a real grid.
        let html = "<table><tr><th>k</th><th>v</th></tr>"
                 + "<tr><td>x</td><td>1</td></tr></table>"
        let grid = ClipboardTableExtractor.htmlTableToRows(html)
        guard let header = grid.first else {
            return XCTFail("expected a header row")
        }
        let body = Array(grid.dropFirst())
        let md = CsvConvert.toMarkdownTable(header: header, rows: body)
        XCTAssertTrue(md.contains("| k"))
        XCTAssertTrue(md.contains("| x"))
    }
}
