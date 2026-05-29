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

    // MARK: - Memory-bound parsing (no scalar materialization)

    /// Analytical guard: ensure no future edit re-introduces
    /// `Array(text.unicodeScalars)`. That materialization holds
    /// ~4 B × scalar-count for the duration of the parse, which on
    /// a 50 MB ASCII CSV doubles peak RSS (≈200 MB scalar array on
    /// top of the source `String`). The parser is required to
    /// stream via `makeIterator()` instead.
    func test_no_full_scalar_array_materialization_in_source() throws {
        // Walk up from this file to the package root, then read
        // Sources/ViewerCore/CSVParser.swift. Done at runtime so the
        // assertion stays accurate even if someone moves the file.
        let here = URL(fileURLWithPath: #filePath)
        // Tests/ViewerCoreTests/CSVParserTests.swift → up 3.
        let packageRoot = here
            .deletingLastPathComponent()  // ViewerCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // package root
        let parserURL = packageRoot
            .appendingPathComponent("Sources/ViewerCore/CSVParser.swift")
        let src = try String(contentsOf: parserURL, encoding: .utf8)
        // Strip block + line comments before scanning so the
        // explanatory note in the parser itself ("`Array(text.unicodeScalars)`")
        // doesn't trip this guard.
        let stripped = stripSwiftComments(src)
        XCTAssertFalse(
            stripped.contains("Array(text.unicodeScalars)"),
            "CSVParser.swift must not materialize the full scalar array; "
            + "stream via text.unicodeScalars.makeIterator() instead."
        )
        // Also reject the common alternative `Array(<x>.unicodeScalars)`
        // anywhere in the parse loop — same memory hazard.
        XCTAssertFalse(
            stripped.range(of: #"Array\([a-zA-Z_][a-zA-Z0-9_]*\.unicodeScalars\)"#,
                           options: .regularExpression) != nil,
            "CSVParser.swift must not call Array(_.unicodeScalars) — "
            + "this defeats the streaming-iterator memory win."
        )
    }

    /// 50 MB synthesized CSV: parse must produce the right row count
    /// and round-trip a few sentinel rows. The point of this test is
    /// less the timing (the runtime is a few seconds) and more the
    /// proof that quoting / CRLF / embedded newlines still work at
    /// scale with the streaming implementation.
    func test_large_csv_50mb_correctness() {
        // Build a CSV with mixed content: plain rows, CRLF, embedded
        // quotes, embedded newlines. Target ≈50 MB of UTF-8.
        var sb = ""
        sb.reserveCapacity(55 * 1024 * 1024)
        sb.append("id,name,note\r\n")
        // Each unit is ~120 bytes; 450_000 units ≈ 54 MB.
        // - row A: plain CRLF
        // - row B: quoted field with embedded comma + escaped quote
        // - row C: quoted field with embedded newline
        let unitCount = 450_000
        for i in 0..<unitCount {
            sb.append("\(i * 3),plain-name-\(i),just a note here for row A padding bytes\r\n")
            sb.append("\(i * 3 + 1),\"Doe, John \"\"#\(i)\"\"\",quoted with comma and escaped quote padding\r\n")
            sb.append("\(i * 3 + 2),\"multi\nline-\(i)\",embedded newline inside quoted field padding\r\n")
        }
        // Sanity check on the synthesized size — only assert ≥40 MB
        // so this isn't fragile if the format changes slightly.
        XCTAssertGreaterThan(sb.utf8.count, 40 * 1024 * 1024,
                             "synthesized CSV should be > 40 MB")

        let r = CSVParser.parse(sb)
        XCTAssertEqual(r.delimiter, ",")
        XCTAssertEqual(r.header, ["id", "name", "note"])
        XCTAssertEqual(r.rows.count, unitCount * 3,
                       "all rows should parse; ragged-row pad/trunc shouldn't lose any")

        // Spot-check first unit of rows: A / B / C.
        XCTAssertEqual(r.rows[0][0], "0")
        XCTAssertEqual(r.rows[0][1], "plain-name-0")

        XCTAssertEqual(r.rows[1][0], "1")
        XCTAssertEqual(r.rows[1][1], "Doe, John \"#0\"",
                       "escaped-quote handling must survive at scale")

        XCTAssertEqual(r.rows[2][0], "2")
        XCTAssertEqual(r.rows[2][1], "multi\nline-0",
                       "embedded newline inside quoted field must survive at scale")

        // Spot-check a middle unit too.
        let mid = (unitCount / 2) * 3
        XCTAssertEqual(r.rows[mid][1], "plain-name-\(unitCount / 2)")
        XCTAssertEqual(r.rows[mid + 1][1],
                       "Doe, John \"#\(unitCount / 2)\"")
        XCTAssertEqual(r.rows[mid + 2][1],
                       "multi\nline-\(unitCount / 2)")
    }

    // MARK: - Helpers

    /// Crude Swift comment stripper — good enough for an in-tree
    /// source-guard assertion (we only need to peel away `//` lines
    /// and `/* … */` blocks; the parser file has no string literals
    /// containing comment markers).
    private func stripSwiftComments(_ src: String) -> String {
        var out = ""
        out.reserveCapacity(src.count)
        var i = src.startIndex
        while i < src.endIndex {
            let c = src[i]
            if c == "/", src.index(after: i) < src.endIndex {
                let next = src[src.index(after: i)]
                if next == "/" {
                    // Line comment — skip to newline.
                    while i < src.endIndex, src[i] != "\n" {
                        i = src.index(after: i)
                    }
                    continue
                } else if next == "*" {
                    // Block comment — skip to "*/".
                    i = src.index(i, offsetBy: 2)
                    while i < src.endIndex {
                        if src[i] == "*",
                           src.index(after: i) < src.endIndex,
                           src[src.index(after: i)] == "/" {
                            i = src.index(i, offsetBy: 2)
                            break
                        }
                        i = src.index(after: i)
                    }
                    continue
                }
            }
            out.append(c)
            i = src.index(after: i)
        }
        return out
    }
}
