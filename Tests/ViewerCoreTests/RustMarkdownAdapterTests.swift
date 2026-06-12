import XCTest
@testable import ViewerCore
import RustCore

/// RustMarkdownAdapter routing (TSK-648): gate OFF → the Swift visitor path
/// untouched, gate ON → rust structural render + production splice with
/// byte-equal output, the PARSE-03 divergence as the rust-route behavioral
/// proof, and the version-skew escape hatch. Gate state injected via
/// `environment`.
final class RustMarkdownAdapterTests: XCTestCase {

    private let gateOn = ["MDV_RUST_MARKDOWN": "1"]

    func test_gateOff_runsSwiftPath() {
        // Env-pinned OFF (the shipped default is ON since TSK-649 round 3).
        let md = "# T\n\npara with *em*"
        let out = RustMarkdownAdapter.outcome(md, environment: ["MDV_RUST_MARKDOWN": "0"])
        XCTAssertEqual(out.source, .swiftBecauseGateOff)
        XCTAssertEqual(out.value, HTMLRenderer.renderSwiftPath(md))
    }

    func test_gateOn_runsRust_byteEqualAcrossKinds() {
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
        let out = RustMarkdownAdapter.outcome(md, environment: gateOn)
        XCTAssertEqual(out.source, .rust)
        XCTAssertEqual(out.value, HTMLRenderer.renderSwiftPath(md))
        XCTAssertFalse(out.value.contains("<script>"), "sanitizer holds on the spliced path")
    }

    func test_renderEntryPoint_routesThroughTheGate() {
        // With the round-3 default ON this compares the RUST route against
        // the Swift path — byte-equality IS the A/B guarantee, so the assert
        // holds in both worlds and regresses if either route or parity breaks.
        let md = "- a\n- b"
        XCTAssertEqual(HTMLRenderer().render(md), HTMLRenderer.renderSwiftPath(md))
    }

    func test_gateOn_nestingBomb_rendersInsteadOfTruncating() {
        // The PARSE-03 guard is Swift-path-only: rust (iterative pulldown)
        // renders a 6000-deep blockquote bomb fully. This doubles as the
        // proof that gate ON genuinely routes rust — the Swift path would
        // return the truncation marker.
        let bomb = String(repeating: ">", count: 6000) + " x"
        XCTAssertEqual(HTMLRenderer.renderSwiftPath(bomb), HTMLVisitor.truncationMarker)
        let out = RustMarkdownAdapter.outcome(bomb, environment: gateOn)
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
