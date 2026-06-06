import AppKit
import XCTest
@testable import ViewerUI

/// Host-safe coverage for `LSPMarkdownRenderer` — the `String →
/// NSAttributedString` transform behind the LSP hover popover. It is pure
/// (no live view / window / layout / event loop; AppKit fonts + attributed
/// strings only) and shipped with zero tests. We assert the observable
/// contract: the plain vs markdown branch, fenced-code-block toggling +
/// styling, inline bold/italic/code trait bridging, and the trailing-
/// newline trim — not the internal `NSInlinePresentationIntent` decoding.
@MainActor
final class LSPMarkdownRendererTests: XCTestCase {

    // MARK: - helpers

    /// First font applied over the run that begins at `substring`'s start.
    private func font(_ a: NSAttributedString, over substring: String,
                      file: StaticString = #filePath, line: UInt = #line) -> NSFont? {
        let r = (a.string as NSString).range(of: substring)
        guard r.location != NSNotFound else {
            XCTFail("substring \(substring.debugDescription) not found in \(a.string.debugDescription)",
                    file: file, line: line)
            return nil
        }
        return a.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
    }

    private func backgroundColor(_ a: NSAttributedString, over substring: String) -> NSColor? {
        let r = (a.string as NSString).range(of: substring)
        guard r.location != NSNotFound else { return nil }
        return a.attribute(.backgroundColor, at: r.location, effectiveRange: nil) as? NSColor
    }

    private func render(_ s: String, markdown: Bool = true) -> NSAttributedString {
        LSPMarkdownRenderer.attributedString(from: s, isMarkdown: markdown)
    }

    // MARK: - plain (non-markdown) path

    func test_plain_preservesTextVerbatim_andDoesNotInterpretMarkdown() {
        // isMarkdown:false must NOT consume the ** markers — verbatim text.
        let a = render("**not bold** _nor italic_", markdown: false)
        XCTAssertEqual(a.string, "**not bold** _nor italic_")
        let f = font(a, over: "not")
        XCTAssertEqual(f?.isFixedPitch, false)
        XCTAssertFalse(f?.fontDescriptor.symbolicTraits.contains(.bold) ?? true,
                       "plain path must not bold anything")
    }

    func test_plain_usesSystemFontAndLabelColor() {
        let a = render("hello", markdown: false)
        let f = a.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(f, NSFont.systemFont(ofSize: NSFont.systemFontSize))
        let c = a.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(c, NSColor.labelColor)
    }

    func test_plain_emptyString_isEmpty() {
        XCTAssertEqual(render("", markdown: false).string, "")
    }

    // MARK: - fenced code blocks

    func test_fencedCode_stripsFenceMarkers_andStylesCodeLines() {
        let a = render("before\n```\nlet x = 1\n```\nafter")
        // Fence markers are consumed; body + code text survive.
        XCTAssertFalse(a.string.contains("```"), "``` fence markers must be stripped")
        XCTAssertTrue(a.string.contains("let x = 1"))
        XCTAssertTrue(a.string.contains("before"))
        XCTAssertTrue(a.string.contains("after"))
        // The code line is uniquely styled: fixed-pitch font + a background.
        XCTAssertEqual(font(a, over: "let x = 1")?.isFixedPitch, true,
                       "fenced code uses a monospaced font")
        XCTAssertNotNil(backgroundColor(a, over: "let x = 1"),
                        "fenced code carries a background fill")
        // Body text is NOT code-styled.
        XCTAssertEqual(font(a, over: "before")?.isFixedPitch, false)
        XCTAssertNil(backgroundColor(a, over: "before"))
    }

    func test_fencedCode_multipleLines_allStyled() {
        let a = render("```\nline one\nline two\n```")
        XCTAssertEqual(font(a, over: "line one")?.isFixedPitch, true)
        XCTAssertEqual(font(a, over: "line two")?.isFixedPitch, true)
        XCTAssertNotNil(backgroundColor(a, over: "line two"))
    }

    // MARK: - inline trait bridging

    func test_inlineBold_carriesBoldTrait() {
        let a = render("**bold** normal")
        XCTAssertEqual(a.string, "bold normal", "** markers consumed")
        XCTAssertTrue(font(a, over: "bold")?.fontDescriptor.symbolicTraits.contains(.bold) ?? false,
                      "strong emphasis must bridge to the .bold font trait")
        XCTAssertFalse(font(a, over: "normal")?.fontDescriptor.symbolicTraits.contains(.bold) ?? true,
                       "plain run stays unbolded")
    }

    func test_inlineItalic_carriesItalicTrait() {
        let a = render("*slanted* upright")
        XCTAssertEqual(a.string, "slanted upright")
        XCTAssertTrue(font(a, over: "slanted")?.fontDescriptor.symbolicTraits.contains(.italic) ?? false,
                      "emphasis must bridge to the .italic font trait")
    }

    func test_inlineCode_isMonospaced() {
        let a = render("call `fn()` here")
        XCTAssertEqual(a.string, "call fn() here", "backtick markers consumed")
        XCTAssertEqual(font(a, over: "fn()")?.isFixedPitch, true,
                       "inline code span uses a monospaced font")
    }

    // MARK: - trailing-newline trim / empties

    func test_trailingNewline_trimmed() {
        // A single paragraph appends a "\n" internally; the tidy-up trims it.
        XCTAssertEqual(render("hello").string, "hello")
    }

    func test_emptyMarkdown_isEmpty_noCrash() {
        XCTAssertEqual(render("").string, "")
    }

    func test_codeBlockThenTrailingBody_trimsOnlyTheLastNewline() {
        let a = render("```\nx\n```\ntail")
        XCTAssertTrue(a.string.hasSuffix("tail"), "no dangling trailing newline after body")
        XCTAssertFalse(a.string.hasSuffix("\n"))
    }
}
