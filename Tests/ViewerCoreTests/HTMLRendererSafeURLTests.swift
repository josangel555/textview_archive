import XCTest
@testable import ViewerCore

/// Security coverage for markdown link/image URL-scheme safety (S5 / F-06).
///
/// STAGE-B (TSK-649): the Swift `HTMLVisitor.safeURL` helper died with the
/// visitor twin — the policy is enforced by the RUST engine (markdown.rs
/// `safe_url`, mirrored from this contract when the port landed), so these
/// pins assert THROUGH the rendered HTML: a blocked scheme must not survive
/// into `href`/`src`. The rendered-page CSP is the second barrier; this is
/// the first.
final class HTMLRendererSafeURLTests: XCTestCase {

    private func render(_ md: String) -> String {
        HTMLRenderer().render(md, authorHTML: .escape)
    }

    // MARK: - link context

    func test_link_allowsWebAndMailto() {
        let html = render("[a](https://example.com/x) [b](http://example.com) [c](mailto:a@b.com)")
        XCTAssertTrue(html.contains("href=\"https://example.com/x\""))
        XCTAssertTrue(html.contains("href=\"http://example.com\""))
        XCTAssertTrue(html.contains("href=\"mailto:a@b.com\""))
    }

    func test_link_blocksDangerousAndDisallowedSchemes() {
        for bad in ["javascript:alert(1)", "vbscript:msgbox(1)",
                    "file:///etc/passwd", "data:image/png;base64,AAAA",
                    "customapp://do/thing"] {
            let html = render("[click](\(bad))")
            XCTAssertFalse(html.contains("href=\"\(bad)"),
                           "\(bad) must not survive into an href:\n\(html)")
            XCTAssertTrue(html.contains("click"), "the link TEXT stays visible")
        }
    }

    // MARK: - image context

    func test_image_allowsWebFileAndImageData() {
        for ok in ["https://example.com/a.png", "file:///tmp/a.png",
                   "data:image/png;base64,AAAA"] {
            let html = render("![alt](\(ok))")
            XCTAssertTrue(html.contains("src=\"\(ok)\""), "\(ok) must pass:\n\(html)")
        }
    }

    func test_image_rejectsNonImageDataAndScripts() {
        for bad in ["data:text/html,<script>", "data:application/json,{}",
                    "javascript:alert(1)", "mailto:a@b.com"] {
            let html = render("![alt](\(bad))")
            XCTAssertFalse(html.contains("src=\"\(bad)"),
                           "\(bad) must not survive into a src:\n\(html)")
        }
    }

    // MARK: - case-insensitivity (scheme compared lowercased)

    func test_schemeMatchingIsCaseInsensitive() {
        XCTAssertFalse(render("[x](JavaScript:alert(1))").contains("href=\"JavaScript:"),
                       "scheme blocking must be case-insensitive")
        XCTAssertTrue(render("[x](HTTPS://example.com)").contains("href=\"HTTPS://example.com\""))
    }
}
