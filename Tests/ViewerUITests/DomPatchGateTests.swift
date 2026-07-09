import Testing
@testable import ViewerUI

/// TSK-838 — the DOM-patch feature gate is now DEFAULT ON (owner-approved
/// 2026-06-30): a same-file rendered-markdown re-render patches the live DOM in
/// place instead of a full `loadHTMLString` reload (killing the measured 2-9s
/// reload storm). Opt OUT with `MDV_DOM_PATCH=0`. The pure gate is host-tested
/// here; the live apply is VM-proven (BlockPatchApplyWebViewTests).
struct DomPatchGateTests {

    @Test func gate_defaultsOn_whenUnset() {
        #expect(MarkdownRenderedView.domPatchEnabled(env: nil) == true)
    }

    @Test func gate_onForOneOrAnyNonZeroValue() {
        #expect(MarkdownRenderedView.domPatchEnabled(env: "1") == true)
        #expect(MarkdownRenderedView.domPatchEnabled(env: "yes") == true)
        #expect(MarkdownRenderedView.domPatchEnabled(env: "") == true)
    }

    @Test func gate_optOutOnlyWithExplicitZero() {
        #expect(MarkdownRenderedView.domPatchEnabled(env: "0") == false)
    }
}
