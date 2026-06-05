import XCTest
@testable import ViewerCore

/// Regression for the S3 security finding "HTMLSanitizer.stripElement
/// attribute scan is not quote-aware ([^>]*?)" (AUDIT_BUGS.md,
/// `Sources/ViewerCore/HTMLSanitizer.swift:76`).
///
/// The original open-tag regex used `[^>]*?` for the attribute run, so a
/// `>` inside a quoted attribute value terminated the match at the wrong
/// `>` (the bare-`>` alternative fired). That left the dropped element's
/// residual tail as live markup re-parsed by WebKit as content. The fix
/// routes `stripElement` through the same quote-aware `tagEnd` tokenizer
/// already used by `rewriteTagBodies`/`tagEnd` (WV-1), so the open tag's
/// real boundary is found structurally, not at the first literal `>`.
///
/// Probes mirror the exact reproductions recorded in the finding.
final class Audit_Sources_ViewerCore_HTMLSanitizer_swift_QuoteAwareElementStripTests: XCTestCase {

    // MARK: - The finding's recorded reproductions

    /// `<script foo="a>b">EVIL()` previously under-matched at the `>`
    /// inside `foo="a>b"`, leaking `b">EVIL()` as live text.
    func test_scriptWithGtInQuotedAttr_doesNotLeakTail() {
        let raw = #"<script foo="a>b">EVIL()</script>"#
        let out = HTMLSanitizer.stripElement(named: "script", in: raw)
        XCTAssertFalse(out.contains("EVIL"), "leaked element tail: \(out)")
        XCTAssertFalse(out.contains("b\">"), "leaked residual attr markup: \(out)")
        XCTAssertEqual(out, "")
    }

    /// `<iframe src="a>"><img src=x onerror=alert(1)>` previously left
    /// `"><img src=x onerror=alert(1)>` after the element strip.
    func test_iframeWithGtInQuotedAttr_doesNotLeakResidualImg() {
        let raw = #"<iframe src="a>"><img src=x onerror=alert(1)>"#
        let out = HTMLSanitizer.stripElement(named: "iframe", in: raw)
        // The whole iframe (open tag through its real boundary) is gone;
        // only the legitimately separate <img> survives this pass.
        XCTAssertFalse(out.contains("\">"), "leaked residual attr markup: \(out)")
        XCTAssertFalse(out.lowercased().contains("iframe"))
        XCTAssertEqual(out, "<img src=x onerror=alert(1)>")
    }

    /// End-to-end through the public entry: the residual `onerror=` must
    /// not survive (belt-and-suspenders — later passes also scrub it, but
    /// the element layer should not have emitted it in the first place).
    func test_sanitize_iframeWithGtInQuotedAttr_noLiveHandler() {
        let raw = #"<iframe src="a>"><img src=x onerror=alert(1)>ok"#
        let out = HTMLSanitizer.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("onerror="),
                       "live event handler survived: \(out)")
        XCTAssertFalse(out.lowercased().contains("iframe"))
        XCTAssertTrue(out.contains("ok"))
    }

    /// Single-quoted variant of the same vector.
    func test_styleWithGtInSingleQuotedAttr_doesNotLeakTail() {
        let raw = "<style data-x='a>b'>body{}</style>tail"
        let out = HTMLSanitizer.stripElement(named: "style", in: raw)
        XCTAssertFalse(out.contains("body{}"), "leaked element body: \(out)")
        XCTAssertEqual(out, "tail")
    }

    // MARK: - Regressions guarding the rewrite's parity with the old regex

    func test_plainElement_stillFullyStripped() {
        let raw = "<p>hi</p><script>alert(1)</script><p>bye</p>"
        let out = HTMLSanitizer.stripElement(named: "script", in: raw)
        XCTAssertEqual(out, "<p>hi</p><p>bye</p>")
    }

    func test_caseInsensitive_openAndClose() {
        let raw = "<SCRIPT>x</ScRiPt>after"
        let out = HTMLSanitizer.stripElement(named: "script", in: raw)
        XCTAssertEqual(out, "after")
    }

    func test_selfClosing_dropsOpenTagOnly() {
        let raw = "<input value=\"x\" />keep"
        let out = HTMLSanitizer.stripElement(named: "input", in: raw)
        XCTAssertEqual(out, "keep")
    }

    func test_selfClosing_withGtInQuotedAttr() {
        let raw = #"<input value="a>b" />keep"#
        let out = HTMLSanitizer.stripElement(named: "input", in: raw)
        XCTAssertEqual(out, "keep")
    }

    /// Unterminated open tag (no `>` at all) is treated as literal `<`
    /// text — the later passes / CSP backstop it. Matches `tagEnd==nil`.
    func test_unterminatedOpenTag_leftAsLiteral() {
        let raw = "before<script foo=\"a"
        let out = HTMLSanitizer.stripElement(named: "script", in: raw)
        XCTAssertEqual(out, raw)
    }

    /// Open tag with no matching close drops just the open tag (the old
    /// bare-`>` fallback). Body text after it survives.
    func test_openTagNoClose_dropsOpenTagOnly() {
        let raw = "<iframe src=\"x\">tail"
        let out = HTMLSanitizer.stripElement(named: "iframe", in: raw)
        XCTAssertEqual(out, "tail")
    }

    /// Word boundary: `<scriptx>` is NOT a `<script>` and must survive.
    func test_wordBoundary_doesNotMatchPrefix() {
        let raw = "<scriptx>keep</scriptx>"
        let out = HTMLSanitizer.stripElement(named: "script", in: raw)
        XCTAssertEqual(out, raw)
    }

    /// Sibling element of the same name after the dropped one is also
    /// dropped (the scan continues past the first close).
    func test_twoSiblingElements_bothStripped() {
        let raw = "a<style>x</style>b<style>y</style>c"
        let out = HTMLSanitizer.stripElement(named: "style", in: raw)
        XCTAssertEqual(out, "abc")
    }

    /// A literal `<` in body text that is not an opening tag is preserved
    /// verbatim by the manual scan.
    func test_strayLessThan_inBodyPreserved() {
        let raw = "1 < 2 and 3 > 2"
        let out = HTMLSanitizer.stripElement(named: "script", in: raw)
        XCTAssertEqual(out, raw)
    }
}
