import XCTest
@testable import ViewerCore

/// Unit tests for the Phase 4 (v2) incremental-edit applier — the
/// Swift-side reducer that consumes the JS `incrementalChange`
/// payload. These mirror the contract `codemirror.html`'s emitter
/// promises:
///
///   - Edits are pre-batch frame, sorted ascending by `from`.
///   - Offsets index UTF-16 code units (matches CM6 `EditorState.doc`).
///   - Pure inserts are `from == to`; pure deletes are `insert == ""`.
///   - Out-of-bounds or overlapping batches => `nil` (caller falls
///     back to full-text resync).
///
/// Each assertion documents one rule. Together they pin down the
/// algorithm so a future "optimisation" can't silently change behaviour.
final class CMEditApplierTests: XCTestCase {

    // MARK: - No-ops

    func testEmptyBatchReturnsBaseUnchanged() {
        XCTAssertEqual(CMEditApplier.apply([], to: "hello"), "hello")
    }

    func testEmptyBatchOnEmptyBaseStaysEmpty() {
        XCTAssertEqual(CMEditApplier.apply([], to: ""), "")
    }

    // MARK: - Single edits

    func testPureInsertAtStart() {
        let r = CMEditApplier.apply(
            [CMEdit(from: 0, to: 0, insert: "X")],
            to: "abc"
        )
        XCTAssertEqual(r, "Xabc")
    }

    func testPureInsertAtEnd() {
        let base = "abc"
        let r = CMEditApplier.apply(
            [CMEdit(from: 3, to: 3, insert: "X")],
            to: base
        )
        XCTAssertEqual(r, "abcX")
    }

    func testPureDeleteInTheMiddle() {
        let r = CMEditApplier.apply(
            [CMEdit(from: 1, to: 3, insert: "")],
            to: "abcde"
        )
        XCTAssertEqual(r, "ade")
    }

    func testReplaceShrinksDoc() {
        let r = CMEditApplier.apply(
            [CMEdit(from: 0, to: 5, insert: "x")],
            to: "abcde"
        )
        XCTAssertEqual(r, "x")
    }

    func testReplaceWholeDoc() {
        let r = CMEditApplier.apply(
            [CMEdit(from: 0, to: 5, insert: "totally new")],
            to: "abcde"
        )
        XCTAssertEqual(r, "totally new")
    }

    // MARK: - Multi-edit batches (all pre-batch frame)

    func testTwoInsertsKeepsOriginalCoordinates() {
        // Both edits reference the original "abc" frame — insert "X" at
        // start AND "Y" at end. The second edit's `from: 3` is the
        // pre-batch length, not the post-first-edit length.
        let r = CMEditApplier.apply([
            CMEdit(from: 0, to: 0, insert: "X"),
            CMEdit(from: 3, to: 3, insert: "Y"),
        ], to: "abc")
        XCTAssertEqual(r, "XabcY")
    }

    func testThreeNonOverlappingReplaces() {
        let r = CMEditApplier.apply([
            CMEdit(from: 0, to: 2, insert: "AA"),
            CMEdit(from: 4, to: 6, insert: "BB"),
            CMEdit(from: 8, to: 10, insert: "CC"),
        ], to: "0123456789")
        XCTAssertEqual(r, "AA23BB67CC")
    }

    func testEditsAcceptedOutOfOrderAndStableSorted() {
        // Caller may have collected edits in dispatch order; the
        // applier must sort and produce the canonical result.
        let r = CMEditApplier.apply([
            CMEdit(from: 4, to: 6, insert: "BB"),
            CMEdit(from: 0, to: 2, insert: "AA"),
        ], to: "012345")
        XCTAssertEqual(r, "AA23BB")
    }

    // MARK: - Rejection paths

    func testOverlappingEditsReturnsNil() {
        // Two edits that touch [1..3] and [2..4] overlap — applier
        // must reject the whole batch so the caller falls back to
        // full-text rather than silently producing something neither
        // editor agrees on.
        let r = CMEditApplier.apply([
            CMEdit(from: 1, to: 3, insert: "X"),
            CMEdit(from: 2, to: 4, insert: "Y"),
        ], to: "abcde")
        XCTAssertNil(r)
    }

    func testNegativeFromReturnsNil() {
        let r = CMEditApplier.apply(
            [CMEdit(from: -1, to: 0, insert: "X")],
            to: "abc"
        )
        XCTAssertNil(r)
    }

    func testFromGreaterThanToReturnsNil() {
        let r = CMEditApplier.apply(
            [CMEdit(from: 4, to: 2, insert: "X")],
            to: "abcde"
        )
        XCTAssertNil(r)
    }

    func testToBeyondDocLengthReturnsNil() {
        let r = CMEditApplier.apply(
            [CMEdit(from: 0, to: 999, insert: "")],
            to: "abc"
        )
        XCTAssertNil(r)
    }

    // MARK: - UTF-16 / surrogate-pair correctness

    func testEditPreservesEmojiOutsideTheEditRange() {
        // CM6 indexes UTF-16; one emoji is 2 code units. Deleting the
        // single-byte char between two emojis must leave them intact.
        // Base UTF-16 layout:
        //   0..1: 😀  (surrogate pair)
        //   2:    " "
        //   3..4: 😁  (surrogate pair)
        let base = "😀 😁"
        XCTAssertEqual(base.utf16.count, 5)
        let r = CMEditApplier.apply(
            [CMEdit(from: 2, to: 3, insert: "")],
            to: base
        )
        XCTAssertEqual(r, "😀😁")
    }

    func testInsertingEmojiAtUTF16BoundaryProducesValidString() {
        // Insert a 4-code-unit emoji-with-modifier between two ASCII chars.
        let payload = "👨‍💻" // ZWJ sequence — 5 UTF-16 units
        let r = CMEditApplier.apply(
            [CMEdit(from: 1, to: 1, insert: payload)],
            to: "ab"
        )
        XCTAssertEqual(r, "a\(payload)b")
        XCTAssertEqual(r?.utf16.count, 2 + payload.utf16.count)
    }

    // MARK: - Round-trip with the bridge decoder

    func testRoundTripFromJSONEnvelopeProducesIdenticalApply() throws {
        // The JS side ships:
        //   { v: 2, type: "incrementalChange",
        //     edits: [{from, to, insert}, ...],
        //     version, contentLength }
        // Run the actual decoder + applier so codec ↔ applier never
        // silently drifts.
        let payload: [String: Any] = [
            "v": 2,
            "type": "incrementalChange",
            "edits": [
                ["from": 0, "to": 0, "insert": "X"],
                ["from": 3, "to": 3, "insert": "Y"],
            ],
            "version": 7,
            "contentLength": 5,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let decoded = CMBridgeCodec.decodeInbound(body)
        guard case .incrementalChange(let edits, let version, let length) = decoded else {
            return XCTFail("expected incrementalChange, got \(String(describing: decoded))")
        }
        XCTAssertEqual(version, 7)
        XCTAssertEqual(length, 5)
        let applied = CMEditApplier.apply(edits, to: "abc")
        XCTAssertEqual(applied, "XabcY")
        XCTAssertEqual(applied?.utf16.count, length)
    }

    // MARK: - Ill-formed UTF-16 (EDIT-S3-APPLIER)

    func testSplittingSurrogatePairReturnsNil() {
        // Base "😀" is one scalar = 2 UTF-16 units (high+low surrogate).
        // Deleting ONLY the high surrogate [0..1] would leave a lone low
        // surrogate — ill-formed UTF-16. The applier must return nil (so
        // the caller resyncs) rather than silently substituting U+FFFD
        // and permanently corrupting the buffer.
        let base = "😀"
        XCTAssertEqual(base.utf16.count, 2)
        let r = CMEditApplier.apply(
            [CMEdit(from: 0, to: 1, insert: "")],
            to: base
        )
        XCTAssertNil(r,
            "splitting a surrogate pair must refuse, not produce U+FFFD")
    }

    func testInsertingLoneSurrogateViaUnpairedTailReturnsNil() {
        // Delete the LOW surrogate [1..2], leaving a lone high surrogate.
        let base = "😀"
        let r = CMEditApplier.apply(
            [CMEdit(from: 1, to: 2, insert: "")],
            to: base
        )
        XCTAssertNil(r,
            "leaving a lone high surrogate must refuse, not produce U+FFFD")
    }

    func testValidEmojiEditStillSucceeds() {
        // Regression: a well-formed edit that keeps surrogate pairs
        // intact must still decode (no false rejection from the
        // validating decoder).
        let base = "a😀b"
        let r = CMEditApplier.apply(
            [CMEdit(from: 0, to: 1, insert: "X")],  // replace 'a' with 'X'
            to: base
        )
        XCTAssertEqual(r, "X😀b")
    }

    func testDecodeValidatingUTF16_rejectsLoneSurrogate() {
        // Directly exercise the validating decoder helper.
        let loneHigh: [UTF16.CodeUnit] = [0xD83D]       // unpaired high
        let loneLow: [UTF16.CodeUnit] = [0xDE00]        // unpaired low
        let wellFormed: [UTF16.CodeUnit] = Array("hi 😀".utf16)
        XCTAssertNil(CMEditApplier.decodeValidatingUTF16(loneHigh))
        XCTAssertNil(CMEditApplier.decodeValidatingUTF16(loneLow))
        XCTAssertEqual(CMEditApplier.decodeValidatingUTF16(wellFormed), "hi 😀")
        XCTAssertEqual(CMEditApplier.decodeValidatingUTF16([]), "")
    }

    func testDecoderRejectsBatchWithNegativeFrom() throws {
        // Defensive: a single bad edit drops the whole envelope, so the
        // caller sees `nil` and asks JS to resync via flushChanges.
        let payload: [String: Any] = [
            "v": 2,
            "type": "incrementalChange",
            "edits": [["from": -5, "to": 0, "insert": ""]],
            "version": 1,
            "contentLength": 0,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertNil(CMBridgeCodec.decodeInbound(body))
    }
}
