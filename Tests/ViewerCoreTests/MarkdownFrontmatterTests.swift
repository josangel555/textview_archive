import XCTest
@testable import ViewerCore

/// A leading YAML (`---`) / TOML (`+++`) frontmatter block must be HIDDEN when
/// rendering markdown (Jekyll/Hugo/Obsidian docs) — not shown as an `<hr>` + a
/// giant setext `<h2>` of the raw key/values. Stage-B (TSK-649): the Swift
/// visitor twin is deleted — every pin here exercises the rust engine.
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

    func test_renderEntryPoint_hidesFrontmatter() {
        let html = HTMLRenderer().render(doc, authorHTML: .escape)
        XCTAssertFalse(html.contains("title: Hello World"), "the public entry hides it too:\n\(html)")
        XCTAssertTrue(html.contains("Body"))
    }

    func test_unterminatedFenceIsNotFrontmatter() {
        // A doc that merely opens with `---` and never closes is NOT
        // frontmatter — its content must survive into the HTML.
        let html = HTMLRenderer().render("---\nnot really frontmatter\n\n# Body")
        XCTAssertTrue(html.contains("not really frontmatter"))
        XCTAssertTrue(html.contains("Body"))
    }
}
