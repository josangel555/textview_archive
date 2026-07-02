import XCTest
@testable import ViewerCore

/// TSK-1327: a rich-paste of a code block (`<pre>` / `<pre><code>`, the common
/// browser/doc copy) must survive as a real fenced Markdown code block with its
/// newlines intact — before this it collapsed into invalid inline-code-spanning-
/// newlines. HTML→Markdown is the LIVE universalPaste converter path.
final class RichTextCodeBlockPasteTests: XCTestCase {
    func test_preCode_becomesFencedBlock_preservingNewlines() {
        let md = RichTextHTMLParser.markdown(fromHTML: "<pre><code>let x = 1\nlet y = 2\n</code></pre>")
        XCTAssertEqual(md, "```\nlet x = 1\nlet y = 2\n```",
                       "code paste must be a fenced block, newlines preserved; got [\(md)]")
    }

    func test_barePre_becomesFencedBlock() {
        let md = RichTextHTMLParser.markdown(fromHTML: "<pre>a\n  b\nc</pre>")
        XCTAssertEqual(md, "```\na\n  b\nc\n```", "indentation + newlines preserved; got [\(md)]")
    }

    func test_codeContainingBackticks_getsALongerFence() {
        // Code with a ``` run inside must be fenced with 4 backticks (can't close early).
        let md = RichTextHTMLParser.markdown(fromHTML: "<pre>a ``` b</pre>")
        XCTAssertTrue(md.hasPrefix("````") && md.hasSuffix("````"),
                      "fence must be longer than the inner backtick run; got [\(md)]")
    }

    func test_serializerRoundTrip_codeBlock() {
        // The IR → Markdown serializer emits a valid fence for a codeBlock.
        let doc = RichTextDocument([.codeBlock("x = 1")])
        XCTAssertEqual(RichTextSerializer.serialize(doc), "```\nx = 1\n```")
    }
}
