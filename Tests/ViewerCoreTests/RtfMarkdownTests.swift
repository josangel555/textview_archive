import XCTest
@testable import ViewerCore

/// TSK-1338 — RTF renders WITH formatting: the RtfTextExtractor.markdown path
/// preserves bold/italic + paragraphs (vs. plainText's flat output), reusing the
/// escaping RichTextSerializer so .rtf renders instead of showing flat text.
final class RtfMarkdownTests: XCTestCase {

    func test_markdown_preservesBoldAndItalic() {
        let rtf = "{\\rtf1\\ansi\\deff0 plain \\b bold\\b0  \\i italic\\i0 .}"
        let md = RtfTextExtractor.markdown(rtf)
        XCTAssertTrue(md.contains("**bold**"), "\\b run → bold (got: \(md))")
        XCTAssertTrue(md.contains("*italic*"), "\\i run → italic (got: \(md))")
        XCTAssertTrue(md.contains("plain"), "plain text preserved")
    }

    func test_markdown_paragraphsFromPar() {
        let md = RtfTextExtractor.markdown("{\\rtf1 first\\par second}")
        XCTAssertTrue(md.contains("first") && md.contains("second"),
                      "\\par splits paragraphs, both preserved (got: \(md))")
    }

    func test_markdown_escapesBodyText() {
        // Body '#'/'*' must be escaped, not become markdown structure (the safety
        // the RichTextSerializer buys over naive string templating).
        let md = RtfTextExtractor.markdown("{\\rtf1 # not a heading and *not italic*}")
        XCTAssertFalse(md.hasPrefix("# "), "body '#' escaped, not a heading (got: \(md))")
        XCTAssertTrue(md.contains("not a heading"), "text preserved")
    }

    func test_plainText_staysFlat_notMarkdown_afterRefactor() {
        // The callback-scanner refactor must keep plainText FLAT — bold/italic
        // control words stripped, NO markdown markers leaking in. (Exact-output
        // parity is covered comprehensively by RtfTextExtractorTests.)
        let txt = RtfTextExtractor.plainText("{\\rtf1\\ansi\\deff0 Hello \\b World\\b0 !}")
        XCTAssertFalse(txt.contains("**"), "plainText stays flat (no markdown markers)")
        XCTAssertTrue(txt.contains("Hello") && txt.contains("World"), "text preserved")
    }
}
