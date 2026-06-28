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

    func test_unicodeControl_withHexByteFallback_word() {
        // Word emits \uNNNN then a \'XX codepage byte as the fallback (not "?").
        // The euro sign (code point 8364) emits \uNNNN then \'80 (Win-1252) —
        // the \'80 must be consumed as the fallback, NOT emitted as a stray byte.
        XCTAssertEqual(RtfTextExtractor.plainText("{\\rtf1 \\u8364\\'80}"), "€")
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

    // MARK: - Audit-harden: untrusted-RTF edge cases (2026-06-27)

    func test_unicode_surrogatePair_astralChar() {
        // RTF encodes astral codepoints (>U+FFFF) as a UTF-16 surrogate pair, each a
        // signed-16-bit \uN. U+1F600 😀 = high 0xD83D (−10179) + low 0xDE00 (−8704),
        // each with a "?" \uc1 fallback. They must COMBINE into the astral scalar,
        // not be dropped as invalid lone surrogates.
        XCTAssertEqual(RtfTextExtractor.plainText(#"{\rtf1 \u-10179?\u-8704?}"#), "😀")
    }

    func test_unicodeControl_ucSkip_greaterThanOne() {
        // \uc2 → each \uN's fallback is TWO tokens. \u233 = é, then "??" skipped, X kept.
        XCTAssertEqual(RtfTextExtractor.plainText(#"{\rtf1 \uc2 \u233??X}"#), "éX")
    }

    func test_negativeUnicode_bmp() {
        // \u-4096 → signed-16-bit → U+F000 (private-use). \uc0 = no fallback to skip.
        XCTAssertEqual(RtfTextExtractor.plainText(#"{\rtf1 \uc0 \u-4096 X}"#), "\u{F000}X")
    }

    func test_malformed_unbalancedBraces_doesNotCrash() {
        // Stray closing / unclosed groups must not crash or lose text (untrusted input).
        XCTAssertEqual(RtfTextExtractor.plainText(#"{\rtf1 A}}}B"#), "AB")
        XCTAssertEqual(RtfTextExtractor.plainText(#"{\rtf1 {{{C"#), "C")
    }
}
