import XCTest
@testable import ViewerCore

final class HTMLRendererMermaidTests: XCTestCase {

    func test_mermaidFence_producesDiv() {
        let md = "```mermaid\nflowchart LR\n  A --> B\n```\n"
        let html = HTMLRenderer().render(md)
        XCTAssertTrue(html.contains("<div class=\"mdv-mermaid\""),
                      "mermaid fence should produce a div host element")
        XCTAssertFalse(html.contains("<pre><code class=\"language-mermaid\""),
                       "mermaid block must not pass through the normal code-fence renderer")
    }

    func test_mermaidFence_isCaseInsensitive() {
        let md = "```Mermaid\nflowchart LR\n  A --> B\n```\n"
        let html = HTMLRenderer().render(md)
        XCTAssertTrue(html.contains("<div class=\"mdv-mermaid\""))
    }

    func test_mermaidFence_preservesSourceAsTextNode() {
        let md = "```mermaid\nflowchart LR\n  A --> B\n```\n"
        let html = HTMLRenderer().render(md)
        XCTAssertTrue(html.contains("flowchart LR"))
        XCTAssertTrue(html.contains("A --&gt; B"),
                      "arrow > must be HTML-escaped inside the host element")
    }

    func test_mermaidFence_emitsSrcHash() {
        let md = "```mermaid\nflowchart LR\n  A --> B\n```\n"
        let html = HTMLRenderer().render(md)
        XCTAssertTrue(html.contains("data-mdv-src-hash=\""),
                      "missing source-hash attribute for cache / dedup")
    }

    func test_mermaidFence_emitsDataMdvSrc() {
        let md = "```mermaid\nflowchart LR\n  A --> B\n```\n"
        let html = HTMLRenderer().render(md)
        XCTAssertTrue(html.contains("data-mdv-src=\""),
                      "missing pristine-source attribute used by theme-flip re-render")
    }

    func test_mermaidFence_emitsStepsManifest() {
        let md = """
        ```mermaid
        flowchart LR
          A --> B
        %% @step 1
          B --> C
        ```
        """
        let html = HTMLRenderer().render(md)
        XCTAssertTrue(html.contains("data-mdv-steps="))
        XCTAssertTrue(html.contains("&quot;step&quot;:1"),
                      "step manifest should be HTML-attribute-escaped")
    }

    func test_mermaidFence_noStepsAttribute_whenNoneDeclared() {
        let md = "```mermaid\nflowchart LR\n  A --> B\n```\n"
        let html = HTMLRenderer().render(md)
        XCTAssertFalse(html.contains("data-mdv-steps="),
                       "static diagrams shouldn't carry an empty step manifest")
    }

    func test_mermaidFence_emitsExplicitId() {
        let md = """
        ```mermaid
        %% @id arch-overview
        flowchart LR
          A --> B
        ```
        """
        let html = HTMLRenderer().render(md)
        XCTAssertTrue(html.contains("data-mdv-id=\"arch-overview\""))
    }

    func test_mermaidFence_synthesizesIdWhenAbsent() {
        let md = "```mermaid\nflowchart LR\n  A --> B\n```\n"
        let html = HTMLRenderer().render(md)
        XCTAssertTrue(html.contains("data-mdv-id=\"mdv-mermaid-"),
                      "no @id directive → synthesized fallback id derived from hash")
    }

    func test_nonMermaidFenceUnaffected() {
        let md = "```swift\nlet x = 1\n```\n"
        let html = HTMLRenderer().render(md)
        XCTAssertTrue(html.contains("<pre><code class=\"language-swift\""))
        XCTAssertFalse(html.contains("mdv-mermaid"))
    }

    func test_renderPage_inlinesExtraStylesheet() {
        let renderer = HTMLRenderer()
        let page = renderer.renderPage(
            "# Hello",
            stylesheet: "/* base */",
            extraStylesheet: "/* extra-mermaid-css */"
        )
        XCTAssertTrue(page.contains("/* base */"))
        XCTAssertTrue(page.contains("/* extra-mermaid-css */"))
    }
}
