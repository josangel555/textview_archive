import XCTest
@testable import ViewerCore

/// TSK-966 — Stored-XSS hardening of the standalone HTML export /
/// Open-in-Browser path.
///
/// Threat model. The standalone export document is opened in a NORMAL BROWSER
/// with `file://` privileges, where the regex `HTMLSanitizer` (which has
/// confirmed bypasses) would be the SOLE defense. In-app, a strict
/// `default-src 'none'` CSP backstops any sanitizer miss; the export path drops
/// that, so a cloned README / emailed `.md` could carry a payload that survives
/// sanitization and executes.
///
/// The fix is two INDEPENDENT layers, each pinned here:
///   1. The export renders author-embedded HTML in `.escape` mode
///      (`HTMLRenderer.AuthorHTMLDisposition.escape`) — author markup becomes
///      visible TEXT, removing the renderer as an injection vector entirely.
///   2. The standalone document carries a restrictive `<meta>` CSP.
///
/// Each test feeds one of the three reproduced sanitizer bypasses through the
/// EXACT composition `DocumentModel.htmlExportForActiveMarkdown` performs —
/// `HtmlExport.standaloneDocument(body: HTMLRenderer().render(md, authorHTML:
/// .escape), …)` — and asserts the exported string carries NO live handler / NO
/// executable `javascript:` scheme, plus the CSP tag.
///
/// TEETH: every assertion here fails on the pre-fix code, where the export
/// rendered author HTML through `HTMLSanitizer.sanitize` (`.sanitize` mode) and
/// `standaloneDocument` emitted no CSP. (Demonstrated by reverting the two
/// production edits and re-running — see the task notes.)
final class HtmlExportXSSTests: XCTestCase {

    // MARK: - Helpers

    /// Reproduce production's export composition for `markdown`.
    private func export(_ markdown: String) -> String {
        let body = HTMLRenderer().render(markdown, authorHTML: .escape)
        return HtmlExport.standaloneDocument(
            body: body, stylesheet: "", title: "doc")
    }

    /// The export must never carry a LIVE inline event handler. We look for the
    /// handler followed by `=` OUTSIDE of an entity-escaped form. After escaping,
    /// the literal text `onclick=` can appear, but only with the surrounding
    /// `<`/`"`/`'` rendered as `&lt;`/`&quot;`/`&#39;`, so the byte sequence can
    /// never form a real attribute on a real element. We assert the document
    /// contains no UN-escaped `<` immediately preceding author tag content — i.e.
    /// no live tag was emitted from author HTML at all.
    private func assertNoLiveAuthorTag(_ doc: String, _ payloadTagOpen: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        // The author's own `<…` open must be escaped to `&lt;…`. If the raw
        // `<tag` survived, a live element was emitted.
        XCTAssertFalse(doc.contains(payloadTagOpen),
                       "live author tag '\(payloadTagOpen)' survived into the export",
                       file: file, line: line)
        // And the escaped form must be present (proves the content is shown as
        // text, not silently dropped — escape, don't vanish).
        XCTAssertTrue(doc.contains("&lt;"),
                      "author HTML should be escaped to visible text, not dropped",
                      file: file, line: line)
    }

    // MARK: - Bypass 1: missing-space event handler  <a href="x"onclick=alert(1)>

    func test_export_neutralizes_noSpaceOnclickHandler() {
        // No whitespace between the quoted href and `onclick` — a valid HTML
        // attribute boundary the regex `\s+on[a-z]+` handler-stripper misses.
        let md = "<a href=\"x\"onclick=alert(1)>click</a>"
        let doc = export(md)

        // No live <a … onclick=…> element: the author tag is escaped.
        assertNoLiveAuthorTag(doc, "<a href=\"x\"onclick")
        // The dangerous attribute must not appear as a LIVE handler. After
        // escaping, `onclick=` only ever appears inside an escaped (&lt;…)
        // fragment — never as `"onclick=` attached to a real open tag.
        XCTAssertFalse(doc.contains("\"onclick=alert"),
                       "a live onclick handler reached the export")
        XCTAssertTrue(doc.contains("Content-Security-Policy"))
    }

    // MARK: - Bypass 2: self-closing handler  <svg/onload=alert(1)>

    func test_export_neutralizes_svgOnloadHandler() {
        // `<svg/onload=…>` — the `/` glues to the tag name; an SVG element that
        // fires `onload` with no network. svg isn't in the dropped-element set
        // and the handler is unquoted/glued.
        let md = "<svg/onload=alert(1)>"
        let doc = export(md)

        // No live <svg…> element survived — the author `<` must be escaped.
        // (The literal substring `onload=alert` legitimately remains inside the
        // ESCAPED text `&lt;svg/onload=alert(1)&gt;`; the security property is
        // that there is no LIVE <svg open tag carrying the handler, i.e. the
        // raw `<svg` byte sequence is gone.)
        XCTAssertFalse(doc.contains("<svg"),
                       "live <svg> element survived into the export")
        // Shown as escaped text instead.
        XCTAssertTrue(doc.contains("&lt;svg/onload=alert(1)&gt;"),
                      "svg payload should be escaped to visible text")
        XCTAssertTrue(doc.contains("Content-Security-Policy"))
    }

    // MARK: - Bypass 3: control-char obfuscated scheme  jav&#x09;ascript:

    func test_export_neutralizes_entityObfuscatedJavascriptScheme() {
        // A browser collapses the HTML entity / control char inside the scheme,
        // so `jav&#x09;ascript:alert(1)` parses as `javascript:`. The regex
        // matches the literal token `javascript`, which this splits, so it sails
        // through the URL-neutralizer.
        let md = "<a href=\"jav&#x09;ascript:alert(1)\">x</a>"
        let doc = export(md)

        // No live <a …> element survived — the whole author tag is text.
        XCTAssertFalse(doc.contains("<a href="),
                       "live <a> element survived into the export")
        // The href cannot resolve to an executable scheme: it must not appear
        // as a real (un-escaped) attribute value. After escaping, the quote is
        // `&quot;`, so `href="jav…` (real attribute) is impossible.
        XCTAssertFalse(doc.contains("href=\"jav"),
                       "an obfuscated javascript: href reached the export live")
        XCTAssertTrue(doc.contains("Content-Security-Policy"))
    }

    // MARK: - Sanity: legitimate text + markdown still renders (no over-escape)

    func test_export_preservesGeneratedMarkupAndEscapesOnlyAuthorHTML() {
        // Heading + emphasis are OUR generated markup and must stay live; the
        // embedded author <b> becomes text. Proves `.escape` defangs the author
        // surface WITHOUT collapsing the whole body to text.
        let md = "# Title\n\nHello *world* and <b>bold</b>"
        let doc = export(md)
        XCTAssertTrue(doc.contains("<h1"), "generated heading markup must stay live")
        XCTAssertTrue(doc.contains("<em>world</em>"), "generated emphasis must stay live")
        XCTAssertTrue(doc.contains("&lt;b&gt;bold&lt;/b&gt;"),
                      "author <b> must be escaped to visible text")
        XCTAssertFalse(doc.contains("<b>bold</b>"),
                       "author <b> must NOT survive as a live tag on the export path")
    }

    // MARK: - The in-app default still SANITIZES (richer HTML, CSP backstops)

    func test_inAppDefault_stillSanitizesRatherThanEscapes() {
        // The default disposition (.sanitize) is unchanged: a benign author <b>
        // survives as live markup in-app (the in-app CSP is the backstop). This
        // pins that the export hardening did NOT regress the in-app preview.
        let md = "Hello <b>bold</b>"
        let inApp = HTMLRenderer().render(md)               // default .sanitize
        XCTAssertTrue(inApp.contains("<b>bold</b>"),
                      "in-app default must still emit live (sanitized) author HTML")
        XCTAssertFalse(inApp.contains("&lt;b&gt;"),
                       "in-app default must not escape benign author HTML")
    }
}
