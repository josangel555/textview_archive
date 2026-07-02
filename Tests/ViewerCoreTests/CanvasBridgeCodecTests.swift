import XCTest

@testable import ViewerCore

/// Canvas M0 (TSK-1353): pure codec tests for the CV envelope — host-safe,
/// no WebKit. Mirrors the CodeMirrorBridge test discipline.
final class CanvasBridgeCodecTests: XCTestCase {

    // MARK: - outbound

    func test_encode_applyPatches_producesVersionedEnvelope() throws {
        let json = try CVBridgeCodec.encode(
            .applyPatches(
                seq: 7,
                patches: [
                    CVPatch(op: .setText, id: 3, text: "hi"),
                    CVPatch(op: .setStyle, id: 4, key: "color", value: "red"),
                ]
            ))
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["v"] as? Int, CVProtocol.currentVersion)
        XCTAssertEqual(obj["type"] as? String, "applyPatches")
        XCTAssertEqual(obj["seq"] as? Int, 7)
        let patches = try XCTUnwrap(obj["patches"] as? [[String: Any]])
        XCTAssertEqual(patches.count, 2)
        XCTAssertEqual(patches[0]["op"] as? String, "setText")
        XCTAssertEqual(patches[0]["id"] as? Int, 3)
        XCTAssertEqual(patches[0]["text"] as? String, "hi")
        XCTAssertEqual(patches[1]["key"] as? String, "color")
    }

    func test_encode_setContent_carriesHTMLVerbatim() throws {
        let html = "<div data-cv-id=\"0\">a & b</div>"
        let json = try CVBridgeCodec.encode(.setContent(seq: 1, html: html))
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["html"] as? String, html)
    }

    // MARK: - inbound

    func test_decode_ready_applied_geometry_text() throws {
        let ready = try CVBridgeCodec.decode("{\"v\":1,\"type\":\"ready\",\"tsMs\":12.5}")
        XCTAssertEqual(ready, .ready(tsMs: 12.5))

        let applied = try CVBridgeCodec.decode(
            "{\"v\":1,\"type\":\"applied\",\"seq\":9,\"applied\":2,\"missing\":[7],\"tsMs\":5,\"applyMs\":0.4}"
        )
        XCTAssertEqual(
            applied, .applied(seq: 9, applied: 2, missing: [7], tsMs: 5, applyMs: 0.4))

        let geo = try CVBridgeCodec.decode(
            "{\"v\":1,\"type\":\"geometry\",\"replyId\":3,\"boxes\":[{\"id\":2,\"x\":1,\"y\":2,\"w\":3,\"h\":4}]}"
        )
        XCTAssertEqual(
            geo,
            .geometry(replyId: 3, boxes: [CVBox(id: 2, x: 1, y: 2, w: 3, h: 4)]))

        let text = try CVBridgeCodec.decode(
            "{\"v\":1,\"type\":\"text\",\"replyId\":4,\"found\":true,\"text\":\"Row 0.0\"}")
        XCTAssertEqual(text, .text(replyId: 4, found: true, text: "Row 0.0"))
    }

    func test_decode_newerVersion_surfacesUnsupported_notSilentDrop() throws {
        let msg = try CVBridgeCodec.decode("{\"v\":99,\"type\":\"ready\",\"tsMs\":0}")
        XCTAssertEqual(msg, .unsupportedVersion(v: 99))
    }

    func test_decode_garbage_throws() {
        XCTAssertThrowsError(try CVBridgeCodec.decode("not json"))
        XCTAssertThrowsError(try CVBridgeCodec.decode(42))
        XCTAssertThrowsError(try CVBridgeCodec.decode("{\"type\":\"ready\"}"))  // missing v
        XCTAssertThrowsError(try CVBridgeCodec.decode("{\"v\":1,\"type\":\"nope\"}"))
    }

    // MARK: - outbound JSON is a valid cvDispatch argument (escaping)

    func test_encode_setContent_escapesForJSStringLiteral() throws {
        let html = "<div>\"quotes\" and \\backslash\\ and \nnewline</div>"
        let json = try CVBridgeCodec.encode(.setContent(seq: 2, html: html))
        // Round-trip: the envelope survives JSON parse with content intact.
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["html"] as? String, html)
    }
}
