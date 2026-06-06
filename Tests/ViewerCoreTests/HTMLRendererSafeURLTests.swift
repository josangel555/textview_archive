import XCTest
@testable import ViewerCore

/// Security coverage for `HTMLVisitor.safeURL(_:for:)` (in HTMLRenderer.swift)
/// — the scheme
/// allowlist that rewrites dangerous `href`/`src` values to `about:blank`
/// so a malicious markdown can't smuggle `javascript:`/`vbscript:`/`data:`
/// even if WKWebView's nav-policy delegate is bypassed on the bootstrap
/// load. The helper had zero direct tests; `render()` only exercises it
/// incidentally. This pins the full matrix (context × scheme + the
/// `data:image/*` sub-rule + relative/fragment/authority forms +
/// case-insensitivity).
final class HTMLRendererSafeURLTests: XCTestCase {

    private func link(_ s: String) -> String { HTMLVisitor.safeURL(s, for: .link) }
    private func image(_ s: String) -> String { HTMLVisitor.safeURL(s, for: .image) }
    private let blank = "about:blank"

    // MARK: - scheme-independent forms (both contexts pass through)

    func test_emptyOrWhitespace_isBlank() {
        XCTAssertEqual(link(""), blank)
        XCTAssertEqual(link("   "), blank)
        XCTAssertEqual(image("\n\t "), blank)
    }

    func test_fragment_relative_and_authorityRelative_passThrough() {
        XCTAssertEqual(link("#section"), "#section")
        XCTAssertEqual(link("docs/guide.md"), "docs/guide.md")
        XCTAssertEqual(link("/abs/path"), "/abs/path")
        // "//host/x" has no colon before the slashes → not a scheme → kept.
        XCTAssertEqual(link("//cdn.example.com/a.js"), "//cdn.example.com/a.js")
    }

    func test_colonInNonSchemeText_isNotTreatedAsScheme() {
        // A space in the prefix means it isn't a URL scheme; keep verbatim.
        XCTAssertEqual(link("see foo:bar"), "see foo:bar")
    }

    // MARK: - link context

    func test_link_allowsWebAndMailto() {
        XCTAssertEqual(link("https://example.com/x"), "https://example.com/x")
        XCTAssertEqual(link("http://example.com"), "http://example.com")
        XCTAssertEqual(link("mailto:a@b.com"), "mailto:a@b.com")
    }

    func test_link_blocksDangerousAndDisallowedSchemes() {
        XCTAssertEqual(link("javascript:alert(1)"), blank)
        XCTAssertEqual(link("vbscript:msgbox(1)"), blank)
        XCTAssertEqual(link("file:///etc/passwd"), blank, "links don't allow file:")
        XCTAssertEqual(link("data:image/png;base64,AAAA"), blank, "links don't allow data:")
        XCTAssertEqual(link("customapp://do/thing"), blank)
    }

    // MARK: - image context

    func test_image_allowsWebFileAndImageData() {
        XCTAssertEqual(image("https://example.com/a.png"), "https://example.com/a.png")
        XCTAssertEqual(image("file:///tmp/a.png"), "file:///tmp/a.png")
        XCTAssertEqual(image("data:image/png;base64,AAAA"), "data:image/png;base64,AAAA")
    }

    func test_image_rejectsNonImageDataAndScripts() {
        XCTAssertEqual(image("data:text/html,<script>"), blank, "only image/* data URLs allowed")
        XCTAssertEqual(image("data:application/json,{}"), blank)
        XCTAssertEqual(image("javascript:alert(1)"), blank)
        XCTAssertEqual(image("mailto:a@b.com"), blank, "images don't allow mailto:")
    }

    // MARK: - case-insensitivity (scheme compared lowercased)

    func test_schemeMatchingIsCaseInsensitive() {
        XCTAssertEqual(link("HTTPS://example.com"), "HTTPS://example.com")
        XCTAssertEqual(link("JavaScript:alert(1)"), blank)
        XCTAssertEqual(image("DATA:image/png;base64,AA"), "DATA:image/png;base64,AA")
    }
}
