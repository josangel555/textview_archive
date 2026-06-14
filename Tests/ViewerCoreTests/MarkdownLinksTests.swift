import XCTest
@testable import ViewerCore

/// Teeth for the Markdown link extractor + broken-local-link check (Check Links).
final class MarkdownLinksTests: XCTestCase {

    // MARK: extract

    func test_extract_inlineLinkAndImage() {
        let links = MarkdownLinks.extract("see [docs](guide.md) and ![logo](img/logo.png)")
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0], MarkdownLink(target: "guide.md", line: 1, isImage: false, text: "docs"))
        XCTAssertEqual(links[1], MarkdownLink(target: "img/logo.png", line: 1, isImage: true, text: "logo"))
    }

    func test_extract_dropsTitle() {
        let links = MarkdownLinks.extract("[a](http://x.com \"the title\")")
        XCTAssertEqual(links.first?.target, "http://x.com")
    }

    func test_extract_tracksLineNumbers_andSkipsFencedCode() {
        let text = """
        # Title
        [real](a.md)
        ```
        [not-a-link](nope.md)
        ```
        [also](b.md)
        """
        let links = MarkdownLinks.extract(text)
        XCTAssertEqual(links.map(\.target), ["a.md", "b.md"], "fenced link is skipped")
        XCTAssertEqual(links[0].line, 2)
        XCTAssertEqual(links[1].line, 6)
    }

    func test_extract_handlesNestedParensInURL() {
        let links = MarkdownLinks.extract("[wiki](https://en.wikipedia.org/wiki/Foo_(bar))")
        XCTAssertEqual(links.first?.target, "https://en.wikipedia.org/wiki/Foo_(bar)")
    }

    func test_extract_handlesBracketsInText() {
        let links = MarkdownLinks.extract("[text [with] brackets](target.md)")
        XCTAssertEqual(links.first?.target, "target.md")
    }

    // MARK: kind

    func test_kind_classifies() {
        XCTAssertEqual(MarkdownLinks.kind(of: "https://x.com"), .external)
        XCTAssertEqual(MarkdownLinks.kind(of: "mailto:a@b.com"), .external)
        XCTAssertEqual(MarkdownLinks.kind(of: "//cdn.example.com/x"), .external)
        XCTAssertEqual(MarkdownLinks.kind(of: "#section"), .anchor)
        XCTAssertEqual(MarkdownLinks.kind(of: "guide.md"), .relative)
        XCTAssertEqual(MarkdownLinks.kind(of: "../img/x.png"), .relative)
    }

    // MARK: brokenLocalLinks

    func test_brokenLocalLinks_flagsMissingRelativeOnly() {
        let text = """
        [ok](exists.md)
        [bad](missing.md)
        [ext](https://x.com/missing.md)
        [anchor](#section)
        ![img](there.png)
        ![gone](nope.png)
        """
        let present: Set<String> = ["exists.md", "there.png"]
        let broken = MarkdownLinks.brokenLocalLinks(in: text) { present.contains($0) }
        XCTAssertEqual(broken.map(\.target), ["missing.md", "nope.png"],
                       "only relative + missing; external + anchor skipped")
    }

    func test_brokenLocalLinks_stripsFragmentBeforeCheck() {
        // a relative link with a #fragment checks only the file part
        let broken = MarkdownLinks.brokenLocalLinks(in: "[x](page.md#sec)") { $0 == "page.md" }
        XCTAssertTrue(broken.isEmpty, "page.md exists → not broken despite the #sec fragment")
    }
}
