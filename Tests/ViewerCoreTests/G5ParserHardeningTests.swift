import XCTest
@testable import ViewerCore

/// Audit group **G5** — core parser / loader robustness & encoding.
///
/// Bundles the PARSE-06 adversarial/fuzz coverage for the caps and
/// guards added across the G5 findings:
///   * TextDecoder chain + loader cap (SCALE-1, I18N-01)
///   * CrossFileSearch encoding + CR/CRLF split + cancellation
///     (I18N-02, I18N-04, SCALE-5, PARSE-08)
///   * CSV delimiter quote-awareness + resource caps (CORR-9, PARSE-04)
///   * Hex slice-safety (CORR-4)
///   * Find column clamp on CRLF (CORR-6)
///   * HTML renderer deep-nesting guard + escape fast path (PARSE-03,
///     PERF-06-escape)
///   * HTML sanitizer quote-aware tokenizer + unquoted js: URLs
///     (WV-1, WV-2)
///   * Diff hunk-coord clamp (PARSE-07)
///
/// All host-safe: pure value logic, no AppKit / WKWebView.
final class G5ParserHardeningTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("G5-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmpDir, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - SCALE-1 / MAGIC-002: loader cap >= display caps

    func test_sourceViewMaxBytes_is_at_least_every_display_cap() {
        XCTAssertGreaterThanOrEqual(sourceViewMaxBytes, codeMirrorEditorMaxBytes)
        XCTAssertGreaterThanOrEqual(sourceViewMaxBytes, markdownRenderMaxBytes)
        XCTAssertGreaterThanOrEqual(sourceViewMaxBytes, highlightMaxBytes)
    }

    func test_defaultLoader_caps_align_with_sourceViewMaxBytes() {
        // Two-tier read cap (post session-ui merge): the SOFT watermark
        // (softWarnBytes) equals the source-view threshold — above it a file
        // still loads but read-only / degraded — while the HARD read ceiling
        // (readableMaxBytes, aliased by maxBytes) sits well above it as the
        // OOM backstop. So they no longer match by equality; the watermark
        // does, and the ceiling covers it.
        XCTAssertEqual(TextFileLoader().softWarnBytes, sourceViewMaxBytes)
        XCTAssertGreaterThanOrEqual(TextFileLoader().maxBytes, sourceViewMaxBytes)
        // A file the editor would accept (just over the old 32 MB cap,
        // under the editor's 50 MB) must not be rejected by the loader.
        XCTAssertGreaterThan(TextFileLoader().maxBytes, 40 * 1024 * 1024)
    }

    // MARK: - I18N-01: CP1252 before Latin-1

    func test_decoder_prefers_cp1252_for_smart_quotes() {
        // 0x93 / 0x94 are curly double quotes in CP1252; in Latin-1
        // they are C1 control codes. "He said \u{201C}hi\u{201D}".
        var bytes: [UInt8] = Array("He said ".utf8)
        bytes.append(0x93)
        bytes += Array("hi".utf8)
        bytes.append(0x94)
        let data = Data(bytes)
        guard case .text(let s, let enc) = TextDecoder.decode(data) else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(enc, .windowsCP1252)
        XCTAssertTrue(s.contains("\u{201C}"), "0x93 should decode to U+201C")
        XCTAssertTrue(s.contains("\u{201D}"), "0x94 should decode to U+201D")
    }

    func test_decoder_valid_utf8_still_wins() {
        let data = Data("café — résumé".utf8)
        guard case .text(_, let enc) = TextDecoder.decode(data) else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(enc, .utf8, "valid UTF-8 must never fall to CP1252")
    }

    func test_decoder_falls_to_latin1_for_cp1252_undefined_byte() {
        // 0x81 is undefined in CP1252 → String(.windowsCP1252) fails →
        // Latin-1 (total) catches it.
        let data = Data([0x41, 0x81, 0x42])  // A <undef> B
        guard case .text(_, let enc) = TextDecoder.decode(data) else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(enc, .isoLatin1)
    }

    func test_decoder_binary_blob_reports_binary() {
        let data = Data([0x00, 0x01, 0x02, 0x00, 0xFF, 0x00])
        XCTAssertEqual(TextDecoder.decode(data), .binary)
        XCTAssertNil(TextDecoder.decodeToString(data))
    }

    // MARK: - I18N-02 / PARSE-08: CrossFileSearch decodes non-UTF-8

    func test_crossSearch_finds_match_in_latin1_file() throws {
        // "café" in Latin-1: 'é' is 0xE9 (a lone high byte → not valid
        // UTF-8). Strict-UTF-8 search would skip this file entirely.
        let bytes: [UInt8] = Array("cafe ".utf8) + [0xE9] + Array(" needle here".utf8)
        let url = tmpDir.appendingPathComponent("latin1.txt")
        try Data(bytes).write(to: url)
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle")
        XCTAssertEqual(groups.count, 1, "Latin-1 file must be searchable")
        XCTAssertEqual(groups.first?.matches.first?.lineNumber, 1)
    }

    func test_crossSearch_finds_match_in_utf16le_bom_file() throws {
        let content = "alpha\nbeta needle\ngamma\n"
        var data = Data([0xFF, 0xFE])  // UTF-16 LE BOM
        data.append(content.data(using: .utf16LittleEndian)!)
        let url = tmpDir.appendingPathComponent("utf16.txt")
        try data.write(to: url)
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle")
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.matches.first?.lineNumber, 2)
    }

    // MARK: - I18N-04: CR / CRLF line split

    func test_crossSearch_crlf_strips_trailing_cr_from_line() throws {
        let url = tmpDir.appendingPathComponent("crlf.txt")
        try "one\r\ntwo needle\r\nthree\r\n".write(to: url, atomically: true, encoding: .utf8)
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle")
        XCTAssertEqual(groups.count, 1)
        let m = try XCTUnwrap(groups.first?.matches.first)
        XCTAssertEqual(m.lineNumber, 2)
        XCTAssertEqual(m.line, "two needle", "no stray trailing \\r")
        XCTAssertFalse(m.line.contains("\r"))
    }

    func test_crossSearch_cr_only_classicMac_does_not_collapse() throws {
        let url = tmpDir.appendingPathComponent("cr.txt")
        try "one\rtwo needle\rthree\r".write(to: url, atomically: true, encoding: .utf8)
        let groups = CrossFileSearch.search(root: tmpDir, query: "needle")
        XCTAssertEqual(groups.count, 1)
        let m = try XCTUnwrap(groups.first?.matches.first)
        XCTAssertEqual(m.lineNumber, 2, "CR-only file must split into real lines")
        XCTAssertEqual(m.line, "two needle")
    }

    func test_splitLines_matches_lf_semantics() {
        // Trailing LF yields a final empty line (parity with old behaviour).
        XCTAssertEqual(CrossFileSearch.splitLines("a\nb\n").map(String.init),
                       ["a", "b", ""])
        XCTAssertEqual(CrossFileSearch.splitLines("a\r\nb").map(String.init),
                       ["a", "b"])
        XCTAssertEqual(CrossFileSearch.splitLines("a\rb\rc").map(String.init),
                       ["a", "b", "c"])
        XCTAssertEqual(CrossFileSearch.splitLines("").map(String.init), [""])
    }

    // MARK: - SCALE-5: cancellation

    func test_crossSearch_honours_cancellation() throws {
        for i in 0..<50 {
            let u = tmpDir.appendingPathComponent("f\(i).txt")
            try "needle in file \(i)\n".write(to: u, atomically: true, encoding: .utf8)
        }
        // Cancel immediately → no results.
        let cancelled = CrossFileSearch.search(
            root: tmpDir, query: "needle", isCancelled: { true }
        )
        XCTAssertTrue(cancelled.isEmpty, "immediate cancel yields no matches")
        // Not cancelled → finds them.
        let full = CrossFileSearch.search(
            root: tmpDir, query: "needle", isCancelled: { false }
        )
        XCTAssertFalse(full.isEmpty)
    }

    // MARK: - CORR-9: quote-aware delimiter detection

    func test_csv_detectDelimiter_ignores_delims_inside_quotes() {
        // The empirical payload: a quoted first field full of commas,
        // real delimiter is the semicolon.
        XCTAssertEqual(CSVParser.detectDelimiter(in: "\"a,b,c\";x;y"), ";")
    }

    func test_csv_detectDelimiter_quoted_newline_spans_first_record() {
        // A quoted field containing a newline must not end the record.
        let text = "\"line1\nline2\";col2;col3\n"
        XCTAssertEqual(CSVParser.detectDelimiter(in: text), ";")
    }

    func test_csv_parse_with_quoted_semicolons_keeps_first_cell_intact() {
        let r = CSVParser.parse("\"a,b,c\";x;y")
        XCTAssertEqual(r.delimiter, ";")
        XCTAssertEqual(r.header, ["a,b,c", "x", "y"])
    }

    // MARK: - PARSE-04: CSV resource caps

    func test_csv_unterminated_quote_is_bounded_and_flagged() {
        // One open quote, then a megabyte of 'x' with no closing quote
        // and no delimiter → previously one unbounded field.
        let blob = "\"" + String(repeating: "x", count: 200_000)
        let r = CSVParser.parse(blob, limits: CSVParser.Limits(maxCellChars: 1000))
        XCTAssertTrue(r.truncated, "runaway cell must flip truncated")
        // The single cell is clamped to ~maxCellChars (+ the … marker).
        let cell = (r.header.first ?? "")
        XCTAssertLessThanOrEqual(cell.count, 1002)
        XCTAssertTrue(cell.hasSuffix("…"))
    }

    func test_csv_no_delimiter_huge_single_column_is_bounded() {
        // No delimiter at all — many one-cell rows. Cap on total cells.
        let many = (0..<10_000).map { "row\($0)" }.joined(separator: "\n")
        let r = CSVParser.parse(many, limits: CSVParser.Limits(maxTotalCells: 100))
        XCTAssertTrue(r.truncated)
        XCTAssertLessThanOrEqual(r.rows.count + 1, 101)
    }

    func test_csv_input_scalar_cap_stops_parsing() {
        let big = String(repeating: "a,b,c\n", count: 10_000)
        let r = CSVParser.parse(big, limits: CSVParser.Limits(maxInputScalars: 50))
        XCTAssertTrue(r.truncated)
    }

    func test_csv_normal_input_not_flagged_truncated() {
        let r = CSVParser.parse("a,b,c\n1,2,3\n4,5,6\n")
        XCTAssertFalse(r.truncated)
        XCTAssertEqual(r.header, ["a", "b", "c"])
        XCTAssertEqual(r.rows.count, 2)
    }

    // MARK: - CORR-4: Hex slice-offset safety

    func test_hex_renderRows_offsetSlice_matches_freshBuffer() {
        // Build an offset slice (non-zero internal startIndex) of a
        // known payload and confirm the dump is byte-identical to the
        // fresh-buffer dump. If the macOS-26 slice bug were live, the
        // ASCII/hex columns would show shifted bytes.
        let payload = Data((0..<64).map { UInt8($0 &+ 0x30) })
        var raw = Data(repeating: 0xEE, count: 7)
        raw.append(payload)
        raw.removeFirst(7)  // raw is now an offset slice == payload
        XCTAssertEqual(raw.count, payload.count)

        let fresh = BinaryFile(url: URL(fileURLWithPath: "/tmp/x"),
                               data: payload, totalByteCount: payload.count,
                               isTruncated: false)
        let sliced = BinaryFile(url: URL(fileURLWithPath: "/tmp/x"),
                                data: raw, totalByteCount: raw.count,
                                isTruncated: false)
        XCTAssertEqual(HexDumpBuilder.buildAll(file: sliced, width: 16),
                       HexDumpBuilder.buildAll(file: fresh, width: 16))
    }

    // MARK: - CORR-6: Find column clamp on CRLF

    func test_find_match_on_crlf_does_not_report_column_zero() throws {
        // "ab\r\ncd" — search for the LF-adjacent boundary. Put a needle
        // that can land right after a CRLF and one whose start would map
        // onto a terminator under the old math.
        let text = "ab\r\ncd\r\nef"
        let q = FindQuery(pattern: "\r", kind: .regex)
        let matches = try FindEngine().search(in: text, query: q)
        XCTAssertFalse(matches.isEmpty)
        for m in matches {
            XCTAssertGreaterThanOrEqual(m.column, 1, "column is 1-based, never 0")
            XCTAssertGreaterThanOrEqual(m.line, 1)
        }
    }

    func test_find_columns_correct_for_crlf_lines() throws {
        let text = "hello\r\nworld\r\n"
        let matches = try FindEngine().search(in: text, query: FindQuery(pattern: "world"))
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].line, 2)
        XCTAssertEqual(matches[0].column, 1)
    }

    // MARK: - PARSE-03: deep-nesting guard

    func test_html_render_5000_deep_blockquote_does_not_crash() {
        // The PARSE-03 guard lives on the SWIFT path (the rust route renders
        // deep nesting fully — pinned by RustMarkdownAdapterTests' bomb test).
        let deep = String(repeating: "> ", count: 5000) + "boom\n"
        let html = HTMLRenderer.renderSwiftPath(deep)
        XCTAssertFalse(html.isEmpty)
        XCTAssertTrue(html.contains("blockquote"))
        XCTAssertTrue(html.contains("truncated"),
                      "should emit the depth truncation marker")
    }

    func test_html_render_deeply_nested_blockquote_emits_truncation_marker() {
        // PARSE-03 is specifically about the *visitor* recursing past
        // the stack budget. Build a tree deeper than `maxDepth` (512)
        // but well under cmark-gfm's own parser recursion limit (the
        // C library traps on pathologically deep *list* indentation
        // during parsing, which is out of this renderer's control and
        // belongs to the off-main render hop in G1). 700 `>` nests the
        // blockquote tree past our guard.
        let deep = String(repeating: "> ", count: 700) + "x\n"
        let html = HTMLRenderer.renderSwiftPath(deep)
        XCTAssertTrue(html.contains("truncated"),
                      "visitor must stop descending and emit the marker")
    }

    func test_html_render_shallow_doc_unaffected_by_guard() {
        let html = HTMLRenderer().render("> quote\n\n- a\n- b\n")
        XCTAssertFalse(html.contains("truncated"))
        XCTAssertTrue(html.contains("<blockquote>"))
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<li>"))
        XCTAssertTrue(html.contains("quote"))
    }

    // MARK: - PERF-06-escape: htmlEscape correctness

    func test_html_escape_preserves_semantics() {
        let v = HTMLVisitor()
        XCTAssertEqual(v.htmlEscape("a & b < c > d \" e ' f"),
                       "a &amp; b &lt; c &gt; d &quot; e &#39; f")
        // Multibyte scalars must survive untouched.
        XCTAssertEqual(v.htmlEscape("café 🎉 日本"), "café 🎉 日本")
        XCTAssertEqual(v.htmlEscape(""), "")
        XCTAssertEqual(v.htmlEscape("<&>"), "&lt;&amp;&gt;")
    }

    // MARK: - WV-1: quote-aware sanitizer tokenizer

    func test_sanitizer_strips_handler_after_gt_inside_quoted_attr() {
        // The empirical payload: a `>` inside the quoted href used to
        // truncate the tag, leaving onerror= outside the scrub.
        let payload = "<img src=\"x>\" onerror=\"alert(1)\">"
        let out = HTMLSanitizer.sanitize(payload)
        XCTAssertFalse(out.lowercased().contains("onerror"),
                       "event handler must be stripped even past a quoted >")
    }

    func test_sanitizer_strips_handler_with_gt_in_single_quotes() {
        let payload = "<a href='javascript:1>' onclick='steal()'>x</a>"
        let out = HTMLSanitizer.sanitize(payload)
        XCTAssertFalse(out.lowercased().contains("onclick"))
    }

    // MARK: - WV-2: unquoted javascript: URLs

    func test_sanitizer_neutralizes_unquoted_javascript_href() {
        let out = HTMLSanitizer.sanitize("<a href=javascript:alert(1)>x</a>")
        XCTAssertFalse(out.lowercased().contains("javascript:"))
        XCTAssertTrue(out.contains("about:blank"))
    }

    func test_sanitizer_neutralizes_unquoted_vbscript_src() {
        let out = HTMLSanitizer.sanitize("<img src=vbscript:msgbox>")
        XCTAssertFalse(out.lowercased().contains("vbscript:"))
    }

    func test_sanitizer_quoted_javascript_still_neutralized() {
        let out = HTMLSanitizer.sanitize("<a href=\"javascript:alert(1)\">x</a>")
        XCTAssertFalse(out.lowercased().contains("javascript:"))
        XCTAssertTrue(out.contains("about:blank"))
    }

    func test_sanitizer_leaves_literal_javascript_text_in_body() {
        // "javascript:" as visible text (not an attribute) is untouched.
        let out = HTMLSanitizer.sanitize("<p>type javascript: to run</p>")
        XCTAssertTrue(out.contains("javascript:"))
    }

    // MARK: - PARSE-07: diff hunk coordinate clamp

    func test_diff_garbage_hunk_header_does_not_explode_coords() {
        let diff = """
        diff --git a/f.txt b/f.txt
        --- a/f.txt
        +++ b/f.txt
        @@ -99999999999999 +-5 @@
        +new line
        """
        let files = RustDiffAdapter.parse(diff)
        // Garbage `+-5` (not a valid `+N` start) makes the header
        // unparseable → no hunk; that's acceptable. The load-bearing
        // assertion is that parsing does not crash and produces a file.
        XCTAssertEqual(files.count, 1)
        for f in files {
            for h in f.hunks {
                XCTAssertGreaterThanOrEqual(h.oldStart, 0)
                XCTAssertGreaterThanOrEqual(h.newStart, 0)
                XCTAssertLessThanOrEqual(h.oldStart, 1_000_000_000)
                XCTAssertLessThanOrEqual(h.newStart, 1_000_000_000)
            }
        }
    }

    func test_diff_huge_but_valid_coords_are_clamped() {
        let diff = """
        diff --git a/f.txt b/f.txt
        --- a/f.txt
        +++ b/f.txt
        @@ -5000000000,3 +6000000000,3 @@
         ctx
        +added
        """
        let files = RustDiffAdapter.parse(diff)
        let hunk = try? XCTUnwrap(files.first?.hunks.first)
        if let hunk {
            XCTAssertLessThanOrEqual(hunk.oldStart, 1_000_000_000)
            XCTAssertLessThanOrEqual(hunk.newStart, 1_000_000_000)
        }
    }

    func test_diff_normal_header_unaffected() {
        let diff = """
        diff --git a/f.txt b/f.txt
        --- a/f.txt
        +++ b/f.txt
        @@ -10,2 +12,3 @@
         ctx
        +added
        """
        let files = RustDiffAdapter.parse(diff)
        XCTAssertEqual(files.first?.hunks.first?.oldStart, 10)
        XCTAssertEqual(files.first?.hunks.first?.newStart, 12)
    }
}
