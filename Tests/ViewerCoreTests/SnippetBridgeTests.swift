import XCTest
@testable import ViewerCore

/// TSK-705 — bridge codec coverage for the snippet tab-stop messages:
/// `setSnippetSessionActive` (Swift → JS) and `snippetTab` (JS → Swift). The
/// JS `cmDispatch` switch / `post(...)` eat / produce these exact envelopes, so
/// a field-name regression at this boundary surfaces here on the host instead
/// of as a silent no-op in the WebView.
final class SnippetBridgeTests: XCTestCase {

    // MARK: - Outbound: setSnippetSessionActive

    private func encodeAndParse(_ m: CMOutboundMessage) -> [String: Any] {
        let raw = CMBridgeCodec.encodeOutboundJSON(m)
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { XCTFail("Encoded JSON didn't parse: \(raw)"); return [:] }
        return dict
    }

    func test_encode_setSnippetSessionActive_true() {
        let d = encodeAndParse(.setSnippetSessionActive(true))
        XCTAssertEqual(d["type"] as? String, "setSnippetSessionActive")
        XCTAssertEqual(d["active"] as? Bool, true)
    }

    func test_encode_setSnippetSessionActive_false() {
        let d = encodeAndParse(.setSnippetSessionActive(false))
        XCTAssertEqual(d["type"] as? String, "setSnippetSessionActive")
        XCTAssertEqual(d["active"] as? Bool, false)
    }

    func test_setSnippetSessionActive_isV2() {
        // The handler is a v2 addition; it must not be sent to a v1 peer.
        XCTAssertEqual(CMOutboundMessage.setSnippetSessionActive(true).minimumVersion, 2)
    }

    // MARK: - Inbound: snippetTab

    func test_decode_snippetTab_forward() {
        let body: [String: Any] = [
            "v": CMProtocol.currentVersion, "type": "snippetTab", "forward": true,
        ]
        XCTAssertEqual(CMBridgeCodec.decodeInbound(body), .snippetTab(forward: true))
    }

    func test_decode_snippetTab_backward() {
        let body: [String: Any] = [
            "v": CMProtocol.currentVersion, "type": "snippetTab", "forward": false,
        ]
        XCTAssertEqual(CMBridgeCodec.decodeInbound(body), .snippetTab(forward: false))
    }

    func test_decode_snippetTab_defaultsForwardWhenMissing() {
        // A `snippetTab` envelope without a `forward` flag is treated as Tab.
        let body: [String: Any] = [
            "v": CMProtocol.currentVersion, "type": "snippetTab",
        ]
        XCTAssertEqual(CMBridgeCodec.decodeInbound(body), .snippetTab(forward: true))
    }
}
