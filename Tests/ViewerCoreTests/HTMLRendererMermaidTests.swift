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

    // MARK: - Diagram-registry routing (TSK-713)
    //
    // These exercise the Swift visitor path (`renderSwiftPath`) directly — the
    // path the diagram intercept lives on — so the assertion is deterministic
    // regardless of the `.markdown` rust-engine gate (which, when on, takes a
    // separate chunk-splice path that wraps fence bodies; dot/plantuml host
    // routing there is a follow-up slice noted in RustMarkdownAdapter.enrich).

    func test_dotFence_emitsLabeledDiagramBlock() {
        let md = "```dot\ndigraph G {\n  a -> b;\n}\n```\n"
        let html = HTMLRenderer().render(md)
        XCTAssertTrue(html.contains("data-mdv-diagram=\"dot\""),
                      "dot fence should route to the labeled diagram block")
        XCTAssertTrue(html.contains("Graphviz DOT (digraph)"),
                      "caption should name the format + directedness")
        XCTAssertTrue(html.contains("a -&gt; b"), "source must be preserved + escaped")
        XCTAssertFalse(html.contains("mdv-mermaid"))
    }

    func test_plantUMLFence_emitsLabeledDiagramBlock() {
        let md = "```plantuml\n@startuml\nAlice -> Bob\n@enduml\n```\n"
        let html = HTMLRenderer().render(md)
        XCTAssertTrue(html.contains("data-mdv-diagram=\"plantuml\""))
        XCTAssertTrue(html.contains("PlantUML (uml)"),
                      "caption should name PlantUML + detected diagram type")
        XCTAssertTrue(html.contains("@startuml"))
    }

    func test_pumlAlias_routesToPlantUML() {
        let md = "```puml\n@startuml\nA -> B\n@enduml\n```\n"
        let html = HTMLRenderer().render(md)
        XCTAssertTrue(html.contains("data-mdv-diagram=\"plantuml\""))
    }

    func test_unknownFence_unaffectedByRegistry() {
        let md = "```rust\nfn main() {}\n```\n"
        let html = HTMLRenderer().render(md)
        XCTAssertFalse(html.contains("mdv-diagram"),
                       "a non-diagram language must not route to a diagram block")
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
