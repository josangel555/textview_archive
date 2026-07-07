import Testing
import RustCore
@testable import ViewerCore

/// TSK-1517/1518/1519 — the stateful-core doc family + shadow differential
/// net, exercised through the REAL linked FFI (host-safe pure logic).
/// Serialized: the shadow's divergence/batch counters are process-wide.
@Suite(.serialized)
struct CoreDocShadowTests {

    // MARK: - CoreDocStore (TSK-1517 Swift client)

    @Test func docStoreCapabilityIsAdvertised() {
        #expect(CoreDocStore.isAvailable, "linked core must ship MDV_CAP_DOC_STORE")
    }

    @Test func openApplyTextWindowSaveCloseRoundTrip() throws {
        let id = try CoreDocStore.open(text: "hello", nowMs: 1)
        let delta = try CoreDocStore.applyDelta(
            docId: id, edits: [.init(from: 5, to: 5, insert: " world")], nowMs: 2)
        #expect(delta.found && delta.changed && delta.dirty)
        #expect(delta.rev == 1)
        #expect(delta.lenUTF16 == 11)
        #expect(try CoreDocStore.text(docId: id, nowMs: 3) == "hello world")
        #expect(try CoreDocStore.window(docId: id, from: 6, len: 5, nowMs: 4) == "world")
        #expect(try CoreDocStore.markSaved(docId: id, nowMs: 5) == 1)
        try CoreDocStore.close(docId: id)
        #expect(try CoreDocStore.text(docId: id, nowMs: 6) == nil, "closed id is data, not a fault")
    }

    @Test func rejectedBatchIsAtomicNoOp() throws {
        let id = try CoreDocStore.open(text: "abc", nowMs: 1)
        // Overlapping edits are invalid — the core rejects the WHOLE batch.
        let delta = try CoreDocStore.applyDelta(
            docId: id,
            edits: [.init(from: 0, to: 2, insert: "x"), .init(from: 1, to: 3, insert: "y")],
            nowMs: 2)
        #expect(delta.found && !delta.changed && !delta.dirty)
        #expect(try CoreDocStore.text(docId: id, nowMs: 3) == "abc")
        try CoreDocStore.close(docId: id)
    }

    // MARK: - CoreDocShadow (TSK-1518 differential net)

    @MainActor
    private func withShadow<T>(_ body: (CoreDocShadow) throws -> T) rethrows -> T {
        CoreDocShadow.shadowOverrideForTesting = true
        CoreDocShadow.resetCountersForTesting()
        defer { CoreDocShadow.shadowOverrideForTesting = nil }
        return try body(CoreDocShadow(fullCompareStride: 2))
    }

    @MainActor
    @Test func shadowMirrorsCleanEditStreamWithZeroDivergence() {
        withShadow { shadow in
            var text = "line one"
            let edits: [(CMEdit, String)] = [
                (CMEdit(from: 8, to: 8, insert: "\nline two"), "line one\nline two"),
                (CMEdit(from: 0, to: 4, insert: "LINE"), "LINE one\nline two"),
                (CMEdit(from: 9, to: 13, insert: "LINE"), "LINE one\nLINE two"),
            ]
            for (edit, expected) in edits {
                shadow.mirror(edits: [edit], base: text, applied: expected)
                text = expected
            }
            // Stride=2 ⇒ the full-compare ran mid-stream too.
            #expect(CoreDocShadow.divergenceCount == 0, "clean stream must not diverge")
            #expect(CoreDocShadow.batchCount == 3)
            shadow.verifyOnSave(hostText: text)
            #expect(CoreDocShadow.divergenceCount == 0)
            shadow.close()
        }
    }

    @MainActor
    @Test func shadowCatchesDivergenceAndResyncs() {
        withShadow { shadow in
            shadow.mirror(edits: [CMEdit(from: 0, to: 0, insert: "a")], base: "", applied: "a")
            #expect(CoreDocShadow.divergenceCount == 0)
            // TEETH: hand the shadow a LYING host text (host "applied" text the
            // edit stream cannot produce) — the len check must catch it.
            shadow.mirror(
                edits: [CMEdit(from: 1, to: 1, insert: "b")],
                base: "a", applied: "a-TAMPERED")
            #expect(CoreDocShadow.divergenceCount == 1, "the net must catch the mismatch")
            // Post-resync the stream is healthy again from the host authority.
            shadow.mirror(
                edits: [CMEdit(from: 10, to: 10, insert: "!")],
                base: "a-TAMPERED", applied: "a-TAMPERED!")
            #expect(CoreDocShadow.divergenceCount == 1, "resync restores a clean net")
            shadow.close()
        }
    }

    @MainActor
    @Test func fullReplaceResyncsAndSnapshotVerifies() {
        withShadow { shadow in
            shadow.mirror(edits: [CMEdit(from: 0, to: 0, insert: "seed")], base: "", applied: "seed")
            shadow.noteFullReplace("brand new text")
            // S4 (TSK-1519): the core can BE the snapshot source when verified.
            #expect(shadow.snapshotTextIfVerified(hostText: "brand new text") == "brand new text")
            #expect(CoreDocShadow.divergenceCount == 0)
            // Mismatched host snapshot text counts a divergence and returns nil.
            #expect(shadow.snapshotTextIfVerified(hostText: "different") == nil)
            #expect(CoreDocShadow.divergenceCount == 1)
            shadow.close()
        }
    }

    @MainActor
    @Test func shadowOffIsInert() {
        CoreDocShadow.shadowOverrideForTesting = false
        defer { CoreDocShadow.shadowOverrideForTesting = nil }
        CoreDocShadow.resetCountersForTesting()
        let shadow = CoreDocShadow()
        shadow.mirror(edits: [CMEdit(from: 0, to: 0, insert: "x")], base: "", applied: "x")
        shadow.verifyOnSave(hostText: "x")
        #expect(shadow.snapshotTextIfVerified(hostText: "x") == nil)
        #expect(CoreDocShadow.batchCount == 0, "off ⇒ no mirroring, no counters")
        #expect(CoreDocShadow.divergenceCount == 0)
    }
}
