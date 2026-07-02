import XCTest

@testable import ViewerCore

/// Canvas M1.S5c (TSK-1360): pure codec tests for the CV envelope — string
/// record ids + the 7 applier verbs. Host-safe, no WebKit.
final class CanvasBridgeCodecTests: XCTestCase {

    // MARK: - outbound

    func test_encode_applyPatches_covers_all_seven_verbs() throws {
        let json = try CVBridgeCodec.encode(
            .applyPatches(
                seq: 7,
                patches: [
                    .setText(id: "nd:a", text: "hi"),
                    .setStyle(id: "nd:a", prop: "color", value: "var(--cv-color-accent)"),
                    .removeStyle(id: "nd:a", prop: "font"),
                    .setAttr(id: "nd:img", attr: "src", value: "x.png"),
                    .insertNode(parent: "pg:1", before: "nd:a", html: "<div data-cv-id=\"nd:new\"></div>"),
                    .removeNode(id: "nd:old"),
                    .moveNode(id: "nd:a", parent: "pg:1", before: nil),
                ]
            ))
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["v"] as? Int, CVProtocol.currentVersion)
        XCTAssertEqual(obj["type"] as? String, "applyPatches")
        let patches = try XCTUnwrap(obj["patches"] as? [[String: Any]])
        XCTAssertEqual(patches.count, 7)
        XCTAssertEqual(patches[0]["op"] as? String, "setText")
        XCTAssertEqual(patches[0]["id"] as? String, "nd:a")
        XCTAssertEqual(patches[1]["prop"] as? String, "color")
        XCTAssertEqual(patches[2]["op"] as? String, "removeStyle")
        XCTAssertEqual(patches[3]["attr"] as? String, "src")
        XCTAssertEqual(patches[4]["op"] as? String, "insertNode")
        XCTAssertEqual(patches[4]["before"] as? String, "nd:a")
        XCTAssertNotNil(patches[4]["html"])
        XCTAssertEqual(patches[5]["op"] as? String, "removeNode")
        XCTAssertEqual(patches[6]["op"] as? String, "moveNode")
        XCTAssertNil(patches[6]["before"], "append is the absent-before form")
    }

    func test_encode_queries_use_string_ids() throws {
        let geo = try CVBridgeCodec.encode(.queryGeometry(replyId: 3, ids: ["nd:a", "pg:1"]))
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(geo.utf8)) as? [String: Any])
        XCTAssertEqual(obj["ids"] as? [String], ["nd:a", "pg:1"])
        let text = try CVBridgeCodec.encode(.queryText(replyId: 4, id: "nd:a"))
        let tobj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(tobj["id"] as? String, "nd:a")
    }

    // MARK: - inbound

    func test_decode_inbound_kinds() throws {
        XCTAssertEqual(
            try CVBridgeCodec.decode("{\"v\":1,\"type\":\"ready\",\"tsMs\":12.5}"),
            .ready(tsMs: 12.5))
        XCTAssertEqual(
            try CVBridgeCodec.decode(
                "{\"v\":1,\"type\":\"applied\",\"seq\":9,\"applied\":2,\"missing\":[\"nd:x\"],\"tsMs\":5,\"applyMs\":0.4}"
            ),
            .applied(seq: 9, applied: 2, missing: ["nd:x"], tsMs: 5, applyMs: 0.4))
        XCTAssertEqual(
            try CVBridgeCodec.decode(
                "{\"v\":1,\"type\":\"geometry\",\"replyId\":3,\"boxes\":[{\"id\":\"nd:a\",\"x\":1,\"y\":2,\"w\":3,\"h\":4}]}"
            ),
            .geometry(replyId: 3, boxes: [CVBox(id: "nd:a", x: 1, y: 2, w: 3, h: 4)]))
        XCTAssertEqual(
            try CVBridgeCodec.decode(
                "{\"v\":1,\"type\":\"text\",\"replyId\":4,\"found\":true,\"text\":\"Row\"}"),
            .text(replyId: 4, found: true, text: "Row"))
    }

    func test_decode_newerVersion_surfaces_not_drops() throws {
        XCTAssertEqual(
            try CVBridgeCodec.decode("{\"v\":99,\"type\":\"ready\",\"tsMs\":0}"),
            .unsupportedVersion(v: 99))
    }

    func test_decode_garbage_throws() {
        XCTAssertThrowsError(try CVBridgeCodec.decode("not json"))
        XCTAssertThrowsError(try CVBridgeCodec.decode(42))
        XCTAssertThrowsError(try CVBridgeCodec.decode("{\"type\":\"ready\"}"))
        XCTAssertThrowsError(try CVBridgeCodec.decode("{\"v\":1,\"type\":\"nope\"}"))
    }

    // MARK: - M3.S2 — edit intents + selection commands (TSK-1373)

    func test_encode_selection_and_editable_commands() throws {
        let sel = try CVBridgeCodec.encode(.setSelection(ids: ["nd:a", "nd:b"]))
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(sel.utf8)) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "setSelection")
        XCTAssertEqual(obj["ids"] as? [String], ["nd:a", "nd:b"])
        let clear = try CVBridgeCodec.encode(.clearSelection)
        XCTAssertTrue(clear.contains("\"type\":\"clearSelection\""))
        let edit = try CVBridgeCodec.encode(.setEditable(id: "nd:t", on: true))
        let eobj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(edit.utf8)) as? [String: Any])
        XCTAssertEqual(eobj["id"] as? String, "nd:t")
        XCTAssertEqual(eobj["on"] as? Bool, true)
    }

    func test_decode_edit_intents() throws {
        XCTAssertEqual(
            try CVBridgeCodec.decode("{\"v\":1,\"type\":\"nodeClicked\",\"id\":\"nd:a\",\"shift\":true}"),
            .nodeClicked(id: "nd:a", shift: true))
        XCTAssertEqual(
            try CVBridgeCodec.decode("{\"v\":1,\"type\":\"nodeClicked\",\"id\":\"nd:a\"}"),
            .nodeClicked(id: "nd:a", shift: false), "shift defaults false")
        XCTAssertEqual(
            try CVBridgeCodec.decode("{\"v\":1,\"type\":\"textEdited\",\"id\":\"nd:t\",\"text\":\"new copy\"}"),
            .textEdited(id: "nd:t", text: "new copy"))
        XCTAssertEqual(
            try CVBridgeCodec.decode(
                "{\"v\":1,\"type\":\"dragEnded\",\"id\":\"nd:a\",\"parent\":\"nd:col\",\"beforeId\":\"nd:b\"}"),
            .dragEnded(id: "nd:a", parent: "nd:col", beforeId: "nd:b"))
        XCTAssertEqual(
            try CVBridgeCodec.decode(
                "{\"v\":1,\"type\":\"dragEnded\",\"id\":\"nd:a\",\"parent\":\"nd:col\"}"),
            .dragEnded(id: "nd:a", parent: "nd:col", beforeId: nil), "append form")
        XCTAssertEqual(
            try CVBridgeCodec.decode("{\"v\":1,\"type\":\"escapePressed\"}"),
            .escapePressed)
        // Malformed intents fail typed, not silently.
        XCTAssertThrowsError(
            try CVBridgeCodec.decode("{\"v\":1,\"type\":\"nodeClicked\"}"))
        XCTAssertThrowsError(
            try CVBridgeCodec.decode("{\"v\":1,\"type\":\"textEdited\",\"id\":\"nd:t\"}"))
    }
}
