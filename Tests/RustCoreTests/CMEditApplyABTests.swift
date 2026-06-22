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

    // MARK: - Randomized differential fuzz (edit-stream parity)

    private struct Xorshift {
        var s: UInt64
        mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
        mutating func int(_ lo: Int, _ hi: Int) -> Int { lo + Int(next() % UInt64(hi - lo + 1)) }
    }

    private func randomAscii(_ rng: inout Xorshift, _ maxLen: Int) -> String {
        let alpha = Array("abc \n")
        let n = rng.int(0, maxLen)
        var s = ""
        for _ in 0..<n { s.append(alpha[rng.int(0, alpha.count - 1)]) }
        return s
    }

    /// A sorted, non-overlapping, in-bounds edit batch (ASCII base → UTF-16 offsets ==
    /// char offsets) — the valid-ACCEPT space, where both engines must return
    /// byte-identical applied text. (The reject space — overlap / OOB / surrogate-split
    /// — is the corpus's job.) `cursor` advances strictly past each edit so no two
    /// ranges touch.
    private func randomValidBatch(_ rng: inout Xorshift, baseLen: Int) -> [CMEdit] {
        var edits: [CMEdit] = []
        var cursor = 0
        let k = rng.int(0, 4)
        for _ in 0..<k {
            guard cursor <= baseLen else { break }
            let from = cursor + rng.int(0, baseLen - cursor)
            let to = from + rng.int(0, baseLen - from)
            edits.append(e(from, to, randomAscii(&rng, 3)))
            cursor = to + 1
        }
        return edits
    }

    /// Randomized edit-stream differential: the highest-frequency editor path (typing)
    /// fuzzed for Swift↔Rust parity, the flip-critical complement to the hand corpus.
    /// Merge gate runs fixed seeds; the nightly lane varies MDV_FUZZ_SEED_BASE.
    func test_rust_matches_swift_random_edit_batches() throws {
        let seedBase = UInt64(ProcessInfo.processInfo.environment["MDV_FUZZ_SEED_BASE"] ?? "0") ?? 0
        for seed in UInt64(1)...UInt64(80) {
            var rng = Xorshift(s: ((seed &+ seedBase) &* 0x9E37_79B9_7F4A_7C15) | 1)
            for _ in 0..<25 {
                let base = randomAscii(&rng, 24)
                let edits = randomValidBatch(&rng, baseLen: base.utf16.count)
                let swift = CMEditApplier.apply(edits, to: base)
                let rust = try mdvCoreApplyCMEdits(
                    base: base, edits: edits.map { (from: $0.from, to: $0.to, insert: $0.insert) })
                XCTAssertEqual(rust, swift,
                               "edit-stream parity diverged: base=\(base.debugDescription) edits=\(edits)")
            }
        }
    }

    func test_gate_off_uses_swift_and_matches() {
        // Env-pinned OFF (the shipped default is ON since TSK-649 round 4).
        let edits = [e(2, 2, "Z")]
        let o = RustCMEditAdapter.outcome(
            edits, to: "hello", environment: ["MDV_RUST_CMEDIT": "0"])
        XCTAssertEqual(o.source, .swiftBecauseGateOff)
        XCTAssertEqual(o.value, CMEditApplier.apply(edits, to: "hello"))
    }

    func test_shippedDefault_routesRust_andMatchesSwift() {
        let edits = [e(2, 2, "Z")]
        let o = RustCMEditAdapter.outcome(edits, to: "hello", environment: [:])
        XCTAssertEqual(o.source, .rust, "cmEdit ships default-ON (round 4 — stage A complete)")
        XCTAssertEqual(o.value, CMEditApplier.apply(edits, to: "hello"))
    }

    // MARK: - Stateful / incremental round-trip (TSK-543)

    /// THE Swift-side golden contract (TSK-543): the editor applies each
    /// `incrementalChange` delta to its mirror and feeds the prior result back
    /// in as the new base (see `CodeMirrorEditorView.userContentController`).
    /// That keystroke-at-a-time sequence MUST equal a from-scratch full-doc
    /// apply of the cumulative edits — otherwise the stateful core (which keeps
    /// the mirror in Rust and ships only deltas) could diverge from the
    /// full-doc path it replaces. We pin it on BOTH the Rust path
    /// (`mdvCoreApplyCMEdits`) and the Swift `CMEditApplier`, and assert they
    /// agree at every step.
    func test_incremental_sequence_equals_full_doc_apply() throws {
        let initial = "fn main() {\n    let x = 🧠;\n}\n"

        // UTF-16 offset of the first occurrence of `needle` — what CM emits.
        func u16(_ hay: String, _ needle: String) -> Int {
            guard let r = hay.range(of: needle) else { return 0 }
            return hay.utf16.distance(from: hay.utf16.startIndex,
                                      to: r.lowerBound.samePosition(in: hay.utf16)!)
        }

        // Build the delta steps by walking a reference string forward, so the
        // offsets are the ones a real editor would emit at each step.
        var ref = initial
        var steps: [[CMEdit]] = []

        let off1 = u16(ref, "🧠")
        let s1 = [e(off1, off1, "42 + ")]
        ref = CMEditApplier.apply(s1, to: ref)!
        steps.append(s1)

        let end = ref.utf16.count
        let s2 = [e(end, end, "// done\n")]
        ref = CMEditApplier.apply(s2, to: ref)!
        steps.append(s2)

        let off3 = u16(ref, "🧠")
        let s3 = [e(off3, off3 + 2, "z")]  // delete emoji's 2 units, insert "z"
        ref = CMEditApplier.apply(s3, to: ref)!
        steps.append(s3)

        // Stateful/incremental path on the RUST side: prior result is the next
        // base, exactly like the editor's mirror.
        var rustDoc = initial
        for batch in steps {
            let applied = try mdvCoreApplyCMEdits(
                base: rustDoc,
                edits: batch.map { (from: $0.from, to: $0.to, insert: $0.insert) })
            rustDoc = try XCTUnwrap(applied, "each delta must apply cleanly")
        }

        // Same incremental walk on the SWIFT side.
        var swiftDoc = initial
        for batch in steps {
            swiftDoc = try XCTUnwrap(CMEditApplier.apply(batch, to: swiftDoc))
        }

        // From-scratch reference is the forward-walked `ref`.
        XCTAssertEqual(rustDoc, ref, "Rust incremental path diverged from full-doc apply")
        XCTAssertEqual(swiftDoc, ref, "Swift incremental path diverged from full-doc apply")
        XCTAssertEqual(rustDoc, swiftDoc, "Rust and Swift incremental paths must agree")
    }

    /// A rejected delta mid-stream (overlap) must leave the doc UNCHANGED on
    /// both paths — the editor's "drift → full resync" cue — so the stateful
    /// mirror can never be left half-mutated.
    func test_rejected_delta_is_clean_noop_both_paths() throws {
        let base = "abcdef"
        let bad = [e(1, 3, "x"), e(2, 4, "y")]  // overlap
        let rust = try mdvCoreApplyCMEdits(
            base: base, edits: bad.map { (from: $0.from, to: $0.to, insert: $0.insert) })
        XCTAssertNil(rust, "Rust rejects the overlapping batch")
        XCTAssertNil(CMEditApplier.apply(bad, to: base), "Swift rejects it too")
    }
}
