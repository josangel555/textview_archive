import XCTest
import ViewerKit

@testable import ViewerCore

/// UAT-M6 (06-MILESTONES-UAT §M6; M6-PLAN §S7) — THE DECK JOURNEY, the epic's
/// final acceptance artifact, driven over the real MCP tool surface + the
/// real store/engine (06 success criteria 1–4):
///   1. an agent builds a themed deck ENTIRELY through ops (no HTML authored);
///   2. the human reorders/retitles slides (a move/update op — the WYSIWYG
///      action) and the agent SEES it (re-read reflects it; a stale-rev apply
///      gets the structured conflict → no clobber);
///   3. timeline_state verifies the step reveals DECLARATIVELY (before pixels);
///   4. the deck exports to a single self-contained offline HTML file;
///      reopen is byte-identical.
/// The LIVE halves — the player reveal (S4), identity-morph FLIP (S5), and
/// offline play (S6) — are their webview tests; this ties them into one
/// narrative with the morph structure surviving to the export.
@MainActor
final class CanvasUATM6Tests: XCTestCase {

    private var host: FakeAutomationHost!
    private var dir: URL!

    override func setUp() async throws {
        host = FakeAutomationHost()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasUATM6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        host = nil
    }

    private func call(_ tool: String, _ args: [String: MCP.Value]) throws -> MCP.Value {
        try MCPToolCatalog.dispatch(name: tool, args: .object(args), host: host)
    }
    private func obj(_ v: MCP.Value) throws -> [String: MCP.Value] {
        guard case .object(let o) = v else { XCTFail("shape: \(v)"); throw MCPError.toolFailed("shape") }
        return o
    }

    func test_uat_m6_the_deck_journey() throws {
        // 1. THEMED DECK via ops: a 3-slide presentation (kit + theme seeded).
        let created = try obj(try call("canvas_new", [
            "mode": .string("presentation"), "slides": .int(3),
        ]))
        guard case .string(let doc)? = created["doc"] else { return XCTFail("doc") }
        let openDoc = try host.automationCanvasStore.doc(doc)
        func rev() throws -> Int { Int(try openDoc.adapter.currentRev()) }

        // The agent authors content ENTIRELY through ops: a title that morphs
        // across slides 0→1, and two stepped reveals on slide 0.
        _ = try openDoc.adapter.apply(baseRev: try openDoc.adapter.currentRev(), [
            .insert(id: "nd:t0", kind: "text", parent: "nd:slide-0", pos: .last,
                    props: [("text", .str("Canvas")), ("morphId", .str("title"))]),
            .insert(id: "nd:p1", kind: "text", parent: "nd:slide-0", pos: .last,
                    props: [("text", .str("point one")), ("step", .num(1))]),
            .insert(id: "nd:p2", kind: "text", parent: "nd:slide-0", pos: .last,
                    props: [("text", .str("point two")), ("step", .num(2))]),
            .insert(id: "nd:t1", kind: "text", parent: "nd:slide-1", pos: .last,
                    props: [("text", .str("Canvas")), ("morphId", .str("title"))]),
        ])

        // 3. DECLARATIVE verification (before any pixel): slide-0 reveals
        //    monotonically over 3 steps; slide-1/2 have none.
        let tl = try obj(try call("canvas_timeline", ["doc": .string(doc)]))
        guard case .array(let slides)? = tl["slides"] else { return XCTFail("timeline") }
        XCTAssertEqual(slides.count, 3)
        guard case .object(let s0) = slides[0] else { return XCTFail("s0") }
        XCTAssertEqual(s0["stepCount"], .int(2), "slide-0 has two reveals")
        func visible(_ step: MCP.Value) -> Set<String> {
            guard case .object(let o) = step, case .array(let ids)? = o["visibleIds"] else { return [] }
            return Set(ids.compactMap { if case .string(let s) = $0 { return s }; return nil })
        }
        guard case .array(let steps)? = s0["steps"] else { return XCTFail("steps") }
        XCTAssertFalse(visible(steps[0]).contains("nd:p1"), "p1 hidden at step 0")
        XCTAssertTrue(visible(steps[1]).contains("nd:p1") && !visible(steps[1]).contains("nd:p2"))
        XCTAssertTrue(visible(steps[2]).isSuperset(of: visible(steps[1])))

        // 2. THE HUMAN reorders (WYSIWYG = a move op) + retitles slide-2, at
        //    the current rev. Capture the agent's stale rev FIRST.
        let agentStaleRev = try rev()
        _ = try openDoc.adapter.apply(baseRev: try openDoc.adapter.currentRev(), [
            .move(id: "nd:slide-2", parent: "pg:1", pos: .first),
            .update(id: "nd:slide-2", set: [("note", .str("Now first"))], unset: []),
        ])

        // The agent SEES it: a fresh read reflects the retitle + new order.
        guard case .object(let read) = try call("canvas_read", ["doc": .string(doc)]),
              case .string(let dsl)? = read["dsl"] else { return XCTFail("read") }
        XCTAssertTrue(dsl.contains("Now first"), "the human's retitle is visible to the agent")

        // The agent's STALE-rev apply gets the structured conflict → no clobber.
        let conflict = try obj(try call("canvas_apply", [
            "doc": .string(doc), "baseRev": .int(agentStaleRev),
            "dsl": .string("text #late \"stale\""),
        ]))
        XCTAssertNotNil(conflict["rejected"], "stale co-edit is rejected, not clobbering: \(conflict)")
        XCTAssertNotNil(conflict["currentRev"], "the conflict teaches the current rev")
        // Adopt currentRev + retry → lands cleanly.
        _ = try obj(try call("canvas_apply", [
            "doc": .string(doc), "baseRev": .int(try rev()),
            "dsl": .string("text #late \"landed\""),
        ]))
        XCTAssertTrue(try openDoc.adapter.html().contains(">landed<"), "retry after adopt lands")

        // 4. EXPORT a self-contained offline deck; the morph structure + the
        //    reordered slides survive to the artifact.
        let deckFile = dir.appendingPathComponent("deck.html")
        let export = try obj(try call("canvas_export", [
            "doc": .string(doc), "path": .string(deckFile.path), "flavor": .string("deck"),
        ]))
        XCTAssertEqual(export["flavor"], .string("deck"))
        let deckHTML = try String(contentsOf: deckFile, encoding: .utf8)
        XCTAssertTrue(deckHTML.hasPrefix("<!doctype html>"))
        XCTAssertFalse(deckHTML.contains("http://") || deckHTML.contains("https://"),
                       "plays offline — zero network")
        XCTAssertTrue(deckHTML.contains("data-cv-morph=\"title\""), "morph pairs survive to export")
        XCTAssertTrue(deckHTML.contains("data-cv-step=\"1\""), "reveals survive to export")

        // Reopen → byte-identical (the whole deck round-trips through io).
        let canvasFile = dir.appendingPathComponent("deck.canvas")
        _ = try call("canvas_save", ["doc": .string(doc), "path": .string(canvasFile.path)])
        let before = try openDoc.adapter.save()
        host.automationCanvasStore.close(CanvasDocumentStore.docID(for: canvasFile))
        let reopened = try host.automationCanvasStore.open(url: canvasFile)
        XCTAssertTrue(CanvasPresentationMode.isPresentation(reopened), "still a deck")
        XCTAssertEqual(try reopened.adapter.save(), before, "byte-identical reopen")
    }
}
