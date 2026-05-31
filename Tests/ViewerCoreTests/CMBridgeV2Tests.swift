import XCTest
@testable import ViewerCore

/// Phase 4 (v2) protocol coverage. The existing `CMBridgeV1Tests` /
/// `CMOutboundEncodingTests` lock in v1 wire shapes; this suite adds:
///
///   - Envelope: encoder stamps `v=currentVersion` (2); decoder accepts
///     v1..v2.
///   - New inbound: `incrementalChange`.
///   - New outbound: `applyEdits`, `setFoldingRanges`,
///     `setGutterMarkers`, `setIndentGuides`.
///
/// Forward-compat is load-bearing: a freshly-bumped Swift binary must
/// keep accepting v1 envelopes for one release cycle so a stale JS
/// bundle still functions.
final class CMBridgeV2Tests: XCTestCase {

    // MARK: - Version policy

    func testCurrentVersionIsTwo() {
        // Pin the bumped value. If you change `CMProtocol.currentVersion`
        // you must also update the JS host (`codemirror.html`) and the
        // BUILD.md re-bundle docs. Catching it here forces both to
        // travel together.
        XCTAssertEqual(CMProtocol.currentVersion, 2)
        XCTAssertEqual(CMProtocol.oldestSupportedVersion, 1)
    }

    func testDecoderAcceptsV1Envelope() {
        // A v1 `ready` payload from a stale JS bundle must still parse
        // post-bump. Document the policy: rolling upgrades cross the
        // wire in either direction during the cycle.
        let dict: [String: Any] = ["v": 1, "type": "ready"]
        XCTAssertNotNil(CMBridgeCodec.decodeInbound(dict))
    }

    func testDecoderRejectsTooOldEnvelope() {
        let dict: [String: Any] = ["v": 0, "type": "ready"]
        XCTAssertNil(CMBridgeCodec.decodeInbound(dict))
    }

    func testDecoderRejectsTooNewEnvelope() {
        // Future messages must NOT parse as v2 / v1 (misinterpreting a
        // renamed field would be worse than dropping). API-08: rather
        // than a bare nil, surface `.unsupportedVersion` so the host can
        // log an actionable "update the app" and pin outbound down.
        let dict: [String: Any] = ["v": 99, "type": "ready"]
        XCTAssertEqual(CMBridgeCodec.decodeInbound(dict), .unsupportedVersion(99))
    }

    func testEncoderStampsCurrentVersion() {
        let raw = CMBridgeCodec.encodeOutboundJSON(
            .setIndentGuides(true))
        let parsed = try? JSONSerialization.jsonObject(
            with: raw.data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(parsed?["v"] as? Int, CMProtocol.currentVersion)
    }

    // MARK: - Inbound: incrementalChange

    func testDecodeIncrementalChange() {
        let dict: [String: Any] = [
            "v": 2,
            "type": "incrementalChange",
            "edits": [
                ["from": 0, "to": 0, "insert": "X"],
                ["from": 5, "to": 7, "insert": "ab"],
            ],
            "version": 12,
            "contentLength": 8,
        ]
        guard case .incrementalChange(let edits, let v, let len) =
                CMBridgeCodec.decodeInbound(dict) else {
            return XCTFail("expected incrementalChange")
        }
        XCTAssertEqual(edits.count, 2)
        XCTAssertEqual(edits[0], CMEdit(from: 0, to: 0, insert: "X"))
        XCTAssertEqual(edits[1], CMEdit(from: 5, to: 7, insert: "ab"))
        XCTAssertEqual(v, 12)
        XCTAssertEqual(len, 8)
    }

    func testDecodeIncrementalChangeEmptyEditsIsValid() {
        // The JS emitter never ships an empty batch (it would have
        // returned early), but defensive: decoder must accept it
        // without producing junk.
        let dict: [String: Any] = [
            "v": 2,
            "type": "incrementalChange",
            "edits": [],
            "version": 1,
            "contentLength": 0,
        ]
        guard case .incrementalChange(let edits, _, _) =
                CMBridgeCodec.decodeInbound(dict) else {
            return XCTFail("expected incrementalChange")
        }
        XCTAssertEqual(edits, [])
    }

    func testDecodeIncrementalChangeMissingEditsArrayDrops() {
        let dict: [String: Any] = [
            "v": 2,
            "type": "incrementalChange",
            "version": 1,
            "contentLength": 0,
        ]
        XCTAssertNil(CMBridgeCodec.decodeInbound(dict))
    }

    func testDecodeIncrementalChangeBadEntryDropsBatch() {
        // One bad entry (`to < from`) invalidates the whole batch —
        // partial application would diverge Swift's mirror from CM's.
        let dict: [String: Any] = [
            "v": 2,
            "type": "incrementalChange",
            "edits": [
                ["from": 0, "to": 0, "insert": "X"],
                ["from": 5, "to": 3, "insert": ""],
            ],
            "version": 1,
            "contentLength": 0,
        ]
        XCTAssertNil(CMBridgeCodec.decodeInbound(dict))
    }

    func testDecodeIncrementalChangeInsertFieldDefaultsToEmpty() {
        // JS may emit pure-delete entries as `{from, to}` without an
        // `insert` field; treat as empty string.
        let dict: [String: Any] = [
            "v": 2,
            "type": "incrementalChange",
            "edits": [["from": 1, "to": 3]],
            "version": 1,
            "contentLength": 5,
        ]
        guard case .incrementalChange(let edits, _, _) =
                CMBridgeCodec.decodeInbound(dict) else {
            return XCTFail("expected incrementalChange")
        }
        XCTAssertEqual(edits, [CMEdit(from: 1, to: 3, insert: "")])
    }

    // MARK: - Outbound: applyEdits

    func testEncodeApplyEdits() {
        let raw = CMBridgeCodec.encodeOutboundJSON(.applyEdits(
            edits: [
                CMEdit(from: 0, to: 0, insert: "X"),
                CMEdit(from: 3, to: 5, insert: "ab"),
            ],
            version: 7
        ))
        let dict = try? JSONSerialization.jsonObject(
            with: raw.data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(dict?["type"] as? String, "applyEdits")
        XCTAssertEqual(dict?["version"] as? Int, 7)
        let arr = dict?["edits"] as? [[String: Any]]
        XCTAssertEqual(arr?.count, 2)
        XCTAssertEqual(arr?[1]["from"] as? Int, 3)
        XCTAssertEqual(arr?[1]["to"] as? Int, 5)
        XCTAssertEqual(arr?[1]["insert"] as? String, "ab")
    }

    func testEncodeApplyEditsEmpty() {
        let raw = CMBridgeCodec.encodeOutboundJSON(.applyEdits(
            edits: [], version: 0))
        let dict = try? JSONSerialization.jsonObject(
            with: raw.data(using: .utf8)!) as? [String: Any]
        let arr = dict?["edits"] as? [[String: Any]]
        XCTAssertEqual(arr?.count, 0)
    }

    // MARK: - Outbound: setFoldingRanges

    func testEncodeSetFoldingRangesKindOmittedWhenNil() {
        let raw = CMBridgeCodec.encodeOutboundJSON(.setFoldingRanges([
            CMFoldRange(from: 10, to: 20, kind: nil),
            CMFoldRange(from: 30, to: 40, kind: "comment"),
        ]))
        let dict = try? JSONSerialization.jsonObject(
            with: raw.data(using: .utf8)!) as? [String: Any]
        let arr = dict?["ranges"] as? [[String: Any]]
        XCTAssertEqual(arr?.count, 2)
        XCTAssertNil(arr?[0]["kind"],
                     "kind must be omitted (not null) when Swift side has nil")
        XCTAssertEqual(arr?[1]["kind"] as? String, "comment")
    }

    func testEncodeSetFoldingRangesEmptyClears() {
        // Empty array is the explicit "clear" signal — the JS-side
        // applyer falls back to language-default fold heuristics.
        let raw = CMBridgeCodec.encodeOutboundJSON(.setFoldingRanges([]))
        let dict = try? JSONSerialization.jsonObject(
            with: raw.data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual((dict?["ranges"] as? [[String: Any]])?.count, 0)
    }

    // MARK: - Outbound: setGutterMarkers

    func testEncodeSetGutterMarkers() {
        let raw = CMBridgeCodec.encodeOutboundJSON(.setGutterMarkers([
            CMGutterMarker(line: 1, kind: "added"),
            CMGutterMarker(line: 7, kind: "blame", tooltip: "jos · 2 days ago"),
        ]))
        let dict = try? JSONSerialization.jsonObject(
            with: raw.data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(dict?["type"] as? String, "setGutterMarkers")
        let arr = dict?["markers"] as? [[String: Any]]
        XCTAssertEqual(arr?.count, 2)
        XCTAssertEqual(arr?[0]["line"] as? Int, 1)
        XCTAssertEqual(arr?[0]["kind"] as? String, "added")
        XCTAssertNil(arr?[0]["tooltip"], "tooltip omitted when nil")
        XCTAssertEqual(arr?[1]["tooltip"] as? String, "jos · 2 days ago")
    }

    // MARK: - Outbound: setIndentGuides

    func testEncodeSetIndentGuides() {
        let raw = CMBridgeCodec.encodeOutboundJSON(.setIndentGuides(true))
        let dict = try? JSONSerialization.jsonObject(
            with: raw.data(using: .utf8)!) as? [String: Any]
        XCTAssertEqual(dict?["type"] as? String, "setIndentGuides")
        XCTAssertEqual(dict?["enabled"] as? Bool, true)
    }

    // MARK: - API-08: v > current surfaces as .unsupportedVersion

    func testDecodeTooNewEnvelopeReturnsUnsupportedVersion() {
        // A future v3 envelope must NOT silently nil-drop — it surfaces
        // as .unsupportedVersion(3) so the host can log "update the app"
        // and the bridge can pin outbound traffic down.
        let got = CMBridgeCodec.decodeInbound(["v": 3, "type": "ready"])
        XCTAssertEqual(got, .unsupportedVersion(3))
    }

    func testDecodeTooNewEnvelopeWithoutTypeStillSurfacesVersion() {
        // A too-new envelope surfaces `.unsupportedVersion` even without
        // a `type`: a future protocol might rename/drop `type`, and the
        // actionable signal is the version itself. (We must NOT require
        // `type` here or the "please update" log never fires for exactly
        // the protocols that need it.)
        XCTAssertEqual(CMBridgeCodec.decodeInbound(["v": 3]), .unsupportedVersion(3))
    }

    func testDecodeMissingVersionStillNil() {
        // No `v` at all is unclassifiable garbage → hard nil (not
        // unsupportedVersion, which is specifically "newer than us").
        XCTAssertNil(CMBridgeCodec.decodeInbound(["type": "ready"]))
    }

    func testDecodeTooOldEnvelopeStillNil() {
        // Too-OLD is still a hard drop — we no longer speak that dialect.
        XCTAssertNil(CMBridgeCodec.decodeInbound(["v": 0, "type": "ready"]))
    }

    // MARK: - API-06/07: peer-version-aware outbound encode

    func testMinimumVersionTable() {
        // v2-only message types report minimumVersion 2; everything else 1.
        XCTAssertEqual(CMOutboundMessage.setIndentGuides(true).minimumVersion, 2)
        XCTAssertEqual(CMOutboundMessage.setGutterMarkers([]).minimumVersion, 2)
        XCTAssertEqual(CMOutboundMessage.setFoldingRanges([]).minimumVersion, 2)
        XCTAssertEqual(CMOutboundMessage.applyEdits(edits: [], version: 0).minimumVersion, 2)
        XCTAssertEqual(
            CMOutboundMessage.setText(text: "x", resetHistory: false, preserveSelection: true)
                .minimumVersion, 1)
        XCTAssertEqual(CMOutboundMessage.undo.minimumVersion, 1)
        XCTAssertEqual(CMOutboundMessage.flushChanges.minimumVersion, 1)
    }

    func testEncodeDowngradesEnvelopeToPeerVersion() {
        // A v1 message bound for a v1 peer must stamp v:1 even though the
        // Swift binary is at currentVersion 2 — otherwise the JS guard
        // (which only accepts oldest..PROTOCOL_VERSION it knows) rejects.
        let dict = CMBridgeCodec.encodeOutbound(
            .setText(text: "hi", resetHistory: false, preserveSelection: true),
            peerVersion: 1
        )
        XCTAssertEqual(dict?["v"] as? Int, 1, "envelope must downgrade to the peer's version")
        XCTAssertEqual(dict?["type"] as? String, "setText")
    }

    func testEncodeRefusesV2OnlyMessageToV1Peer() {
        // setGutterMarkers has no handler in a v1 JS bundle. Encoding it
        // for a v1 peer must REFUSE (nil) so the caller skips the
        // dispatch — shipping it stamped v:1 would land as an
        // "unknown message type" error and the host would wrongly
        // believe the push succeeded.
        XCTAssertNil(
            CMBridgeCodec.encodeOutbound(.setGutterMarkers([
                CMGutterMarker(line: 1, kind: "added"),
            ]), peerVersion: 1)
        )
        XCTAssertNil(
            CMBridgeCodec.encodeOutboundJSON(.setIndentGuides(true), peerVersion: 1)
        )
    }

    func testEncodeAllowsV2MessageToV2Peer() {
        let dict = CMBridgeCodec.encodeOutbound(.setIndentGuides(true), peerVersion: 2)
        XCTAssertEqual(dict?["v"] as? Int, 2)
        XCTAssertEqual(dict?["type"] as? String, "setIndentGuides")
    }

    func testEncodePeerVersionAboveCurrentClampsToCurrent() {
        // A peer that claims a higher version than we know: we still
        // stamp our currentVersion (we can't speak a dialect we don't
        // have), never a `v` above currentVersion.
        let dict = CMBridgeCodec.encodeOutbound(.undo, peerVersion: 99)
        XCTAssertEqual(dict?["v"] as? Int, CMProtocol.currentVersion)
    }

    func testConvenienceEncodeMatchesCurrentVersionPeer() {
        // The no-peer convenience must behave exactly like passing
        // currentVersion as the peer.
        let a = CMBridgeCodec.encodeOutbound(.focus)
        let b = CMBridgeCodec.encodeOutbound(.focus, peerVersion: CMProtocol.currentVersion)
        XCTAssertEqual(a["v"] as? Int, b?["v"] as? Int)
        XCTAssertEqual(a["type"] as? String, b?["type"] as? String)
    }
}
