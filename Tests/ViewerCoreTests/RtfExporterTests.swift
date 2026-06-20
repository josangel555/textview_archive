import XCTest
@testable import ViewerCore

/// TSK-680: RTF export foundation. Pure string generation — host-tested with
/// teeth (escaping edge cases + control-word emission).
final class RtfExporterTests: XCTestCase {

    // MARK: escape

    func test_escape_metacharacters() {
        XCTAssertEqual(RtfExporter.escape(#"a\b{c}d"#), #"a\\b\{c\}d"#)
    }

    func test_escape_asciiUnchanged() {
        XCTAssertEqual(RtfExporter.escape("Hello, world! 42"), "Hello, world! 42")
    }

    func test_escape_tabAndNewline_becomeControlWords() {
        XCTAssertEqual(RtfExporter.escape("a\tb\nc"), #"a\tab b\line c"#)
    }

    func test_escape_nonAscii_bmp() {
        // é = U+00E9 = 233 → \u233?
        XCTAssertEqual(RtfExporter.escape("café"), #"caf\u233?"#)
    }

    func test_escape_astral_emitsSurrogatePair() {
        // 😀 = U+1F600 → UTF-16 surrogates 0xD83D/0xDE00 → signed \u-10179?\u-8704?
        let out = RtfExporter.escape("😀")
        XCTAssertEqual(out, #"\u-10179?\u-8704?"#)
    }

    // MARK: export

    func test_export_wrapsDocumentWithHeaderAndFontTable() {
        let rtf = RtfExporter.export([.paragraph([RtfRun("hi")])])
        XCTAssertTrue(rtf.hasPrefix(#"{\rtf1\ansi"#), "RTF version header")
        XCTAssertTrue(rtf.contains(#"\fonttbl"#), "declares a font table")
        XCTAssertTrue(rtf.hasSuffix("}"), "document is brace-closed")
    }

    func test_export_boldItalicMonoRuns() {
        let rtf = RtfExporter.export([.paragraph([
            RtfRun("B", bold: true),
            RtfRun("I", italic: true),
            RtfRun("C", mono: true),
        ])])
        XCTAssertTrue(rtf.contains(#"\b B\b0 "#), "bold run brackets with \\b…\\b0")
        XCTAssertTrue(rtf.contains(#"\i I\i0 "#), "italic run brackets with \\i…\\i0")
        XCTAssertTrue(rtf.contains(#"{\f1 C}"#), "mono run switches to font 1 in a group")
        XCTAssertTrue(rtf.contains(#"\par"#), "paragraph terminator present")
    }

    func test_export_heading_isBoldAndLarger() {
        let rtf = RtfExporter.export([.heading(level: 1, [RtfRun("Title")])])
        XCTAssertTrue(rtf.contains(#"\b\fs36 "#), "h1 is bold at 18pt (\\fs36)")
        XCTAssertTrue(rtf.contains("Title"))
    }

    func test_export_headingSizesDecreaseWithLevel_flooring() {
        XCTAssertEqual(RtfExporter.headingHalfPoints(1), 36)
        XCTAssertEqual(RtfExporter.headingHalfPoints(2), 32)
        XCTAssertEqual(RtfExporter.headingHalfPoints(4), 24)
        XCTAssertEqual(RtfExporter.headingHalfPoints(6), 24, "floors at 12pt")
    }

    func test_export_codeBlock_usesMonoFontAndEscapes() {
        let rtf = RtfExporter.export([.codeBlock("let x = {1}")])
        XCTAssertTrue(rtf.contains(#"{\f1 let x = \{1\}}"#),
                      "code block is mono + RTF-escaped")
    }
}
