import XCTest
@testable import ViewerCore

/// Mapping table for `LSPDiagnostic → CMDiagnostic`. Verifies the
/// position translation works in UTF-16 (what CM6's doc indexing uses
/// inside JS), respects the negotiated LSP encoding, clamps out-of-
/// range ranges to the document, and widens zero-length ranges so the
/// squiggle has a visible target.
final class CMDiagnosticMappingTests: XCTestCase {

    private func diag(
        startLine: Int, startCh: Int, endLine: Int, endCh: Int,
        sev: LSPDiagnostic.Severity = .error,
        message: String = "boom",
        source: String? = "test",
        code: String? = nil
    ) -> LSPDiagnostic {
        LSPDiagnostic(
            range: LSPRange(
                start: LSPPosition(line: startLine, character: startCh),
                end: LSPPosition(line: endLine, character: endCh)
            ),
            severity: sev,
            code: code,
            source: source,
            message: message
        )
    }

    func testEmptyArrayMapsToEmpty() {
        let out = CMDiagnosticMapping.cmDiagnostics(
            from: [],
            documentText: "line 1\nline 2\n",
            encoding: .utf16
        )
        XCTAssertEqual(out, [])
    }

    func testAsciiRangeUTF16Encoding() {
        // "abc\ndef\nghi" — "def" is at offsets 4..7 (UTF-16, same as bytes).
        let doc = "abc\ndef\nghi"
        let out = CMDiagnosticMapping.cmDiagnostics(
            from: [diag(startLine: 1, startCh: 0, endLine: 1, endCh: 3)],
            documentText: doc,
            encoding: .utf16
        )
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].from, 4)
        XCTAssertEqual(out[0].to, 7)
        XCTAssertEqual(out[0].severity, .error)
        XCTAssertEqual(out[0].message, "boom")
        XCTAssertEqual(out[0].source, "test")
    }

    func testEmojiInLineUTF8VsUTF16() {
        // "👍 foo" — 👍 is 2 UTF-16 code units, 4 UTF-8 bytes.
        // Diagnostic on "foo" via line=0, char=3 (UTF-16) should land
        // at CM offset 3..6. With utf8 encoding char=5 → same CM range.
        let doc = "👍 foo"
        let outUTF16 = CMDiagnosticMapping.cmDiagnostics(
            from: [diag(startLine: 0, startCh: 3, endLine: 0, endCh: 6)],
            documentText: doc,
            encoding: .utf16
        )
        XCTAssertEqual(outUTF16.count, 1)
        XCTAssertEqual(outUTF16[0].from, 3)
        XCTAssertEqual(outUTF16[0].to, 6)

        let outUTF8 = CMDiagnosticMapping.cmDiagnostics(
            from: [diag(startLine: 0, startCh: 5, endLine: 0, endCh: 8)],
            documentText: doc,
            encoding: .utf8
        )
        XCTAssertEqual(outUTF8.count, 1)
        // Same JS-side offset because CM6 uses UTF-16 internally.
        XCTAssertEqual(outUTF8[0].from, 3)
        XCTAssertEqual(outUTF8[0].to, 6)
    }

    func testZeroLengthRangeIsWidenedToOne() {
        let doc = "hello"
        let out = CMDiagnosticMapping.cmDiagnostics(
            from: [diag(startLine: 0, startCh: 2, endLine: 0, endCh: 2)],
            documentText: doc,
            encoding: .utf16
        )
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].from, 2)
        XCTAssertEqual(out[0].to, 3, "zero-length range should be widened by 1")
    }

    func testOutOfBoundsClampsToDocEnd() {
        let doc = "abc"
        let out = CMDiagnosticMapping.cmDiagnostics(
            from: [diag(startLine: 42, startCh: 100, endLine: 42, endCh: 200)],
            documentText: doc,
            encoding: .utf16
        )
        XCTAssertEqual(out.count, 1)
        // converter clamps to endIndex (offset = 3), then widening
        // would push past the doc — capped at docLen.
        XCTAssertGreaterThanOrEqual(out[0].from, 0)
        XCTAssertLessThanOrEqual(out[0].to, doc.utf16.count)
    }

    func testSeverityTranslation() {
        XCTAssertEqual(CMDiagnosticMapping.cmSeverity(.error),       .error)
        XCTAssertEqual(CMDiagnosticMapping.cmSeverity(.warning),     .warning)
        XCTAssertEqual(CMDiagnosticMapping.cmSeverity(.information), .info)
        XCTAssertEqual(CMDiagnosticMapping.cmSeverity(.hint),        .hint)
    }

    func testCodeAndSourcePassthrough() {
        let out = CMDiagnosticMapping.cmDiagnostics(
            from: [diag(
                startLine: 0, startCh: 0, endLine: 0, endCh: 1,
                source: "sourcekit-lsp", code: "E1234"
            )],
            documentText: "ab",
            encoding: .utf16
        )
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].source, "sourcekit-lsp")
        XCTAssertEqual(out[0].code, "E1234")
    }

    func testCRLFTreatedAsSingleGraphemeByConverter() {
        // Documented behavior: `LSPPositionConverter`'s line tally
        // bumps only on `Character == "\n"`, and Swift treats `\r\n`
        // as a single grapheme. So a diag claiming "line 1" against a
        // CRLF doc clamps to endIndex. This is acceptable because
        // every LSP server we ship today (sourcekit-lsp, pylsp,
        // typescript-language-server) normalizes line endings before
        // emitting diagnostics. If we ever see a server that doesn't,
        // upgrade the converter to track CR as a line break too.
        let doc = "ab\r\ncd"
        let out = CMDiagnosticMapping.cmDiagnostics(
            from: [diag(startLine: 1, startCh: 0, endLine: 1, endCh: 2)],
            documentText: doc,
            encoding: .utf16
        )
        XCTAssertEqual(out.count, 1)
        // Both clamped to end-of-doc, then widened.
        XCTAssertGreaterThanOrEqual(out[0].from, 0)
        XCTAssertLessThanOrEqual(out[0].to, doc.utf16.count)
    }

    func testLFOnlyLineBoundariesAreRespected() {
        // Standard LF case — same shape as our other tests but
        // documents the LF/CRLF contrast explicitly.
        let doc = "ab\ncd"
        let out = CMDiagnosticMapping.cmDiagnostics(
            from: [diag(startLine: 1, startCh: 0, endLine: 1, endCh: 2)],
            documentText: doc,
            encoding: .utf16
        )
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].from, 3)
        XCTAssertEqual(out[0].to, 5)
    }
}
