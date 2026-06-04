import XCTest
@testable import RustCore
import ViewerCore

/// A/B parity: the Rust core's `mdvcore_cm_apply` (via `mdvCoreApplyCMEdits`)
/// vs the SHIPPING Swift `CMEditApplier`, over a corpus that exercises the
/// UTF-16 hazards the migration plan flagged (astral plane, split surrogate),
/// plus overlap/OOB rejection. A non-nil result must be byte-identical; a
/// rejected batch must be `nil` on BOTH sides. Forces the Rust path directly
/// (no gate) — the whole-pipeline cost incl. MessagePack encode/decode + FFI.
final class CMEditApplyABTests: XCTestCase {

    private func e(_ from: Int, _ to: Int, _ insert: String) -> CMEdit {
        CMEdit(from: from, to: to, insert: insert)
    }

    /// Each case: a base doc + an edit batch. Both impls must agree exactly.
    private func cases() -> [(String, [CMEdit])] {
        [
            ("hello", []),                                   // no-op
            ("hello", [e(2, 2, "X")]),                       // insert
            ("hello", [e(1, 3, "")]),                        // delete
            ("hello", [e(0, 5, "bye")]),                     // full replace
            ("abcdef", [e(1, 1, "-"), e(3, 5, "")]),         // multi, pre-edit offsets
            ("abcdef", [e(3, 5, ""), e(1, 1, "-")]),         // unsorted input
            ("abcdef", [e(1, 2, "X"), e(2, 3, "Y")]),        // adjacent (ok)
            ("abcdef", [e(1, 3, "x"), e(2, 4, "y")]),        // overlap → both nil
            ("abc", [e(-1, 0, "")]),                         // from < 0 → both nil
            ("abc", [e(0, 4, "")]),                          // to > len → both nil
            ("abc", [e(2, 1, "")]),                          // from > to → both nil
            ("a\r\nb", [e(0, 0, "X")]),                      // CRLF preserved
            ("🧠x", [e(2, 2, "!")]),                          // astral: insert past surrogate pair
            ("🧠x", [e(0, 2, "")]),                           // astral: delete whole emoji
            ("🧠", [e(0, 1, "")]),                            // split surrogate → both nil
            ("🧠", [e(1, 1, "x")]),                           // insert mid-pair → both nil
            ("abc", [e(3, 3, "Z")]),                         // append at end
            ("", [e(0, 0, "seed")]),                         // empty base
        ]
    }

    func test_rust_matches_swift_across_corpus() throws {
        for (base, edits) in cases() {
            let swift = CMEditApplier.apply(edits, to: base)
            let rust = try mdvCoreApplyCMEdits(
                base: base,
                edits: edits.map { (from: $0.from, to: $0.to, insert: $0.insert) })
            XCTAssertEqual(rust, swift,
                           "parity mismatch for base=\(base.debugDescription) edits=\(edits)")
        }
    }

    func test_gate_off_uses_swift_and_matches() {
        // Through the adapter with the gate OFF (default): Swift path, and it
        // equals calling CMEditApplier directly.
        let edits = [e(2, 2, "Z")]
        let o = RustCMEditAdapter.outcome(edits, to: "hello")
        XCTAssertEqual(o.source, .swiftBecauseGateOff)
        XCTAssertEqual(o.value, CMEditApplier.apply(edits, to: "hello"))
    }
}
