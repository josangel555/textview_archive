import XCTest
@testable import ViewerCore
import RustCore

/// RustMarkdownAdapter behavior pins (STAGE-B, TSK-649: the Swift visitor
/// twin is deleted — rust is the only engine, no gate). The expectations
/// below are the CONTRACT the retired byte-equality A/B proved before
/// deletion: structural render + production splice (sanitized raw html,
/// highlighted fences, in-core mermaid host), iterative deep-nesting
/// behavior, and the version-skew escape hatch.
final class RustMarkdownAdapterTests: XCTestCase {

    func test_rustIsTheOnlyEngine_spliceSurfaceHolds() {
        // Structure + sanitized raw html + highlighted fence + in-core
        // mermaid — the whole splice surface in one document.
        let md = """
        # Doc

        a <b>bold</b> inline and <script>evil()</script>

        ```swift
        let x = 1
        ```

        ```mermaid
        A-->B
        ```
        """
        let out = RustMarkdownAdapter.outcome(md)
        XCTAssertEqual(out.source, .rust, "twin deleted — rust must serve the render")
        let html = out.value
        XCTAssertTrue(html.contains("<h1 id=\"doc\">Doc</h1>"), "structure + slug:\n\(html)")
        XCTAssertTrue(html.contains("<b>bold</b>"), "benign author html survives sanitize")
        XCTAssertFalse(html.contains("<script>"), "sanitizer holds on the spliced path")
        XCTAssertTrue(html.contains("tok-"), "the swift fence carries highlight spans")
        XCTAssertTrue(html.contains("mdv-mermaid"), "the mermaid host div is emitted in-core")
    }

    func test_renderEntryPoint_servesTheEngine() {
        // The engine's documented list shape (own-suite pin): items wrap
        // their inline content in <p> (markdown.rs synth-para rule).
        let html = HTMLRenderer().render("- a\n- b")
        XCTAssertTrue(html.contains("<ul>") && html.contains("<li><p>a</p>"),
                      "engine list shape:\n\(html)")
    }

    func test_nestingBomb_rendersFullyIteratively() {
        // pulldown-cmark is an iterative pull parser: a 6000-deep blockquote
        // bomb renders fully — no stack to blow, no truncation marker.
        let bomb = String(repeating: ">", count: 6000) + " x"
        let out = RustMarkdownAdapter.outcome(bomb)
        XCTAssertEqual(out.source, .rust)
        XCTAssertTrue(out.value.hasPrefix("<blockquote>"))
        XCTAssertFalse(out.value.contains("truncated"))
    }

    func test_unknownChunkKind_escapesPayload_neverInjects() {
        let chunk = CoreMarkdownChunk(kind: "future_kind", lang: "", payload: "<script>x</script>")
        XCTAssertEqual(
            RustMarkdownAdapter.enrich(chunk),
            "&lt;script&gt;x&lt;/script&gt;",
            "version skew must degrade to escaped text, never raw markup")
    }
}
