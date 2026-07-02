import XCTest
import ViewerKit

@testable import ViewerCore

/// UAT-M5 (06-MILESTONES-UAT §M5; M5-PLAN §S5) — THE DESIGNER JOURNEY,
/// driven over the real MCP tool surface + the real store/engine: mode-new
/// (both artboards, kit pre-imported) → kit insert (the `use` op the kit
/// strip lands) → inspector edit (the `set` op the inspector lands) → an
/// agent co-edits the same doc → the responsive check flags the mobile
/// artboard but not the desktop (the measured stage, cached by the rendered
/// lens, merged at canvas_lint) → export standalone + fragment → reopen
/// identical. This is the milestone's acceptance artifact; the LIVE-runtime
/// halves (kit-strip pixels, live geometry) are the S2/S4 webview + T5 tests.
@MainActor
final class CanvasUATM5Tests: XCTestCase {

    private var host: FakeAutomationHost!
    private var dir: URL!

    override func setUp() async throws {
        host = FakeAutomationHost()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasUATM5-\(UUID().uuidString)")
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

    func test_uat_m5_the_designer_journey() throws {
        // 1. MODE-NEW: a UI-Design doc with both artboards + the kit.
        let created = try obj(try call("canvas_new", [
            "mode": .string("ui-design"), "template": .string("both"),
        ]))
        guard case .string(let doc)? = created["doc"] else { return XCTFail("doc") }
        let openDoc = try host.automationCanvasStore.doc(doc)
        XCTAssertTrue(CanvasUIDesignMode.isUIDesign(openDoc), "mode seeded")

        func readDSL() throws -> String {
            guard case .string(let dsl)? = try obj(try call("canvas_read", ["doc": .string(doc)]))["dsl"]
            else { XCTFail("read"); throw MCPError.toolFailed("read") }
            return dsl
        }
        var dsl = try readDSL()
        XCTAssertTrue(dsl.contains("#artboard-desktop") && dsl.contains("#artboard-mobile"))

        // 2. KIT INSERT (the op the kit strip lands): a card in the desktop
        //    artboard, via canvas_apply `use`.
        func rev() throws -> Int { Int(try openDoc.adapter.currentRev()) }
        _ = try obj(try call("canvas_apply", [
            "doc": .string(doc), "baseRev": .int(try rev()),
            "dsl": .string("use #kit-card #hero override text #kit-card-title \"Welcome\""),
        ]))
        // Reparent it under the desktop artboard (the strip inserts at the
        // selection; here we place it explicitly via a move op).
        _ = try openDoc.adapter.apply(baseRev: try openDoc.adapter.currentRev(), [
            .move(id: "nd:hero", parent: "nd:artboard-desktop", pos: .last),
        ])
        dsl = try readDSL()
        XCTAssertTrue(dsl.contains("Welcome"), "kit card inserted + overridden: \(dsl.prefix(400))")

        // 3. INSPECTOR EDIT (the op the inspector lands): set a prop.
        _ = try openDoc.adapter.apply(baseRev: try openDoc.adapter.currentRev(), [
            .update(id: "nd:artboard-desktop", set: [("gap", .num(24))], unset: []),
        ])

        // 4. AGENT CO-EDIT: an independent apply into the SAME doc lands.
        let coedit = try obj(try call("canvas_apply", [
            "doc": .string(doc), "baseRev": .int(try rev()),
            "dsl": .string("text #note parent-less \"agent note\""),
        ]))
        // (The `parent-less` token is unknown → this teaches; retry clean.)
        if coedit["rejected"] != nil {
            _ = try obj(try call("canvas_apply", [
                "doc": .string(doc), "baseRev": .int(try rev()),
                "dsl": .string("text #note \"agent note\""),
            ]))
        }
        XCTAssertTrue(try readDSL().contains("agent note"), "agent co-edit landed")

        // 5. RESPONSIVE CHECK: the rendered lens caches the measured stage
        //    (proven live in the S2/S5 webview tests); here we assert
        //    canvas_lint MERGES it with the mobile artboard flagged, desktop
        //    clean — the responsive verdict the agent reads.
        openDoc.cacheMeasuredLint([
            CanvasDocLint(severity: "warn", code: "overflow", id: "nd:artboard-mobile",
                          message: "content overflows its box"),
        ])
        let lint = try obj(try call("canvas_lint", ["doc": .string(doc)]))
        XCTAssertEqual(lint["measured"], .bool(true), "measured stage present")
        guard case .array(let findings)? = lint["lint"] else { return XCTFail("lint") }
        func flags(_ id: String) -> Bool {
            findings.contains { v in
                guard case .object(let f) = v else { return false }
                return f["code"] == .string("overflow") && f["id"] == .string(id)
            }
        }
        XCTAssertTrue(flags("nd:artboard-mobile"), "mobile flagged (responsive)")
        XCTAssertFalse(flags("nd:artboard-desktop"), "desktop clean")

        // 6. EXPORT both flavors.
        let standalone = dir.appendingPathComponent("out.html")
        let fragment = dir.appendingPathComponent("frag.html")
        let s = try obj(try call("canvas_export", [
            "doc": .string(doc), "path": .string(standalone.path),
        ]))
        XCTAssertEqual(s["flavor"], .string("standalone"))
        let f = try obj(try call("canvas_export", [
            "doc": .string(doc), "path": .string(fragment.path),
            "flavor": .string("fragment"), "artboard": .string("#artboard-desktop"),
        ]))
        XCTAssertEqual(f["flavor"], .string("fragment"))
        let sHTML = try String(contentsOf: standalone, encoding: .utf8)
        let fHTML = try String(contentsOf: fragment, encoding: .utf8)
        XCTAssertTrue(sHTML.contains("cv-theme") && sHTML.contains("Welcome"))
        XCTAssertFalse(fHTML.contains("cv-theme"), "fragment drops the theme")
        XCTAssertFalse(fHTML.contains("var(--cv-"), "fragment inlines literals")
        XCTAssertTrue(fHTML.contains("Welcome"), "fragment scoped to the desktop artboard")

        // 7. SAVE → REOPEN → IDENTICAL (mode + content survive).
        let target = dir.appendingPathComponent("journey.canvas")
        _ = try call("canvas_save", ["doc": .string(doc), "path": .string(target.path)])
        let before = try openDoc.adapter.save()
        host.automationCanvasStore.close(CanvasDocumentStore.docID(for: target))
        let reopened = try host.automationCanvasStore.open(url: target)
        XCTAssertTrue(CanvasUIDesignMode.isUIDesign(reopened), "mode survives")
        XCTAssertEqual(try reopened.adapter.save(), before, "byte-identical reopen")
    }
}
