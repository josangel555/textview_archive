import XCTest
import ViewerKit

@testable import ViewerCore

/// Canvas M2.S3 (TSK-1368): the canvas_* lifecycle + apply tools through the
/// REAL dispatch path (`MCPToolCatalog.dispatch`), a real store, and the real
/// engine. Host-safe. FakeAutomationHost carries a PER-INSTANCE store (its
/// class property is the protocol witness), so tests are isolated from the
/// process-shared default.
@MainActor
final class CanvasMCPToolsTests: XCTestCase {

    private var host: FakeAutomationHost!
    private var dir: URL!

    override func setUp() async throws {
        host = FakeAutomationHost()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasMCPTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        host = nil
    }

    private func call(_ tool: String, _ args: [String: MCP.Value]) throws -> MCP.Value {
        try MCPToolCatalog.dispatch(name: tool, args: .object(args), host: host)
    }

    func test_descriptors_are_registered_and_teach_the_dsl() {
        let names = MCPToolCatalog.all.map(\.name)
        for tool in ["canvas_new", "canvas_open", "canvas_save", "canvas_apply"] {
            XCTAssertTrue(names.contains(tool), "\(tool) missing from the catalog")
        }
        let apply = MCPToolCatalog.all.first { $0.name == "canvas_apply" }
        XCTAssertTrue(apply?.description.contains("canvas_vocab") == true,
                      "the description points at the full vocabulary")
        XCTAssertTrue(apply?.description.contains("rejection is DATA") == true)
    }

    func test_new_apply_save_open_journey_with_lint_riding() throws {
        // new
        let created = try call("canvas_new", [:])
        guard case .object(let newObj) = created,
              case .string(let doc)? = newObj["doc"] else {
            return XCTFail("canvas_new shape: \(created)")
        }
        // apply — raw literal in a themeable slot so lint MUST ride.
        let applied = try call("canvas_apply", [
            "doc": .string(doc), "baseRev": .int(0),
            "dsl": .string("shape #s fill=\"#ff0000\"\ntext #t \"hello tools\""),
        ])
        guard case .object(let a) = applied else { return XCTFail("apply shape") }
        XCTAssertEqual(a["rev"], .int(1))
        XCTAssertEqual(a["applied"], .int(2))
        XCTAssertEqual(a["noop"], .bool(false))
        guard case .array(let lint)? = a["lint"] else { return XCTFail("lint missing") }
        XCTAssertTrue(lint.contains { v in
            if case .object(let f) = v, case .string(let code)? = f["code"] {
                return code == "raw-literal-themeable"
            }
            return false
        }, "the tier-2 steer rides the tool response: \(lint)")

        // save (untitled → path re-keys)
        let target = dir.appendingPathComponent("tools.canvas")
        let saved = try call("canvas_save", [
            "doc": .string(doc), "path": .string(target.path),
        ])
        guard case .object(let s) = saved, case .string(let newDoc)? = s["doc"] else {
            return XCTFail("save shape: \(saved)")
        }
        XCTAssertEqual(newDoc, CanvasDocumentStore.docID(for: target))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))

        // open (dedupes onto the same doc)
        let opened = try call("canvas_open", ["path": .string(target.path)])
        guard case .object(let o) = opened, case .string(let openedDoc)? = o["doc"] else {
            return XCTFail("open shape: \(opened)")
        }
        XCTAssertEqual(openedDoc, newDoc)
    }

    func test_rejections_are_data_with_the_retry_loop_working() throws {
        let created = try call("canvas_new", [:])
        guard case .object(let n) = created, case .string(let doc)? = n["doc"] else {
            return XCTFail("new shape")
        }
        _ = try call("canvas_apply", [
            "doc": .string(doc), "baseRev": .int(0), "dsl": .string("text #t \"v1\""),
        ])

        // Stale baseRev → conflict DATA carrying currentRev.
        let conflicted = try call("canvas_apply", [
            "doc": .string(doc), "baseRev": .int(0), "dsl": .string("set #t \"v2\""),
        ])
        guard case .object(let c) = conflicted else { return XCTFail("shape") }
        XCTAssertEqual(c["rejected"], .string("conflict"))
        guard case .int(let currentRev)? = c["currentRev"] else {
            return XCTFail("currentRev missing")
        }
        // The retry loop: reuse the reported rev and succeed.
        let retried = try call("canvas_apply", [
            "doc": .string(doc), "baseRev": .int(currentRev), "dsl": .string("set #t \"v2\""),
        ])
        guard case .object(let r) = retried else { return XCTFail("shape") }
        XCTAssertEqual(r["rev"], .int(currentRev + 1))

        // DSL teaching error surfaces VERBATIM (line-anchored).
        let taught = try call("canvas_apply", [
            "doc": .string(doc), "baseRev": .int(currentRev + 1),
            "dsl": .string("wormhole #x"),
        ])
        guard case .object(let t) = taught, case .string(let detail)? = t["detail"] else {
            return XCTFail("teaching shape: \(taught)")
        }
        XCTAssertEqual(t["rejected"], .string("dsl"))
        XCTAssertTrue(detail.contains("line 1"), "\(detail)")
        XCTAssertTrue(detail.contains("frame, text, image"), "names the legal set")

        // Unknown doc: a typed param error teaching what IS open.
        XCTAssertThrowsError(try call("canvas_apply", [
            "doc": .string("nope"), "baseRev": .int(0), "dsl": .string("text \"x\""),
        ])) { error in
            guard case MCPError.invalidParams(let msg) = error else {
                return XCTFail("expected invalidParams, got \(error)")
            }
            XCTAssertTrue(msg.contains("open docs:"), "\(msg)")
        }
    }

    // MARK: M2.S4 — read-side tools (TSK-1369)

    func test_read_wholePage_anchorSlice_and_json_forms() throws {
        guard case .object(let n) = try call("canvas_new", [:]),
              case .string(let doc)? = n["doc"] else { return XCTFail("new") }
        _ = try call("canvas_apply", [
            "doc": .string(doc), "baseRev": .int(0),
            "dsl": .string("frame #hero gap=8 {\n  text #title \"readable\"\n}\ntext #tail \"outside\""),
        ])
        // Whole page.
        guard case .object(let whole) = try call("canvas_read", ["doc": .string(doc)]),
              case .string(let dsl)? = whole["dsl"] else { return XCTFail("read shape") }
        XCTAssertTrue(dsl.contains("frame #hero"))
        XCTAssertTrue(dsl.contains("text #tail"))
        XCTAssertEqual(whole["rev"], .int(1))
        // Anchor slice: contains the subtree, not the sibling.
        guard case .object(let sliced) = try call("canvas_read", [
            "doc": .string(doc), "anchor": .string("#hero"),
        ]), case .string(let slice)? = sliced["dsl"] else { return XCTFail("slice shape") }
        XCTAssertTrue(slice.contains("#title"))
        XCTAssertFalse(slice.contains("#tail"), "slice must exclude siblings")
        // Unknown anchor teaches.
        XCTAssertThrowsError(try call("canvas_read", [
            "doc": .string(doc), "anchor": .string("#nope"),
        ])) { error in
            guard case MCPError.invalidParams(let msg) = error else {
                return XCTFail("expected invalidParams, got \(error)")
            }
            XCTAssertTrue(msg.contains("#nope"))
        }
        // JSON form parses and carries the format version.
        guard case .object(let j) = try call("canvas_read", [
            "doc": .string(doc), "format": .string("json"),
        ]), case .string(let json)? = j["json"] else { return XCTFail("json shape") }
        XCTAssertTrue(json.contains("\"formatVersion\":1"))
    }

    func test_vocab_lint_undo_tools_close_the_loop() throws {
        // Vocab without a doc: default theme; with format json parses.
        guard case .object(let v) = try call("canvas_vocab", [:]),
              case .string(let vocab)? = v["vocabulary"] else { return XCTFail("vocab") }
        XCTAssertTrue(vocab.contains("ELEMENTS AND THEIR PROPS"))
        guard case .object(let vj) = try call("canvas_vocab", ["format": .string("json")]),
              case .string(let vocabJSON)? = vj["vocabulary"] else { return XCTFail("vocab json") }
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(vocabJSON.utf8)) as? [String: Any])

        // Lint: a hole surfaces through the tool.
        guard case .object(let n) = try call("canvas_new", [:]),
              case .string(let doc)? = n["doc"] else { return XCTFail("new") }
        _ = try call("canvas_apply", [
            "doc": .string(doc), "baseRev": .int(0),
            "dsl": .string("hole #todo note=\"finish the chart\""),
        ])
        guard case .object(let l) = try call("canvas_lint", ["doc": .string(doc)]),
              case .array(let lint)? = l["lint"] else { return XCTFail("lint shape") }
        XCTAssertTrue(lint.contains { v in
            if case .object(let f) = v, case .string(let code)? = f["code"] { return code == "hole" }
            return false
        }, "hole audit through the tool: \(lint)")

        // Undo through the tool restores; empty history is data.
        guard case .object(let u1) = try call("canvas_undo", ["doc": .string(doc)]) else {
            return XCTFail("undo shape")
        }
        XCTAssertEqual(u1["undone"], .bool(true))
        guard case .object(let read) = try call("canvas_read", ["doc": .string(doc)]),
              case .string(let after)? = read["dsl"] else { return XCTFail("read") }
        XCTAssertFalse(after.contains("#todo"), "undo removed the hole")
        guard case .object(let u2) = try call("canvas_undo", ["doc": .string(doc)]) else {
            return XCTFail("undo2 shape")
        }
        XCTAssertEqual(u2["undone"], .bool(false), "empty history is data, not an error")
    }
}
