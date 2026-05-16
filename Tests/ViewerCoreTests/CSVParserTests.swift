import XCTest
@testable import ViewerCore

final class CSVParserTests: XCTestCase {

    // MARK: - Delimiter detection

    func test_detect_tab_is_unambiguous() {
        XCTAssertEqual(CSVParser.detectDelimiter(in: "a\tb\tc\n1\t2\t3"), "\t")
    }

    func test_detect_comma_when_no_tab() {
        XCTAssertEqual(CSVParser.detectDelimiter(in: "a,b,c\n1,2,3"), ",")
    }

    func test_detect_semicolon_when_only_semicolons() {
        XCTAssertEqual(CSVParser.detectDelimiter(in: "a;b;c\n1;2;3"), ";")
    }

    func test_detect_pipe_when_pipes_dominate() {
        XCTAssertEqual(CSVParser.detectDelimiter(in: "a|b|c\n1|2|3"), "|")
    }

    func test_detect_defaults_to_comma_for_empty() {
        XCTAssertEqual(CSVParser.detectDelimiter(in: ""), ",")
    }

    // MARK: - Basic parse

    func test_simple_csv_header_plus_rows() {
        let r = CSVParser.parse("a,b,c\n1,2,3\n4,5,6")
        XCTAssertEqual(r.header, ["a", "b", "c"])
        XCTAssertEqual(r.rows, [["1","2","3"], ["4","5","6"]])
        XCTAssertEqual(r.delimiter, ",")
    }

    func test_tab_separated() {
        let r = CSVParser.parse("a\tb\n1\t2")
        XCTAssertEqual(r.header, ["a", "b"])
        XCTAssertEqual(r.rows, [["1", "2"]])
        XCTAssertEqual(r.delimiter, "\t")
    }

    // MARK: - Quoting

    func test_quoted_field_with_embedded_comma() {
        let r = CSVParser.parse("name,age\n\"Doe, John\",42")
        XCTAssertEqual(r.rows.first, ["Doe, John", "42"])
    }

    func test_quoted_field_with_embedded_newline() {
        let csv = "a,b\n\"line1\nline2\",x"
        let r = CSVParser.parse(csv)
        XCTAssertEqual(r.rows.first?.first, "line1\nline2")
    }

    func test_doubled_quotes_inside_field() {
        let r = CSVParser.parse("a,b\n\"He said \"\"hi\"\"\",ok")
        XCTAssertEqual(r.rows.first, ["He said \"hi\"", "ok"])
    }

    // MARK: - Line endings + edge cases

    func test_crlf_line_endings() {
        let r = CSVParser.parse("a,b\r\n1,2\r\n3,4")
        XCTAssertEqual(r.rows, [["1","2"], ["3","4"]])
    }

    func test_trailing_newline_does_not_create_empty_row() {
        let r = CSVParser.parse("a,b\n1,2\n")
        XCTAssertEqual(r.rows.count, 1)
    }

    func test_empty_fields_preserved() {
        let r = CSVParser.parse("a,b,c\n1,,3")
        XCTAssertEqual(r.rows.first, ["1", "", "3"])
    }

    func test_more_columns_than_header_are_truncated() {
        // Ragged rows: header has 2 cols, row has 3 → drop the extra.
        let r = CSVParser.parse("a,b\n1,2,extra")
        XCTAssertEqual(r.rows.first, ["1", "2"])
    }

    func test_single_column() {
        let r = CSVParser.parse("only\na\nb")
        XCTAssertEqual(r.header, ["only"])
        XCTAssertEqual(r.rows, [["a"], ["b"]])
    }

    func test_empty_input() {
        let r = CSVParser.parse("")
        XCTAssertEqual(r.header, [])
        XCTAssertEqual(r.rows, [])
    }
}
