import XCTest
@testable import ViewerCore

/// Pure-logic tests for the CodeMirror 6 bridge protocol v1 codec.
/// Covers the envelope rules from `docs/CM6_INTEGRATION_DESIGN_2026-05-23.md`
/// §13. Runs on host — no WKWebView, no AppKit.
final class CMBridgeV1Tests: XCTestCase {

    // MARK: - Envelope validation

    func testDecodeRejectsMissingVersion() {
        XCTAssertNil(CMBridgeCodec.decodeInbound(["type": "ready"]))
    }

    func testDecodeRejectsTooOldVersion() {
        // Below oldestSupportedVersion is a hard drop — we no longer
        // speak that dialect. (Too-NEW is handled separately as
        // .unsupportedVersion; see CMBridgeV2Tests.)
        XCTAssertNil(CMBridgeCodec.decodeInbound(["v": 0, "type": "ready"]))
    }

    func testDecodeTooNewVersionIsUnsupportedNotNil() {
        // API-08: a too-new envelope is NOT a bare nil — it surfaces
        // .unsupportedVersion so the host can log + downgrade.
        XCTAssertEqual(
            CMBridgeCodec.decodeInbound(["v": 99, "type": "ready"]),
            .unsupportedVersion(99)
        )
    }

    func testDecodeRejectsMissingType() {
        XCTAssertNil(CMBridgeCodec.decodeInbound(["v": 1]))
    }

    func testDecodeRejectsNonDictionary() {
        XCTAssertNil(CMBridgeCodec.decodeInbound("not a dict"))
        XCTAssertNil(CMBridgeCodec.decodeInbound(42))
        XCTAssertNil(CMBridgeCodec.decodeInbound(NSNull()))
    }

    func testDecodeUnknownTypeReturnsUnknown() {
        // Unknown type within a valid envelope is *not* nil — it's
        // .unknown so the host can log + drop without crash.
        let got = CMBridgeCodec.decodeInbound(["v": 1, "type": "futureMessage"])
        XCTAssertEqual(got, .unknown(type: "futureMessage"))
    }

    func testDecodeAcceptsJSONData() {
        // WKScriptMessage.body is usually a dict, but for tests we also
        // accept Data and String for ergonomics.
        let json = #"{"v":1,"type":"ready"}"#.data(using: .utf8)!
        XCTAssertEqual(CMBridgeCodec.decodeInbound(json), .ready(version: 1))
    }

    func testDecodeAcceptsJSONString() {
        XCTAssertEqual(
            CMBridgeCodec.decodeInbound(#"{"v":1,"type":"save"}"#),
            .save
        )
    }

    // MARK: - Each inbound case

    func testDecodeReady() {
        XCTAssertEqual(
            CMBridgeCodec.decodeInbound(["v": 1, "type": "ready"]),
            .ready(version: 1)
        )
    }

    func testDecodeChange() {
        let got = CMBridgeCodec.decodeInbound([
            "v": 1, "type": "change",
            "text": "hello", "version": 7, "contentLength": 5,
        ])
        XCTAssertEqual(got, .change(text: "hello", version: 7, contentLength: 5))
    }

    func testDecodeChangeWithMissingFieldsUsesDefaults() {
        let got = CMBridgeCodec.decodeInbound(["v": 1, "type": "change"])
        XCTAssertEqual(got, .change(text: "", version: 0, contentLength: 0))
    }

    func testDecodeSave() {
        XCTAssertEqual(
            CMBridgeCodec.decodeInbound(["v": 1, "type": "save"]),
            .save
        )
    }

    func testDecodeCursorPosition() {
        let got = CMBridgeCodec.decodeInbound([
            "v": 1, "type": "cursorPositionChanged",
            "line": 12, "column": 4, "head": 138, "ranges": 1,
        ])
        XCTAssertEqual(
            got,
            .cursorPositionChanged(line: 12, column: 4, head: 138, ranges: 1)
        )
    }

    func testDecodeSelectionChangedAcceptsObject() {
        let got = CMBridgeCodec.decodeInbound([
            "v": 1, "type": "selectionChanged",
            "selection": ["main": 0, "ranges": [["anchor": 0, "head": 5]]],
            "hasSelection": true,
        ])
        guard case .selectionChanged(let json, let hasSel) = got else {
            return XCTFail("expected .selectionChanged, got \(String(describing: got))")
        }
        XCTAssertTrue(hasSel)
        XCTAssertTrue(json.contains("\"main\""))
    }

    func testDecodeScrollChanged() {
        let got = CMBridgeCodec.decodeInbound([
            "v": 1, "type": "scrollChanged",
            "top": 100, "left": 0, "viewportFromLine": 5, "viewportToLine": 42,
        ])
        XCTAssertEqual(
            got,
            .scrollChanged(top: 100, left: 0, viewportFromLine: 5, viewportToLine: 42)
        )
    }

    func testDecodeFindOpenedAndClosed() {
        XCTAssertEqual(
            CMBridgeCodec.decodeInbound(["v": 1, "type": "findOpened", "query": "abc"]),
            .findOpened(query: "abc")
        )
        XCTAssertEqual(
            CMBridgeCodec.decodeInbound(["v": 1, "type": "findClosed"]),
            .findClosed
        )
    }

    func testDecodeFindResultChanged() {
        XCTAssertEqual(
            CMBridgeCodec.decodeInbound([
                "v": 1, "type": "findResultChanged",
                "matches": 12, "current": 3,
            ]),
            .findResultChanged(matches: 12, current: 3)
        )
    }

    func testDecodeLinkClicked() {
        XCTAssertEqual(
            CMBridgeCodec.decodeInbound([
                "v": 1, "type": "linkClicked",
                "href": "https://x.com", "line": 2, "column": 7,
            ]),
            .linkClicked(href: "https://x.com", line: 2, column: 7)
        )
    }

    func testDecodeEditorBlurred() {
        XCTAssertEqual(
            CMBridgeCodec.decodeInbound(["v": 1, "type": "editorBlurred"]),
            .editorBlurred
        )
    }

    func testDecodeErrorOccurred() {
        XCTAssertEqual(
            CMBridgeCodec.decodeInbound([
                "v": 1, "type": "errorOccurred",
                "phase": "dispatch:setText", "message": "boom",
                "stack": "at foo:42",
            ]),
            .errorOccurred(phase: "dispatch:setText", message: "boom", stack: "at foo:42")
        )
    }

    func testDecodeRequestReplyWithObjectValue() {
        let got = CMBridgeCodec.decodeInbound([
            "v": 1, "type": "requestReply",
            "replyId": "r-abc",
            "value": ["text": "doc", "version": 5],
        ])
        guard case .requestReply(let rid, let valJSON) = got else {
            return XCTFail("expected .requestReply, got \(String(describing: got))")
        }
        XCTAssertEqual(rid, "r-abc")
        XCTAssertTrue(valJSON.contains("\"text\""))
        XCTAssertTrue(valJSON.contains("\"version\""))
    }

    func testDecodeRequestReplyRejectsMissingReplyId() {
        XCTAssertNil(CMBridgeCodec.decodeInbound([
            "v": 1, "type": "requestReply", "value": "x",
        ]))
    }

    // MARK: - Phase 3 additions: hover / definition / context menu

    func testDecodeRequestHover() {
        XCTAssertEqual(
            CMBridgeCodec.decodeInbound([
                "v": 1, "type": "requestHover",
                "pos": 42, "line": 3, "character": 5,
                "replyId": "h-9",
            ]),
            .requestHover(pos: 42, line: 3, character: 5, replyId: "h-9")
        )
    }

    func testDecodeRequestHoverRejectsMissingReplyId() {
        XCTAssertNil(CMBridgeCodec.decodeInbound([
            "v": 1, "type": "requestHover", "pos": 0, "line": 1, "character": 0,
        ]))
    }

    func testDecodeRequestDefinition() {
        XCTAssertEqual(
            CMBridgeCodec.decodeInbound([
                "v": 1, "type": "requestDefinition",
                "pos": 100, "line": 12, "character": 7,
            ]),
            .requestDefinition(pos: 100, line: 12, character: 7)
        )
    }

    func testDecodeContextMenuRequested() {
        let got = CMBridgeCodec.decodeInbound([
            "v": 1, "type": "contextMenuRequested",
            "pos": 50, "line": 4, "character": 8,
            "screenX": 200.0, "screenY": 300.0,
            "selection": "foo", "hasSelection": true,
        ])
        guard case .contextMenuRequested(let pos, let line, let ch,
                                         let sx, let sy, let sel, let has) = got
        else {
            return XCTFail("expected .contextMenuRequested, got \(String(describing: got))")
        }
        XCTAssertEqual(pos, 50)
        XCTAssertEqual(line, 4)
        XCTAssertEqual(ch, 8)
        XCTAssertEqual(sx, 200.0, accuracy: 0.001)
        XCTAssertEqual(sy, 300.0, accuracy: 0.001)
        XCTAssertEqual(sel, "foo")
        XCTAssertTrue(has)
    }

    func testDecodeContextMenuRequestedAcceptsIntCoords() {
        // JS sometimes serializes screenX/Y as integers (when whole
        // pixels). Decoder must tolerate both.
        let got = CMBridgeCodec.decodeInbound([
            "v": 1, "type": "contextMenuRequested",
            "pos": 0, "line": 1, "character": 0,
            "screenX": 200, "screenY": 300,
        ])
        guard case .contextMenuRequested(_, _, _, let sx, let sy, _, _) = got else {
            return XCTFail("expected .contextMenuRequested")
        }
        XCTAssertEqual(sx, 200.0, accuracy: 0.001)
        XCTAssertEqual(sy, 300.0, accuracy: 0.001)
    }
}
