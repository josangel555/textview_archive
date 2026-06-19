import XCTest
@testable import ViewerCore

/// `HTMLSanitizer` defends `HTMLRenderer.visitHTMLBlock` /
/// `visitInlineHTML` against script injection / event handler / URL
/// scheme attacks (finding §2.1 in
/// `docs/code-review/SECURITY_CONCURRENCY_2026-05-25.md`). These tests
/// pin both the rejection rules (XSS payloads stripped) and the
/// positive rules (legitimate authored HTML preserved).
final class HTMLSanitizerTests: XCTestCase {

    // MARK: - Negative (strip)

    func test_stripsScriptElement() {
        let raw = "<p>hi</p><script>alert(1)</script><p>bye</p>"
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("<script"))
        XCTAssertFalse(out.contains("alert"))
        XCTAssertTrue(out.contains("<p>hi</p>"))
        XCTAssertTrue(out.contains("<p>bye</p>"))
    }

    func test_stripsScriptElement_withAttributes() {
        let raw = #"<script type="text/javascript" defer>evil()</script>after"#
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("script"))
        XCTAssertFalse(out.contains("evil"))
        XCTAssertTrue(out.contains("after"))
    }

    func test_stripsScriptElement_caseInsensitive() {
        let raw = "<SCRIPT>x</SCRIPT><ScRipT>y</ScRiPt>"
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("script"))
        XCTAssertFalse(out.contains("x"))
        XCTAssertFalse(out.contains("y"))
    }

    func test_stripsIframe() {
        let raw = "<iframe src='https://evil'></iframe><div>ok</div>"
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("iframe"))
        XCTAssertTrue(out.contains("<div>ok</div>"))
    }

    func test_stripsForm() {
        let raw = "<form action='/x'><input name='u'></form><p>fine</p>"
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("<form"))
        XCTAssertFalse(out.lowercased().contains("<input"))
        XCTAssertTrue(out.contains("<p>fine</p>"))
    }

    func test_stripsObjectAndEmbed() {
        let raw = "<object data='x.swf'></object><embed src='y.swf'/>"
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("<object"))
        XCTAssertFalse(out.lowercased().contains("<embed"))
    }

    func test_stripsStyleElement() {
        // <style> can pull off-page exfiltration via CSS content tricks
        // — block it. The renderer's own CSS is injected as a separate
        // <style> block from the host page, not from markdown.
        let raw = "<style>body{display:none}</style>hello"
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("<style"))
        XCTAssertTrue(out.contains("hello"))
    }

    func test_stripsMetaAndLink() {
        let raw = "<meta http-equiv='refresh' content='0;url=https://evil'><link rel='stylesheet' href='x'>"
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("<meta"))
        XCTAssertFalse(out.lowercased().contains("<link"))
    }

    func test_stripsOnEventHandlers() {
        let raw = "<div onclick=\"alert(1)\" onload='x()'>hi</div>"
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("onclick"))
        XCTAssertFalse(out.lowercased().contains("onload"))
        XCTAssertFalse(out.contains("alert"))
        XCTAssertTrue(out.contains("<div"))
        XCTAssertTrue(out.contains(">hi</div>"))
    }

    func test_stripsOnEventHandlers_bareValue() {
        let raw = "<img src='x' onerror=alert(1)>"
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("onerror"))
    }

    func test_stripsSvgOnload() {
        // The CommonMark spec docs example for finding §2.1.
        let raw = "<svg onload='alert(1)'></svg>"
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("onload"))
    }

    func test_neutralizesJavascriptURL_inHref() {
        let raw = #"<a href="javascript:alert(1)">x</a>"#
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("javascript:"))
        XCTAssertTrue(out.contains("about:blank"))
    }

    func test_neutralizesVbscriptURL_inHref() {
        let raw = #"<a href='vbscript:msgbox(1)'>x</a>"#
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("vbscript:"))
    }

    func test_neutralizesJavascriptURL_inSrc() {
        let raw = #"<iframe src="javascript:alert(1)"></iframe>"#
        let out = HTMLSanitizer.sanitize(raw)
        // The iframe gets dropped wholesale, so neither attribute
        // value survives. This is the intent: belt-and-suspenders.
        XCTAssertFalse(out.lowercased().contains("javascript:"))
        XCTAssertFalse(out.lowercased().contains("<iframe"))
    }

    // MARK: - H1b: regex bypass hardening (TSK-967)

    // (a) event-handler anchor: handler abutting a closing quote.

    func test_h1b_stripsHandler_abuttingClosingQuote() {
        // `href="x"onclick=…` — no whitespace before `on`, so the old
        // `\s+on` anchor missed it. The handler is a live attribute.
        let raw = #"<a href="x"onclick="alert(1)">y</a>"#
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("onclick"),
                       "quote-adjacent handler must be stripped, got: \(out)")
        XCTAssertFalse(out.contains("alert"))
        // The legitimate href and link survive.
        XCTAssertTrue(out.contains(#"href="x""#))
        XCTAssertTrue(out.contains(">y</a>"))
    }

    func test_h1b_stripsHandler_abuttingSingleQuote() {
        let raw = #"<a href='x'onmouseover='steal()'>y</a>"#
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("onmouseover"))
        XCTAssertFalse(out.contains("steal"))
        XCTAssertTrue(out.contains("href='x'"))
    }

    // (b) event-handler anchor: handler separated by `/`.

    func test_h1b_stripsHandler_afterSlash() {
        // `<svg/onload=…>` — `/` is an attribute separator in HTML, so
        // the handler is live; `\s+on` missed it.
        let raw = "<svg/onload='alert(1)'>"
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("onload"),
                       "slash-adjacent handler must be stripped, got: \(out)")
        XCTAssertFalse(out.contains("alert"))
    }

    func test_h1b_stripsTwoAdjacentHandlers() {
        // Two handlers back-to-back, the second abutting the first's
        // closing quote — the multi-pass loop must catch both.
        let raw = #"<div onclick="a()"onmouseover="b()">x</div>"#
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("onclick"))
        XCTAssertFalse(out.lowercased().contains("onmouseover"))
        XCTAssertFalse(out.contains("a()"))
        XCTAssertFalse(out.contains("b()"))
        XCTAssertTrue(out.contains(">x</div>"))
    }

    // (c) javascript-URL scheme: numeric / named entity in the scheme.

    func test_h1b_neutralizesNumericEntityScheme_hex() {
        // `&#x6a;` == `j` → browser decodes to `javascript:`.
        let raw = #"<a href="&#x6a;avascript:alert(1)">y</a>"#
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.contains("&#x6a;"),
                       "entity-obfuscated scheme must be rewritten, got: \(out)")
        XCTAssertFalse(out.contains("alert"))
        XCTAssertTrue(out.contains("about:blank"))
    }

    func test_h1b_neutralizesNumericEntityScheme_decimal() {
        // `&#106;` == `j`.
        let raw = #"<a href="&#106;avascript:alert(1)">y</a>"#
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.contains("&#106;"))
        XCTAssertFalse(out.contains("alert"))
        XCTAssertTrue(out.contains("about:blank"))
    }

    func test_h1b_neutralizesNamedEntityScheme() {
        // `&Tab;` prefix decodes to a tab, leaving `javascript:`.
        let raw = #"<a href="&Tab;javascript:alert(1)">y</a>"#
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.contains("alert"),
                       "named-entity-prefixed scheme must be rewritten, got: \(out)")
        XCTAssertTrue(out.contains("about:blank"))
    }

    // (d) javascript-URL scheme: embedded ASCII control char.

    func test_h1b_neutralizesTabControlInScheme() {
        // A literal TAB embedded in the scheme — browsers strip it.
        let raw = "<a href=\"jav\tascript:alert(1)\">y</a>"
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.contains("alert"),
                       "tab-split scheme must be rewritten, got: \(out)")
        XCTAssertTrue(out.contains("about:blank"))
    }

    func test_h1b_neutralizesNewlineControlInScheme() {
        let raw = "<a href=\"jav\nascript:alert(1)\">y</a>"
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.contains("alert"),
                       "newline-split scheme must be rewritten, got: \(out)")
        XCTAssertTrue(out.contains("about:blank"))
    }

    // (e) H1b must NOT over-reach: legitimate values survive untouched.

    func test_h1b_preservesHttpsHref() {
        let raw = #"<a href="https://example.com/p?a=b">link</a>"#
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertEqual(out, raw)
    }

    func test_h1b_preservesDataImageSrc() {
        // `data:image/png` is a legitimate inline-image scheme and must
        // NOT be neutralized (only `data:text/html` is dangerous).
        let raw = #"<img src="data:image/png;base64,iVBORw0KGgo=">"#
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertTrue(out.contains("data:image/png"),
                      "legit data:image must survive, got: \(out)")
        XCTAssertFalse(out.contains("about:blank"))
    }

    func test_h1b_neutralizesDataTextHtml() {
        let raw = #"<a href="data:text/html,<script>alert(1)</script>">y</a>"#
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("data:text/html"))
        XCTAssertTrue(out.contains("about:blank"))
    }

    func test_h1b_preservesRelativePathWithColon() {
        // A relative path is not a scheme even though a `:` may appear
        // later; the leading token before the first `:` must be a real
        // scheme token to count.
        let raw = #"<a href="page.html#a:b">link</a>"#
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertEqual(out, raw)
    }

    func test_h1b_preservesAttributeWithTrailingAttrs() {
        // Ensure tokenizer doesn't drop following attributes when it
        // rewrites a URL attr.
        let raw = #"<a href="javascript:x" class="btn" id="go">y</a>"#
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("javascript:"))
        XCTAssertTrue(out.contains(#"class="btn""#))
        XCTAssertTrue(out.contains(#"id="go""#))
        XCTAssertTrue(out.contains("about:blank"))
    }

    func test_h1b_preservesNonURLEntityAttr() {
        // An entity in a non-URL attribute must be left exactly as-is.
        let raw = #"<div data-x="&#x6a;avascript:foo">x</div>"#
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertEqual(out, raw)
    }

    // MARK: - Positive (preserve)

    func test_preservesPlainAuthoredHTML() {
        let raw = "<figure><img src='ok.png' alt='ok'/><figcaption>caption</figcaption></figure>"
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertTrue(out.contains("<figure>"))
        XCTAssertTrue(out.contains("<img"))
        XCTAssertTrue(out.contains("caption"))
    }

    func test_preservesDivAndSpan() {
        let raw = "<div class='note'><span style='color:red'>hi</span></div>"
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertTrue(out.contains("<div"))
        XCTAssertTrue(out.contains("<span"))
        XCTAssertTrue(out.contains("hi"))
    }

    func test_preservesTables() {
        let raw = "<table><tr><th>k</th></tr><tr><td>v</td></tr></table>"
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertEqual(out, raw)
    }

    func test_preservesAside() {
        let raw = "<aside><p>note</p></aside>"
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertEqual(out, raw)
    }

    func test_preservesLiteralOnclickInTextNode() {
        // We must NOT scrub "onclick" outside of tag attribute
        // context — a code-block paragraph explaining XSS would
        // legitimately contain the word.
        let raw = "<p>The onclick= attribute is for handlers.</p>"
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertTrue(out.contains("onclick="))
    }

    func test_preservesNonURLAttribute() {
        // `data-x="javascript:foo"` is not a navigation-bearing attr
        // (no `href`/`src`), so we leave it alone — it can't cause
        // navigation without script, and we already strip scripts.
        let raw = #"<div data-x="javascript:foo">x</div>"#
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertEqual(out, raw)
    }

    // MARK: - Edge cases

    func test_emptyInput() {
        XCTAssertEqual(HTMLSanitizer.sanitize(""), "")
    }

    func test_plainText() {
        let raw = "this is just text, no tags"
        XCTAssertEqual(HTMLSanitizer.sanitize(raw), raw)
    }

    func test_multilineScriptBlock() {
        let raw = """
        <p>start</p>
        <script>
          var x = 1;
          alert(x);
        </script>
        <p>end</p>
        """
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("script"))
        XCTAssertFalse(out.contains("alert"))
        XCTAssertTrue(out.contains("start"))
        XCTAssertTrue(out.contains("end"))
    }
}
