import XCTest
@testable import ViewerUI
import ViewerCore

/// TSK-838 (external-change staleness fix, 2026-07-17) — host tests for the PURE
/// half of the verified DOM-patch apply: `MarkdownRenderedView.domPatchPlan`.
/// The live half (evaluate + count-verify + fallback trigger) is VM-webview-proven
/// in `BlockPatchApplyWebViewTests`; these pin the eligibility heuristic and the
/// verify-contract inputs so a regression fails on the host gate.
final class DomPatchPlanTests: XCTestCase {

    func test_smallDiff_producesPlan_withExpectedBlockCount() {
        let old = "<p>Alpha</p>\n<p>Beta</p>\n<p>Gamma</p>\n"
        let new = "<p>Alpha</p>\n<p>Beta EDITED</p>\n<p>Gamma</p>\n"
        let plan = MarkdownRenderedView.domPatchPlan(oldHTML: old, newHTML: new)
        XCTAssertNotNil(plan, "a single-block edit is the patch path's whole point")
        XCTAssertEqual(plan?.expectedBlockCount, 3,
            "expectedBlockCount must be splitBlocks(newHTML).count — the verify contract")
        XCTAssertTrue(plan?.js.contains("mdvApplyBlockPatch") == true,
            "the plan JS must invoke the shared BlockPatchJS apply routine")
    }

    func test_identicalHTML_noOps_isNil() {
        let same = "<p>Same</p>\n<p>Body</p>\n"
        XCTAssertNil(MarkdownRenderedView.domPatchPlan(oldHTML: same, newHTML: same),
            "no block-level change ⇒ no patch plan (caller's reload gate handles it)")
    }

    func test_largeRewrite_isNil_fallbackToReload() {
        let old = (0..<10).map { "<p>old \($0)</p>\n" }.joined()
        let new = (0..<10).map { "<p>new \($0)</p>\n" }.joined()
        XCTAssertNil(MarkdownRenderedView.domPatchPlan(oldHTML: old, newHTML: new),
            "a whole-document rewrite must take the full-reload path")
    }

    func test_blockCountChange_reflectedInExpectedCount() {
        // Insert one block: expected count tracks the NEW grain, not the old.
        let old = "<p>One</p>\n<p>Two</p>\n"
        let new = "<p>One</p>\n<p>Middle</p>\n<p>Two</p>\n"
        let plan = MarkdownRenderedView.domPatchPlan(oldHTML: old, newHTML: new)
        XCTAssertEqual(plan?.expectedBlockCount, 3)
    }

    func test_applyFunction_returnsCountContract_isPresentInJS() {
        // The verify contract lives in the SHARED BlockPatchJS string: the routine
        // must return the post-apply children.length (and -1 on failure) — pin the
        // load-bearing fragments so a contract revert fails here on the host.
        XCTAssertTrue(BlockPatchJS.applyFunction.contains("return container.children.length"),
            "success path must return the post-apply children.length")
        XCTAssertTrue(BlockPatchJS.applyFunction.contains("return -1"),
            "failure path must return -1 (missing container / unparseable payload)")
    }
}
