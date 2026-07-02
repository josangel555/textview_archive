import XCTest
import ViewerKit

@testable import ViewerCore

/// UAT-M2 (06-MILESTONES-UAT §M2; M2-PLAN §S5) — THE AGENT JOURNEY, driven
/// over NOTHING but the MCP tool surface (real dispatch, real store, real
/// engine): discover → create → author (with a deliberate mistake — the
/// teaching loop) → read back → conflict-retry → lint → undo → save →
/// reopen → identical. Plus the milestone's latency budget on a 1k-node
/// document (tool round-trip p95 < 20ms). This test is the milestone's
/// acceptance artifact.
@MainActor
final class CanvasUATM2Tests: XCTestCase {

    private var host: FakeAutomationHost!
    private var dir: URL!

    override func setUp() async throws {
        host = FakeAutomationHost()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasUATM2-\(UUID().uuidString)")
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
        guard case .object(let o) = v else {
            XCTFail("expected object, got \(v)")
            throw MCPError.toolFailed("shape")
        }
        return o
    }
    private func str(_ o: [String: MCP.Value], _ k: String) throws -> String {
        guard case .string(let s)? = o[k] else {
            XCTFail("expected string '\(k)' in \(o)")
            throw MCPError.toolFailed("shape")
        }
        return s
    }
    private func int(_ o: [String: MCP.Value], _ k: String) throws -> Int {
        guard case .int(let i)? = o[k] else {
            XCTFail("expected int '\(k)' in \(o)")
            throw MCPError.toolFailed("shape")
        }
        return i
    }

    func test_uat_m2_the_agent_journey_over_the_mcp_surface_only() throws {
        // 1. DISCOVER: the vocabulary teaches the grammar before any doc exists.
        let vocab = try str(try obj(try call("canvas_vocab", [:])), "vocabulary")
        XCTAssertTrue(vocab.contains("ELEMENT LINES"))
        XCTAssertTrue(vocab.contains("frame (container)"))

        // 2. CREATE.
        let doc = try str(try obj(try call("canvas_new", [:])), "doc")

        // 3. AUTHOR — first attempt uses vocabulary NOT in the registry (the
        //    deliberate mistake): the rejection TEACHES, the agent fixes.
        let mistake = try obj(try call("canvas_apply", [
            "doc": .string(doc), "baseRev": .int(0),
            "dsl": .string("card #hero title=\"Q3\""),
        ]))
        XCTAssertEqual(mistake["rejected"], .string("dsl"))
        let lesson = try str(mistake, "detail")
        XCTAssertTrue(lesson.contains("unknown element 'card'"), "\(lesson)")
        XCTAssertTrue(lesson.contains("frame"), "the lesson names the legal set")

        // The corrected build (what the lesson taught).
        let built = try obj(try call("canvas_apply", [
            "doc": .string(doc), "baseRev": .int(0),
            "dsl": .string(
                """
                frame #hero fill=$color.surface padding=$space.lg gap=8 {
                  text #title "Q3 Report" font=$font.h1 color=$color.fg
                  text #sub "Revenue up 12%" color=$color.muted
                }
                """),
        ]))
        XCTAssertEqual(built["rev"], .int(1))
        XCTAssertEqual(built["applied"], .int(3))

        // 4. READ BACK: the projection round-trips what was authored.
        let read1 = try obj(try call("canvas_read", ["doc": .string(doc)]))
        let dsl1 = try str(read1, "dsl")
        XCTAssertTrue(dsl1.contains("frame #hero"))
        XCTAssertTrue(dsl1.contains("\"Q3 Report\""))
        XCTAssertTrue(dsl1.contains("$color.surface"), "tokens stay symbolic")

        // 5. EDIT with a STALE rev → conflict carries currentRev → retry lands.
        let conflict = try obj(try call("canvas_apply", [
            "doc": .string(doc), "baseRev": .int(0),
            "dsl": .string("set #sub \"Revenue up 14%\""),
        ]))
        XCTAssertEqual(conflict["rejected"], .string("conflict"))
        let current = try int(conflict, "currentRev")
        let retried = try obj(try call("canvas_apply", [
            "doc": .string(doc), "baseRev": .int(current),
            "dsl": .string("set #sub \"Revenue up 14%\""),
        ]))
        XCTAssertEqual(try int(retried, "rev"), current + 1)

        // 6. LINT: clean doc, clean report (tokens were used throughout).
        let lint = try obj(try call("canvas_lint", ["doc": .string(doc)]))
        XCTAssertEqual(lint["lint"], .array([]), "token-disciplined doc lints clean")

        // 7. UNDO the edit; the read reflects the restore.
        let undone = try obj(try call("canvas_undo", ["doc": .string(doc)]))
        XCTAssertEqual(undone["undone"], .bool(true))
        let read2 = try str(try obj(try call("canvas_read", ["doc": .string(doc)])), "dsl")
        XCTAssertTrue(read2.contains("Revenue up 12%"), "undo restored the copy")

        // 8. SAVE → REOPEN → the projection is IDENTICAL.
        let target = dir.appendingPathComponent("q3.canvas")
        let saved = try obj(try call("canvas_save", [
            "doc": .string(doc), "path": .string(target.path),
        ]))
        let fileDoc = try str(saved, "doc")
        // Close by dropping the store's handle, then reopen from disk.
        host.automationCanvasStore.close(fileDoc)
        let reopened = try str(try obj(try call("canvas_open", [
            "path": .string(target.path),
        ])), "doc")
        let read3 = try str(try obj(try call("canvas_read", ["doc": .string(reopened)])), "dsl")
        XCTAssertEqual(read3, read2, "reopen projects the identical document")
    }

    func test_uat_m2_latency_budget_1k_node_doc_p95_under_20ms() throws {
        let doc = try str(try obj(try call("canvas_new", [:])), "doc")
        // Build 1000 nodes through the tool surface (10 frames × 100 texts).
        for f in 0..<10 {
            var dsl = "frame #f\(f) gap=4 {\n"
            for t in 0..<100 {
                dsl += "  text #f\(f)t\(t) \"row \(f)-\(t)\"\n"
            }
            dsl += "}\n"
            let applied = try obj(try call("canvas_apply", [
                "doc": .string(doc), "baseRev": .int(f), "dsl": .string(dsl),
            ]))
            XCTAssertEqual(applied["noop"], .bool(false))
        }

        // 50 timed tool round-trips: apply (single-node edit) + read slice.
        var applyMs: [Double] = []
        var readMs: [Double] = []
        for i in 0..<50 {
            let t0 = Date()
            _ = try call("canvas_apply", [
                "doc": .string(doc), "baseRev": .int(10 + i),
                "dsl": .string("set #f\(i % 10)t\(i % 100) \"edited \(i)\""),
            ])
            applyMs.append(Date().timeIntervalSince(t0) * 1000)

            let t1 = Date()
            _ = try call("canvas_read", [
                "doc": .string(doc), "anchor": .string("#f\(i % 10)"),
            ])
            readMs.append(Date().timeIntervalSince(t1) * 1000)
        }
        func pct(_ v: [Double], _ p: Double) -> Double {
            let s = v.sorted()
            return s[min(s.count - 1, Int(Double(s.count) * p))]
        }
        print("CANVAS-M2-LATENCY apply(ms) p50=\(pct(applyMs, 0.5)) p95=\(pct(applyMs, 0.95))")
        print("CANVAS-M2-LATENCY read(ms)  p50=\(pct(readMs, 0.5)) p95=\(pct(readMs, 0.95))")
        XCTAssertLessThan(pct(applyMs, 0.95), 20, "apply round-trip over the M2 budget")
        XCTAssertLessThan(pct(readMs, 0.95), 20, "read round-trip over the M2 budget")
    }
}
