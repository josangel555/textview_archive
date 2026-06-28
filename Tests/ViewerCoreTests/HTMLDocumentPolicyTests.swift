import XCTest
@testable import ViewerCore

/// REGRESSION-CRITICAL security policy for rendering raw `.html` files
/// (see `HTMLDocumentPolicy`). These host-safe tests pin every layer of
/// the model headless — they catch the security regressions WITHOUT a
/// live `WKWebView`:
///
///   L0  render size cap (mirror of `markdownRenderMaxBytes`)
///   L1  sanitizer allowlist routing
///   L2  JavaScript DEFAULT-DENY (default is OFF; opt-in is the only "on")
///   L3  no remote sub-resources, no `file://` beyond the document tree
///       (CSP envelope + sub-resource navigation policy)
///   L4  link-click policy (browser-routable opens externally; rest
///       cancelled; in-page escapes cancelled)
///
/// The live render is the small visual residue; the policy lives here.
final class HTMLDocumentPolicyTests: XCTestCase {

    // MARK: - L0: render size cap

    func test_renderCap_mirrorsMarkdownCap() {
        // The HTML cap must track the markdown render cap — the task
        // requires "mirror markdownRenderMaxBytes". A drift here is a
        // policy regression.
        XCTAssertEqual(HTMLDocumentPolicy.renderMaxBytes, markdownRenderMaxBytes)
    }

    func test_shouldRender_underCap_true() {
        XCTAssertTrue(HTMLDocumentPolicy.shouldRender(byteCount: 0))
        XCTAssertTrue(HTMLDocumentPolicy.shouldRender(byteCount: 1024))
        XCTAssertTrue(HTMLDocumentPolicy.shouldRender(
            byteCount: HTMLDocumentPolicy.renderMaxBytes
        ))
    }

    func test_shouldRender_overCap_false() {
        XCTAssertFalse(HTMLDocumentPolicy.shouldRender(
            byteCount: HTMLDocumentPolicy.renderMaxBytes + 1
        ))
        XCTAssertFalse(HTMLDocumentPolicy.shouldRender(byteCount: 64 * 1024 * 1024))
    }

    // MARK: - L1: sanitizer routing

    func test_sanitize_routesThroughAllowlist_dropsScript() {
        let raw = "<p>ok</p><script>steal()</script>"
        let out = HTMLDocumentPolicy.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("<script"))
        XCTAssertFalse(out.contains("steal"))
        XCTAssertTrue(out.contains("<p>ok</p>"))
    }

    func test_sanitize_stripsEventHandlers() {
        let raw = #"<div onclick="evil()">x</div>"#
        let out = HTMLDocumentPolicy.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("onclick"))
        XCTAssertFalse(out.contains("evil"))
    }

    func test_sanitize_neutralizesJavascriptURL() {
        let raw = #"<a href="javascript:alert(1)">click</a>"#
        let out = HTMLDocumentPolicy.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("javascript:"))
        XCTAssertTrue(out.contains("about:blank"))
    }

    func test_sanitize_dropsIframeAndForm() {
        let raw = "<iframe src=\"https://evil.test\"></iframe>"
            + "<form action=\"https://evil.test\"><input></form>"
        let out = HTMLDocumentPolicy.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("<iframe"))
        XCTAssertFalse(out.lowercased().contains("<form"))
        XCTAssertFalse(out.lowercased().contains("<input"))
    }

    func test_sanitize_dropsMetaRefresh() {
        // <meta http-equiv=refresh> is a redirect / exfil vector; the
        // sanitizer drops all <meta> elements.
        let raw = #"<meta http-equiv="refresh" content="0;url=https://evil.test">"#
        let out = HTMLDocumentPolicy.sanitize(raw)
        XCTAssertFalse(out.lowercased().contains("<meta"))
        XCTAssertFalse(out.lowercased().contains("evil.test"))
    }

    func test_sanitize_preservesBenignMarkup() {
        let raw = "<h1>Title</h1><p class=\"lead\">Body <em>text</em>.</p>"
        let out = HTMLDocumentPolicy.sanitize(raw)
        XCTAssertTrue(out.contains("<h1>Title</h1>"))
        XCTAssertTrue(out.contains("class=\"lead\""))
        XCTAssertTrue(out.contains("<em>text</em>"))
    }

    // MARK: - L2: JavaScript DEFAULT-DENY

    func test_javaScript_defaultIsOff() {
        // The secure default: a tab that has NOT opted in runs no JS.
        XCTAssertFalse(HTMLDocumentPolicy.javaScriptEnabled(tabOptedIn: false))
    }

    func test_javaScript_onlyOnWhenOptedIn() {
        // The ONLY path to JS-on is an explicit per-tab opt-in.
        XCTAssertTrue(HTMLDocumentPolicy.javaScriptEnabled(tabOptedIn: true))
    }

    // MARK: - L3: CSP envelope

    func test_csp_deniesByDefault() {
        XCTAssertTrue(HTMLDocumentPolicy.csp.contains("default-src 'none'"))
    }

    func test_csp_blocksScriptConnectFrameObjectBaseForm() {
        // No script-src override (script stays denied via default-src),
        // and the exfil / framing / plugin / retarget vectors are all
        // explicitly 'none'.
        let csp = HTMLDocumentPolicy.csp
        XCTAssertFalse(csp.contains("script-src"),
                       "CSP must NOT re-permit scripts — default-src 'none' keeps them off")
        XCTAssertTrue(csp.contains("connect-src 'none'"))
        XCTAssertTrue(csp.contains("frame-src 'none'"))
        XCTAssertTrue(csp.contains("object-src 'none'"))
        XCTAssertTrue(csp.contains("base-uri 'none'"))
        XCTAssertTrue(csp.contains("form-action 'none'"))
    }

    func test_csp_allowsOnlyLocalAndDataImages() {
        // img-src is limited to file: + data: — NO http(s) image loads
        // (which double as beacons / trackers).
        let csp = HTMLDocumentPolicy.csp
        XCTAssertTrue(csp.contains("img-src file: data:"))
        XCTAssertFalse(csp.contains("img-src") && csp.contains("https:"),
                       "img-src must not permit remote https images")
    }

    func test_cspMetaTag_embedsCSP() {
        let tag = HTMLDocumentPolicy.cspMetaTag
        XCTAssertTrue(tag.contains("http-equiv=\"Content-Security-Policy\""))
        XCTAssertTrue(tag.contains("default-src 'none'"))
    }

    // MARK: - cspMeta(trusted:) — the LIVE parameterized CSP-meta emitter
    // (consumed by the trusted-document envelope; cspMetaTag above is the
    // untrusted-only var). These pin the live delivery path directly.

    func test_cspMeta_untrusted_matchesStrictMetaTag_noDrift() {
        let tag = HTMLDocumentPolicy.cspMeta(trusted: false)
        XCTAssertTrue(tag.contains("http-equiv=\"Content-Security-Policy\""))
        XCTAssertTrue(tag.contains("default-src 'none'"))
        XCTAssertFalse(tag.contains("script-src"),
                       "untrusted CSP meta must NOT relax script-src")
        // The two untrusted CSP-meta emitters must not drift apart: a divergence
        // would deliver a different policy depending on the code path.
        XCTAssertEqual(tag, HTMLDocumentPolicy.cspMetaTag)
    }

    func test_cspMeta_trusted_relaxesScriptButKeepsAntiExfilFence() {
        let tag = HTMLDocumentPolicy.cspMeta(trusted: true)
        XCTAssertTrue(tag.contains("http-equiv=\"Content-Security-Policy\""))
        XCTAssertTrue(tag.contains("script-src 'self'"),
                      "trusted CSP runs the page's OWN scripts")
        // The anti-exfiltration fence MUST survive the trust relaxation.
        XCTAssertTrue(tag.contains("connect-src 'none'"),
                      "trusted CSP must keep connect-src 'none' (no exfil)")
        XCTAssertTrue(tag.contains("object-src 'none'"))
        XCTAssertTrue(tag.contains("base-uri 'none'"))
        XCTAssertTrue(tag.contains("form-action 'none'"))
    }

    func test_cspMeta_isWellFormed_bothTrustLevels() {
        for trusted in [false, true] {
            let tag = HTMLDocumentPolicy.cspMeta(trusted: trusted)
            XCTAssertTrue(tag.hasPrefix("<meta http-equiv=\"Content-Security-Policy\" content=\""),
                          "malformed prefix (trusted=\(trusted))")
            XCTAssertTrue(tag.hasSuffix("\">"), "malformed suffix (trusted=\(trusted))")
            // Exactly the 4 attribute quotes — a stray double quote in the CSP
            // value would terminate content="" early and silently void the policy.
            XCTAssertEqual(tag.filter { $0 == "\"" }.count, 4,
                           "CSP value leaked a double quote, breaking the attr (trusted=\(trusted))")
        }
    }

    func test_envelope_injectsCSPAndWrapsBody() {
        let body = "<h1>hello</h1>"
        let doc = HTMLDocumentPolicy.envelope(sanitizedBody: body)
        XCTAssertTrue(doc.contains("<!DOCTYPE html>"))
        XCTAssertTrue(doc.contains(HTMLDocumentPolicy.cspMetaTag))
        XCTAssertTrue(doc.contains("<meta charset=\"utf-8\">"))
        XCTAssertTrue(doc.contains(body))
        // CSP meta must precede the body content it governs.
        let cspRange = doc.range(of: "Content-Security-Policy")!
        let bodyRange = doc.range(of: body)!
        XCTAssertTrue(cspRange.lowerBound < bodyRange.lowerBound)
    }

    // MARK: - L3: sub-resource navigation policy

    private let docURL = URL(fileURLWithPath: "/tmp/site/index.html")

    func test_subresource_initialLoad_allowed() {
        // The bootstrap document load must render.
        let d = HTMLDocumentPolicy.decideSubresource(
            url: docURL, documentURL: nil, isInitialDocumentLoad: true
        )
        XCTAssertEqual(d, .allow)
    }

    func test_subresource_remoteHTTP_cancelled() {
        // No remote sub-resource loads — the core L3 guarantee.
        let d = HTMLDocumentPolicy.decideSubresource(
            url: URL(string: "https://evil.test/track.png"),
            documentURL: docURL,
            isInitialDocumentLoad: false
        )
        XCTAssertEqual(d, .cancel)
    }

    func test_subresource_remoteHTTP_plainHTTP_cancelled() {
        let d = HTMLDocumentPolicy.decideSubresource(
            url: URL(string: "http://evil.test/track.png"),
            documentURL: docURL,
            isInitialDocumentLoad: false
        )
        XCTAssertEqual(d, .cancel)
    }

    func test_subresource_websocket_cancelled() {
        // WebSocket beacons are a remote-exfil channel — cancelled.
        let d = HTMLDocumentPolicy.decideSubresource(
            url: URL(string: "wss://evil.test/socket"),
            documentURL: docURL,
            isInitialDocumentLoad: false
        )
        XCTAssertEqual(d, .cancel)
    }

    func test_subresource_localImage_inDocumentTree_allowed() {
        // A relative image next to the document loads.
        let d = HTMLDocumentPolicy.decideSubresource(
            url: URL(fileURLWithPath: "/tmp/site/img/logo.png"),
            documentURL: docURL,
            isInitialDocumentLoad: false
        )
        XCTAssertEqual(d, .allow)
    }

    func test_subresource_localFile_outsideTree_cancelled() {
        // file:///etc/passwd pull from a doc in /tmp/site/ — blocked.
        let d = HTMLDocumentPolicy.decideSubresource(
            url: URL(fileURLWithPath: "/etc/passwd"),
            documentURL: docURL,
            isInitialDocumentLoad: false
        )
        XCTAssertEqual(d, .cancel)
    }

    func test_subresource_localFile_parentTraversal_cancelled() {
        // `../../secrets.txt` traversal out of the document tree.
        let traversal = URL(fileURLWithPath: "/tmp/site/../../secrets.txt")
        let d = HTMLDocumentPolicy.decideSubresource(
            url: traversal,
            documentURL: docURL,
            isInitialDocumentLoad: false
        )
        XCTAssertEqual(d, .cancel)
    }

    func test_subresource_siblingDirPrefix_notTreatedAsInTree() {
        // /tmp/site must NOT match a sibling /tmp/site-secrets — the
        // path-boundary guard prevents a bare-prefix escape.
        let sibling = URL(fileURLWithPath: "/tmp/site-secrets/data.txt")
        let d = HTMLDocumentPolicy.decideSubresource(
            url: sibling,
            documentURL: docURL,
            isInitialDocumentLoad: false
        )
        XCTAssertEqual(d, .cancel)
    }

    func test_subresource_javascriptScheme_cancelled() {
        let d = HTMLDocumentPolicy.decideSubresource(
            url: URL(string: "javascript:alert(1)"),
            documentURL: docURL,
            isInitialDocumentLoad: false
        )
        XCTAssertEqual(d, .cancel)
    }

    func test_subresource_dataScheme_afterLoad_cancelled() {
        // location.replace('data:text/html,…') style document swap.
        let d = HTMLDocumentPolicy.decideSubresource(
            url: URL(string: "data:text/html,%3Cscript%3E1%3C/script%3E"),
            documentURL: docURL,
            isInitialDocumentLoad: false
        )
        XCTAssertEqual(d, .cancel)
    }

    func test_subresource_fileEscape_afterLoad_cancelled() {
        // window.location = 'file:///etc/passwd' AFTER load (not the
        // bootstrap) — an in-page escape; cancelled even though it's a
        // file: scheme, because it's outside the document tree.
        let d = HTMLDocumentPolicy.decideSubresource(
            url: URL(fileURLWithPath: "/etc/passwd"),
            documentURL: docURL,
            isInitialDocumentLoad: false
        )
        XCTAssertEqual(d, .cancel)
    }

    func test_subresource_nilURL_cancelled() {
        let d = HTMLDocumentPolicy.decideSubresource(
            url: nil, documentURL: docURL, isInitialDocumentLoad: false
        )
        XCTAssertEqual(d, .cancel)
    }

    func test_subresource_customScheme_cancelled() {
        let d = HTMLDocumentPolicy.decideSubresource(
            url: URL(string: "myapp://do/evil"),
            documentURL: docURL,
            isInitialDocumentLoad: false
        )
        XCTAssertEqual(d, .cancel)
    }

    // MARK: - L4: link-click policy

    func test_link_http_opensExternally() {
        let d = HTMLDocumentPolicy.decideLink(
            url: URL(string: "https://example.com"), documentURL: docURL
        )
        guard case .openExternally(let u) = d else {
            return XCTFail("expected .openExternally, got \(d)")
        }
        XCTAssertEqual(u.host, "example.com")
    }

    func test_link_mailto_opensExternally() {
        guard case .openExternally = HTMLDocumentPolicy.decideLink(
            url: URL(string: "mailto:user@example.com"), documentURL: docURL
        ) else { return XCTFail("expected .openExternally") }
    }

    func test_link_fileClick_cancelled() {
        // A user click must never navigate the WebView to another local
        // file — even one in the document tree (that escapes the
        // sandboxed render).
        let d = HTMLDocumentPolicy.decideLink(
            url: URL(fileURLWithPath: "/tmp/site/other.html"),
            documentURL: docURL
        )
        XCTAssertEqual(d, .cancel)
    }

    func test_link_javascriptClick_cancelled() {
        let d = HTMLDocumentPolicy.decideLink(
            url: URL(string: "javascript:alert(1)"), documentURL: docURL
        )
        XCTAssertEqual(d, .cancel)
    }

    func test_link_dataClick_cancelled() {
        let d = HTMLDocumentPolicy.decideLink(
            url: URL(string: "data:text/html,%3Ch1%3Ex%3C/h1%3E"),
            documentURL: docURL
        )
        XCTAssertEqual(d, .cancel)
    }

    func test_link_sameDocumentFragment_allowed() {
        let target = URL(string: "file:///tmp/site/index.html#section")!
        let current = URL(string: "file:///tmp/site/index.html")!
        let d = HTMLDocumentPolicy.decideLink(url: target, documentURL: current)
        XCTAssertEqual(d, .allow)
    }

    func test_link_fragmentOnOtherDocument_cancelled() {
        let target = URL(string: "file:///tmp/site/other.html#section")!
        let current = URL(string: "file:///tmp/site/index.html")!
        let d = HTMLDocumentPolicy.decideLink(url: target, documentURL: current)
        XCTAssertEqual(d, .cancel)
    }

    // MARK: - isWithinDocumentTree edge cases

    func test_isWithinDocumentTree_nonFileURL_false() {
        XCTAssertFalse(HTMLDocumentPolicy.isWithinDocumentTree(
            URL(string: "https://example.com/x")!, documentURL: docURL
        ))
    }

    func test_isWithinDocumentTree_documentItself_true() {
        XCTAssertTrue(HTMLDocumentPolicy.isWithinDocumentTree(
            docURL, documentURL: docURL
        ))
    }

    func test_isWithinDocumentTree_nilDocument_false() {
        XCTAssertFalse(HTMLDocumentPolicy.isWithinDocumentTree(
            URL(fileURLWithPath: "/tmp/site/x.png"), documentURL: nil
        ))
    }

    // MARK: - dependsOnSuppressedScript (TSK-1189 diagnostic seam)

    func test_dependsOnSuppressedScript_trueForInlineScript() {
        // A JS-driven bundled app (the Weather Console case): its <script>
        // gets stripped + script-src 'none', so it never paints. The detector
        // must flag it so the UI can explain instead of silently breaking.
        let bundled = """
        <!DOCTYPE html><html><head><script>window.__boot()</script></head>
        <body><div id="__bundler_loading">Loading…</div></body></html>
        """
        XCTAssertTrue(HTMLDocumentPolicy.dependsOnSuppressedScript(bundled))
    }

    func test_dependsOnSuppressedScript_trueForExternalScriptSrc() {
        XCTAssertTrue(HTMLDocumentPolicy.dependsOnSuppressedScript(
            "<html><body><script src=\"app.bundle.js\"></script></body></html>"))
    }

    func test_dependsOnSuppressedScript_caseInsensitive() {
        XCTAssertTrue(HTMLDocumentPolicy.dependsOnSuppressedScript(
            "<HTML><SCRIPT>x()</SCRIPT></HTML>"))
    }

    func test_dependsOnSuppressedScript_falseForPlainDocument() {
        // A plain static document renders fine under the locked-down policy —
        // no script, so no explanation to over-offer.
        XCTAssertFalse(HTMLDocumentPolicy.dependsOnSuppressedScript(
            "<!DOCTYPE html><html><body><h1>Hello</h1><p>world</p></body></html>"))
    }
}
