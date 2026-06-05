import XCTest
import WebKit
@testable import ViewerUI

/// T1 pure-logic suite pinning the CodeMirror editor's navigation
/// security policy (`CodeMirrorEditorView.Coordinator.decide(...)`),
/// mirroring `MarkdownLinkPolicyTests` for the rendered view.
///
/// Audit findings (S3/security + S3/test-gap, both in
/// `Sources/ViewerUI/CodeMirrorEditorView.swift`): the editor's nav
/// delegate previously allowed EVERY `.other` navigation unconditionally
/// — `window.location = 'javascript:…'` / `'data:…'` / a post-bootstrap
/// `file:` escape all surfaced as `.other` and slipped through. The fix
/// extracts a pure `decide()` that (a) unconditionally rejects
/// `javascript:`/`vbscript:`/`data:`, (b) gates the lone allowed `file:`
/// load behind a one-shot `didFinishFirstLoad` flag, and (c) permits
/// same-document `#fragment` navigation. These tests pin that contract.
///
/// `WebKit` is imported only for the `WKNavigationType` enum the policy
/// takes as input; no `WKWebView` is ever instantiated (host-safe T1).
@MainActor
final class Audit_Sources_ViewerUI_CodeMirrorEditorView_swift_LinkPolicyTests: XCTestCase {

    private func decide(
        _ url: String?,
        navigationType: WKNavigationType = .other,
        currentDocumentURL: URL? = nil,
        didFinishFirstLoad: Bool = false
    ) -> CodeMirrorEditorView.LinkDecision {
        CodeMirrorEditorView.Coordinator.decide(
            url: url.flatMap(URL.init(string:)),
            navigationType: navigationType,
            currentDocumentURL: currentDocumentURL,
            didFinishFirstLoad: didFinishFirstLoad
        )
    }

    // MARK: - One-shot bootstrap file: load allowed

    func test_decide_bootstrapFileLoad_beforeFirstLoad_isAllowed() {
        // The single legitimate navigation: loadFileURL(codemirror.html)
        // surfaces as `.other` before didFinish. Must be allowed or the
        // editor never renders.
        XCTAssertEqual(
            decide("file:///bundle/codemirror.html",
                   navigationType: .other,
                   didFinishFirstLoad: false),
            .allow
        )
    }

    func test_decide_bootstrapSubresources_beforeFirstLoad_areAllowed() {
        // The host HTML pulls codemirror.css / codemirror.js as relative
        // file: subresources during the bootstrap load (also `.other`,
        // pre-didFinish). They must be allowed.
        XCTAssertEqual(
            decide("file:///bundle/codemirror.css",
                   navigationType: .other,
                   didFinishFirstLoad: false),
            .allow
        )
        XCTAssertEqual(
            decide("file:///bundle/codemirror.js",
                   navigationType: .other,
                   didFinishFirstLoad: false),
            .allow
        )
    }

    // MARK: - Post-load .other to file:/data: is a script escape -> cancel

    func test_decide_other_fileScheme_afterFirstLoad_isCancelled() {
        // `window.location = 'file:///etc/passwd'` from in-page script
        // arrives as a top-level `.other` AFTER the bootstrap — cancel.
        XCTAssertEqual(
            decide("file:///etc/passwd",
                   navigationType: .other,
                   currentDocumentURL: URL(string: "file:///bundle/codemirror.html"),
                   didFinishFirstLoad: true),
            .cancel
        )
    }

    func test_decide_other_dataScheme_afterFirstLoad_isCancelled() {
        // `location.replace('data:text/html,…')` style escape.
        XCTAssertEqual(
            decide("data:text/html,%3Cscript%3E1%3C/script%3E",
                   navigationType: .other,
                   currentDocumentURL: URL(string: "file:///bundle/codemirror.html"),
                   didFinishFirstLoad: true),
            .cancel
        )
    }

    func test_decide_data_beforeFirstLoad_isCancelled() {
        // Unlike MarkdownRenderedView (which bootstraps via loadHTMLString),
        // the editor never loads data: — so data: is rejected even during
        // the bootstrap window.
        XCTAssertEqual(
            decide("data:text/html,%3Ch1%3Ehi%3C/h1%3E",
                   navigationType: .other,
                   didFinishFirstLoad: false),
            .cancel
        )
    }

    // MARK: - javascript:/vbscript: cancelled for ANY navigation type

    func test_decide_javascript_isCancelled_forAnyType() {
        for type: WKNavigationType in [.other, .linkActivated, .reload, .formSubmitted] {
            XCTAssertEqual(
                decide("javascript:alert(1)",
                       navigationType: type,
                       didFinishFirstLoad: false),
                .cancel,
                "javascript: must be cancelled for \(type.rawValue)"
            )
            XCTAssertEqual(
                decide("javascript:alert(1)",
                       navigationType: type,
                       didFinishFirstLoad: true),
                .cancel,
                "javascript: must be cancelled post-load for \(type.rawValue)"
            )
        }
    }

    func test_decide_vbscript_isCancelled_forAnyType() {
        for type: WKNavigationType in [.other, .linkActivated, .reload] {
            XCTAssertEqual(
                decide("vbscript:msgbox(1)", navigationType: type, didFinishFirstLoad: false),
                .cancel
            )
            XCTAssertEqual(
                decide("vbscript:msgbox(1)", navigationType: type, didFinishFirstLoad: true),
                .cancel
            )
        }
    }

    // MARK: - Same-document #fragment allowed

    func test_decide_sameDocFragment_isAllowed() {
        let current = URL(string: "file:///bundle/codemirror.html")!
        XCTAssertEqual(
            CodeMirrorEditorView.Coordinator.decide(
                url: URL(string: "file:///bundle/codemirror.html#anchor"),
                navigationType: .linkActivated,
                currentDocumentURL: current,
                didFinishFirstLoad: true
            ),
            .allow
        )
    }

    func test_decide_fragmentOnDifferentDocument_isCancelled() {
        // A #fragment that points at a DIFFERENT file: document is not a
        // same-document nav — it's a cross-document file: load, cancelled.
        let current = URL(string: "file:///bundle/codemirror.html")!
        XCTAssertEqual(
            CodeMirrorEditorView.Coordinator.decide(
                url: URL(string: "file:///etc/passwd#x"),
                navigationType: .linkActivated,
                currentDocumentURL: current,
                didFinishFirstLoad: true
            ),
            .cancel
        )
    }

    // MARK: - Link clicks / external schemes cancelled (editor is not a browser)

    func test_decide_httpLink_isCancelled() {
        // The editor never opens external links — clicking a link must not
        // navigate the WebView away from the host HTML.
        XCTAssertEqual(
            decide("https://example.com",
                   navigationType: .linkActivated,
                   didFinishFirstLoad: true),
            .cancel
        )
    }

    func test_decide_customScheme_isCancelled() {
        XCTAssertEqual(
            decide("myapp://x?evil=1", navigationType: .linkActivated, didFinishFirstLoad: true),
            .cancel
        )
    }

    func test_decide_nilURL_isCancelled() {
        XCTAssertEqual(
            decide(nil, navigationType: .other, didFinishFirstLoad: false),
            .cancel
        )
    }

    // MARK: - Coordinator flag default

    func test_coordinator_didFinishFirstLoad_startsFalse() {
        let coordinator = CodeMirrorEditorView.Coordinator()
        XCTAssertFalse(coordinator.didFinishFirstLoad)
    }
}
