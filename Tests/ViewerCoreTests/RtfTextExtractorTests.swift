import XCTest
@testable import ViewerCore

/// RTF → plain-text extraction (read counterpart to RtfExporter). Host-tested
/// with teeth on the tricky control sequences.
final class RtfTextExtractorTests: XCTestCase {

    func test_basic_textOnly() {
        XCTAssertEqual(RtfTextExtractor.plainText(#"{\rtf1\ansi Hello}"#), "Hello")
    }

    func test_formatting_isStripped_textKept() {
        XCTAssertEqual(RtfTextExtractor.plainText(#"{\rtf1\ansi\b Hi\b0}"#), "Hi")
    }

    func test_par_becomesNewline() {
        XCTAssertEqual(RtfTextExtractor.plainText(#"{\rtf1 a\par b}"#), "a\nb")
    }

    func test_escapedMetacharacters() {
        XCTAssertEqual(RtfTextExtractor.plainText(#"{\rtf1 a\\b\{c\}}"#), #"a\b{c}"#)
    }

    func test_unicodeControl_withFallbackSkip() {
        // \u233 = é, then \uc1 default → the single fallback char "?" is skipped.
        XCTAssertEqual(RtfTextExtractor.plainText(#"{\rtf1 caf\u233?}"#), "café")
    }

    func test_hexEscape() {
        // \'41 = 'A', \'42 = 'B'
        XCTAssertEqual(RtfTextExtractor.plainText(#"{\rtf1 \'41\'42}"#), "AB")
    }

    func test_fontTable_destinationIsDropped() {
        let rtf = #"{\rtf1{\fonttbl{\f0 Helvetica;}}Hello}"#
        XCTAssertEqual(RtfTextExtractor.plainText(rtf), "Hello")
    }

    func test_ignorableDestination_starGroup_isDropped() {
        let rtf = #"{\rtf1{\*\generator Word 16}Body}"#
        XCTAssertEqual(RtfTextExtractor.plainText(rtf), "Body")
    }

    func test_roundTrip_withExporter() {
        // Export a paragraph, read it back — the text survives.
        let rtf = RtfExporter.export([.paragraph([RtfRun("Hello world")])])
        XCTAssertTrue(RtfTextExtractor.plainText(rtf).contains("Hello world"),
                      "RtfExporter output reads back through RtfTextExtractor")
    }
}
