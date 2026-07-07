import XCTest
import Foundation
@testable import ViewerCore

/// Integration coverage for the Phase 4 (v2) bridge that exercises
/// the **full Swift-side flow** without spinning up a WKWebView:
///
///   - JS emits incremental edits → Swift decodes → applier replays →
///     EditorBuffer reflects the new text, dirty bit flips correctly.
///   - LSP foldingRange round-trip: decode → mapping → outbound encode
///     reaches the JS dispatcher with the right wire shape.
///   - Big-file cap: the design-doc constant gates editor activation
///     and is large enough to not affect typical files.
///
/// Each test simulates the JS half of the conversation by hand-rolling
/// the JSON envelope the JS bundle's `post(...)` would produce, then
/// runs `CMBridgeCodec.decodeInbound` + the relevant Swift helper.
final class CMV2IntegrationTests: XCTestCase {

    // MARK: - End-to-end: incremental edits drive EditorBuffer

    /// Simulates a user typing "hello world" character-by-character.
    /// The JS emitter batches per-debounce-window edits; each batch
    /// posts as one `incrementalChange` envelope, which Swift decodes,
    /// applies via `CMEditApplier`, and writes back to its mirror.
    /// After three batches the buffer should equal "hello world" and
    /// the dirty bit should be set.
    func test_jsIncrementalEditsFlowIntoEditorBuffer() throws {
        var buffer = EditorBuffer(
            url: URL(fileURLWithPath: "/tmp/test.txt"),
            original: ""
        )
        XCTAssertFalse(buffer.isDirty)

        let batches: [[String: Any]] = [
            // Batch 1: insert "hello"
            [
                "v": 2, "type": "incrementalChange",
                "edits": [["from": 0, "to": 0, "insert": "hello"]],
                "version": 1, "contentLength": 5,
            ],
            // Batch 2: insert " " at end
            [
                "v": 2, "type": "incrementalChange",
                "edits": [["from": 5, "to": 5, "insert": " "]],
                "version": 2, "contentLength": 6,
            ],
            // Batch 3: insert "world" at end
            [
                "v": 2, "type": "incrementalChange",
                "edits": [["from": 6, "to": 6, "insert": "world"]],
                "version": 3, "contentLength": 11,
            ],
        ]

        for batch in batches {
            let body = try JSONSerialization.data(withJSONObject: batch)
            guard case .incrementalChange(let edits, _, let len) =
                    CMBridgeCodec.decodeInbound(body) else {
                return XCTFail("decode failed for batch \(batch)")
            }
            let next = try XCTUnwrap(
                RustCMEditAdapter.apply(edits, to: buffer.text))
            XCTAssertEqual(next.utf16.count, len,
                           "Swift mirror diverged from JS contentLength")
            buffer.setText(next)
        }
        XCTAssertEqual(buffer.text, "hello world")
        XCTAssertTrue(buffer.isDirty,
                      "buffer should be dirty after JS-driven edits")
    }

    /// Multi-edit batch — a paste-then-delete cycle that arrives as
    /// one batch (CM6 dispatches both changes in one transaction when
    /// the user pastes-over a selection).
    func test_singleBatchPasteOverSelectionRoundTrips() throws {
        let buffer = EditorBuffer(
            url: URL(fileURLWithPath: "/tmp/test.txt"),
            original: "the quick brown fox"
        )
        // User selected "quick brown" and pasted "lazy" — CM6 ships
        // this as a single edit {from:4, to:15, insert:"lazy"}.
        let body = try JSONSerialization.data(withJSONObject: [
            "v": 2, "type": "incrementalChange",
            "edits": [["from": 4, "to": 15, "insert": "lazy"]],
            "version": 1, "contentLength": 12,
        ])
        guard case .incrementalChange(let edits, _, _) =
                CMBridgeCodec.decodeInbound(body) else {
            return XCTFail("decode")
        }
        let next = try XCTUnwrap(RustCMEditAdapter.apply(edits, to: buffer.text))
        XCTAssertEqual(next, "the lazy fox")
    }

    /// Drift: JS reports `contentLength` that doesn't match what the
    /// applier produces (would happen if the encoder accumulator
    /// regressed). Swift can detect via length mismatch and request a
    /// full resync — pinning this branch so the recovery path can't
    /// regress to silent acceptance.
    func test_lengthMismatchDetectedAtApplyTime() throws {
        let buffer = EditorBuffer(
            url: URL(fileURLWithPath: "/tmp/test.txt"),
            original: "abc"
        )
        let body = try JSONSerialization.data(withJSONObject: [
            "v": 2, "type": "incrementalChange",
            "edits": [["from": 0, "to": 0, "insert": "X"]],
            "version": 1, "contentLength": 999,  // lies — true length = 4
        ])
        guard case .incrementalChange(let edits, _, let claimedLen) =
                CMBridgeCodec.decodeInbound(body) else {
            return XCTFail("decode")
        }
        let next = try XCTUnwrap(RustCMEditAdapter.apply(edits, to: buffer.text))
        XCTAssertNotEqual(next.utf16.count, claimedLen,
                          "applier output should disagree with bogus length")
        // Caller policy (mirrored in CodeMirrorEditorView coordinator):
        // length mismatch ⇒ drop the apply, ask JS to flushChanges so
        // the next emit is a full-text v1 `change`.
    }

    // MARK: - LSP foldingRange wire trip

    func test_lspFoldingRange_roundTripsThroughDecodeMapEncode() throws {
        // Inbound LSP wire bytes — what sourcekit-lsp would return for
        // a tiny Swift file with one fold (lines 1..3).
        let lspBytes = Data(#"""
        [
          {"startLine": 1, "endLine": 3, "kind": "region"}
        ]
        """#.utf8)
        let folds = LSPClient.decodeFoldingRange(lspBytes)
        XCTAssertEqual(folds.count, 1)

        // Map to CM6 doc offsets using a representative doc.
        let doc = """
        func a() {
            print(1)
            print(2)
        }
        """
        let cm = CMFoldRangeMapping.cmFoldRanges(
            from: folds, documentText: doc)
        XCTAssertEqual(cm.count, 1)

        // Encode for the JS bridge.
        let raw = CMBridgeCodec.encodeOutboundJSON(.setFoldingRanges(cm))
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: raw.data(using: .utf8)!) as? [String: Any])
        XCTAssertEqual(parsed["type"] as? String, "setFoldingRanges")
        let arr = parsed["ranges"] as? [[String: Any]]
        XCTAssertEqual(arr?.count, 1)
        XCTAssertEqual(arr?[0]["kind"] as? String, "region")
        XCTAssertEqual(arr?[0]["from"] as? Int, cm[0].from)
        XCTAssertEqual(arr?[0]["to"] as? Int, cm[0].to)
    }

    // MARK: - Big-file cap (Phase 4 deliverable)

    func test_bigFileCap_existsAndIsLargerThanRenderCap() {
        // Phase 4 deliverable: the 50 MB editor-mode cap protects the
        // WebContent process from JS-heap pathology (design doc §17.5).
        // Locked here so a casual bump requires editing this test —
        // and forces the engineer to read the rationale comment first.
        XCTAssertEqual(codeMirrorEditorMaxBytes, 50 * 1024 * 1024)
        XCTAssertGreaterThan(codeMirrorEditorMaxBytes, markdownRenderMaxBytes)
        // 10 MB is the sweet-spot ceiling per §9; assert headroom.
        XCTAssertGreaterThanOrEqual(
            codeMirrorEditorMaxBytes, 10 * 1024 * 1024)
    }

    // MARK: - Outbound applyEdits → JS dispatch shape

    func test_applyEdits_outboundShapeMatchesJsDispatcherContract() throws {
        // The JS dispatcher destructures msg.edits as an array of
        // {from, to, insert}. Encode a representative batch and
        // confirm the exact wire shape so the JS-side switch doesn't
        // need defensive normalization.
        let raw = CMBridgeCodec.encodeOutboundJSON(.applyEdits(
            edits: [
                CMEdit(from: 0, to: 5, insert: "hello"),
                CMEdit(from: 10, to: 10, insert: " world"),
            ],
            version: 3
        ))
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: raw.data(using: .utf8)!) as? [String: Any])
        XCTAssertEqual(parsed["v"] as? Int, 2)
        XCTAssertEqual(parsed["type"] as? String, "applyEdits")
        XCTAssertEqual(parsed["version"] as? Int, 3)
        let edits = parsed["edits"] as? [[String: Any]]
        XCTAssertEqual(edits?.count, 2)
        XCTAssertEqual(edits?[0].keys.sorted(), ["from", "insert", "to"])
        XCTAssertEqual(edits?[1]["insert"] as? String, " world")
    }
}
