import XCTest
@testable import ViewerCore

/// A leading YAML (`---`) / TOML (`+++`) frontmatter block must be HIDDEN when
/// rendering markdown (Jekyll/Hugo/Obsidian docs) — not shown as an `<hr>` + a
/// giant setext `<h2>` of the raw key/values. Covers the live rust path AND the
/// swift fallback, which must agree.
final class MarkdownFrontmatterTests: XCTestCase {
    private let doc = "---\ntitle: Hello World\ntags: [a, b]\n---\n\n# Body\n\nText."

    func test_rustPath_hidesYAMLFrontmatter() {
        let html = RustMarkdownAdapter.render(doc, authorHTML: .escape)
        XCTAssertFalse(html.contains("title: Hello World"), "yaml must not render as content:\n\(html)")
        XCTAssertFalse(html.contains("<hr"), "the --- fences must not become a rule")
        XCTAssertTrue(html.contains("<h1 id=\"body\">Body</h1>"), "the real body must render")
    }

    func test_rustPath_hidesTOMLFrontmatter() {
        let html = RustMarkdownAdapter.render("+++\ntitle = \"X\"\n+++\n\n# Body", authorHTML: .escape)
        XCTAssertFalse(html.contains("title = "), "toml must not render:\n\(html)")
        XCTAssertTrue(html.contains("Body"))
    }

    func test_rustPath_midDocumentDashesStaysThematicBreak() {
        // A `---` that is NOT leading frontmatter must still be a thematic break.
        let html = RustMarkdownAdapter.render("# A\n\ntext\n\n---\n\nmore", authorHTML: .escape)
        XCTAssertTrue(html.contains("<hr"), "mid-doc --- is still a rule:\n\(html)")
    }

    func test_swiftFallback_hidesFrontmatter() {
        let html = HTMLRenderer.renderSwiftPath(doc, authorHTML: .escape)
        XCTAssertFalse(html.contains("title: Hello World"), "swift fallback must also hide it:\n\(html)")
        XCTAssertTrue(html.contains("Body"))
    }

    func test_stripHelper_unterminatedNotStripped() {
        // A doc that merely opens with `---` and never closes is NOT frontmatter.
        let src = "---\nnot really frontmatter\n\n# Body"
        XCTAssertEqual(HTMLRenderer.strippingLeadingFrontmatter(src), src)
    }

    func test_stripHelper_nonLeadingNotStripped() {
        let src = "# A\n\n---\n\nB"
        XCTAssertEqual(HTMLRenderer.strippingLeadingFrontmatter(src), src)
    }
}
