import XCTest
@testable import ViewerCore

/// TSK-1189 slice 2 — teeth for the BOUNDED trust relaxation. Two things must
/// hold together: (a) a trusted local doc keeps its own `<script>`/`<style>` so
/// it can paint, but (b) the anti-exfiltration fence is NEVER relaxed — a
/// trusted page runs its JS yet cannot beacon out (`connect-src 'none'`) or pull
/// remote/plugin content. Untrusted output must stay byte-identical to today.
final class HTMLTrustModeTests: XCTestCase {

    // MARK: sanitizer — untrusted unchanged (default is the hardened path)

    func test_untrusted_stripsScriptAndStyle_asBefore() {
        let out = HTMLSanitizer.sanitize("<script>evil()</script><style>x{}</style><p>hi</p>")
        XCTAssertFalse(out.localizedCaseInsensitiveContains("<script"))
        XCTAssertFalse(out.localizedCaseInsensitiveContains("<style"))
        XCTAssertTrue(out.contains("hi"))
    }

    func test_defaultArg_isUntrusted_byteIdentical() {
        let raw = "<script>x</script><iframe src=q></iframe><p onclick='y'>hi</p>"
        XCTAssertEqual(HTMLSanitizer.sanitize(raw), HTMLSanitizer.sanitize(raw, trusted: false),
                       "the default (no-arg) sanitize must equal the explicit untrusted path")
    }

    // MARK: sanitizer — trusted keeps script/style, still bounds the rest

    func test_trusted_keepsScriptAndStyle() {
        let out = HTMLSanitizer.sanitize("<script>render()</script><style>b{}</style><div id=app></div>",
                                         trusted: true)
        XCTAssertTrue(out.localizedCaseInsensitiveContains("<script"),
                      "a trusted local doc must keep its own <script> so a JS bundle can paint")
        XCTAssertTrue(out.localizedCaseInsensitiveContains("<style"))
        XCTAssertTrue(out.contains("id=app"))
    }

    func test_trusted_stillDropsIframeObjectEmbed() {
        let out = HTMLSanitizer.sanitize(
            "<script>x</script><iframe src=//evil></iframe><object data=p></object><embed src=q>",
            trusted: true)
        XCTAssertFalse(out.localizedCaseInsensitiveContains("<iframe"),
                       "even trusted: iframe stays dropped (remote-content vector)")
        XCTAssertFalse(out.localizedCaseInsensitiveContains("<object"))
        XCTAssertFalse(out.localizedCaseInsensitiveContains("<embed"))
    }

    func test_trusted_stillNeutralizesInlineJSVectors() {
        // Modern bundles wire up via addEventListener; we keep the inline-JS
        // surface bounded even when trusted.
        let out = HTMLSanitizer.sanitize(
            "<a href=\"javascript:steal()\">x</a><div onclick=\"go()\">y</div>", trusted: true)
        XCTAssertFalse(out.localizedCaseInsensitiveContains("javascript:steal"),
                       "javascript: URLs neutralized even when trusted")
        XCTAssertFalse(out.localizedCaseInsensitiveContains("onclick"),
                       "inline on*= handlers stripped even when trusted")
    }

    // MARK: CSP — untrusted unchanged

    func test_cspString_untrusted_equalsStrictConstant() {
        XCTAssertEqual(HTMLDocumentPolicy.cspString(trusted: false), HTMLDocumentPolicy.csp)
    }

    func test_cspString_untrusted_hasNoScript() {
        XCTAssertFalse(HTMLDocumentPolicy.cspString(trusted: false).contains("script-src"),
                       "untrusted CSP relies on default-src 'none' — no script-src directive")
    }

    // MARK: CSP — trusted relaxes script, KEEPS the anti-exfil fence (the teeth)

    func test_cspString_trusted_allowsOwnScripts() {
        let csp = HTMLDocumentPolicy.cspString(trusted: true)
        XCTAssertTrue(csp.contains("script-src 'self' 'unsafe-inline' 'unsafe-eval'"),
                      "trusted CSP must let the page's own scripts run")
    }

    func test_cspString_trusted_keepsConnectSrcNone_antiExfilFence() {
        let csp = HTMLDocumentPolicy.cspString(trusted: true)
        // THE security invariant: scripts run, but cannot beacon/fetch out.
        XCTAssertTrue(csp.contains("connect-src 'none'"),
                      "trusted CSP must KEEP connect-src 'none' — no exfiltration path")
        XCTAssertTrue(csp.contains("object-src 'none'"))
        XCTAssertTrue(csp.contains("base-uri 'none'"))
        XCTAssertTrue(csp.contains("form-action 'none'"))
        XCTAssertTrue(csp.contains("frame-src 'none'"))
        XCTAssertFalse(csp.contains("connect-src 'self'"),
                       "trusted must NEVER permit network egress")
    }

    // MARK: envelope wiring

    func test_envelope_default_isUntrusted_byteIdentical() {
        let body = "<p>hi</p>"
        XCTAssertEqual(HTMLDocumentPolicy.envelope(sanitizedBody: body),
                       HTMLDocumentPolicy.envelope(sanitizedBody: body, trusted: false))
    }

    func test_envelope_trusted_embedsTrustedCSP() {
        let doc = HTMLDocumentPolicy.envelope(sanitizedBody: "<div id=app></div>", trusted: true)
        XCTAssertTrue(doc.contains("script-src 'self' 'unsafe-inline' 'unsafe-eval'"))
        XCTAssertTrue(doc.contains("connect-src 'none'"), "the fence travels into the rendered envelope")
    }

    func test_envelope_untrusted_embedsStrictCSP() {
        let doc = HTMLDocumentPolicy.envelope(sanitizedBody: "<p>hi</p>")
        XCTAssertTrue(doc.contains(HTMLDocumentPolicy.cspMetaTag))
    }
}
