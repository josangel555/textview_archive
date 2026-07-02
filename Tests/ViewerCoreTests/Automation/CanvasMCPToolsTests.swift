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

    // MARK: M2.S6 — canvas_export (TSK-1371)

    func test_export_writes_selfContained_html() throws {
        guard case .object(let n) = try call("canvas_new", [:]),
              case .string(let doc)? = n["doc"] else { return XCTFail("new") }
        _ = try call("canvas_apply", [
            "doc": .string(doc), "baseRev": .int(0),
            "dsl": .string("frame #hero fill=$color.surface {\n  text #t \"exported\"\n}"),
        ])
        let out = dir.appendingPathComponent("page.html")
        guard case .object(let e) = try call("canvas_export", [
            "doc": .string(doc), "path": .string(out.path),
        ]) else { return XCTFail("export shape") }
        XCTAssertEqual(e["path"], .string(out.path))
        let html = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(html.contains("--cv-color-surface"), "theme block embedded")
        XCTAssertTrue(html.contains(">exported<"), "content lowered")
        XCTAssertTrue(html.contains("var(--cv-color-surface)"), "tokens symbolic")
        guard case .int(let bytes)? = e["bytes"] else { return XCTFail("bytes") }
        XCTAssertEqual(bytes, html.utf8.count)
    }

    // MARK: M4.S5 — the starter kit (TSK-1384)

    func test_kit_import_use_and_drift_blocks_overwrite() throws {
        guard case .object(let n) = try call("canvas_new", [:]),
              case .string(let doc)? = n["doc"] else { return XCTFail("new") }

        // Import: definitions land + the pin records.
        guard case .object(let first) = try call("canvas_kit_import", ["doc": .string(doc)]) else {
            return XCTFail("import shape")
        }
        XCTAssertEqual(first["imported"], .bool(true))
        XCTAssertEqual(first["driftDetected"], .bool(false))

        // The kit is usable: instantiate a card and read it back.
        let openDoc = try host.automationCanvasStore.doc(doc)
        let rev = try openDoc.adapter.currentRev()
        guard case .object(let applied) = try call("canvas_apply", [
            "doc": .string(doc), "baseRev": .int(Int(rev)),
            "dsl": .string("use #kit-card #my-card override text #kit-card-title \"Kitted\""),
        ]) else { return XCTFail("apply shape") }
        XCTAssertNotNil(applied["rev"], "kit instance applies: \(applied)")
        XCTAssertTrue(try openDoc.adapter.html().contains(">Kitted<"),
                      "the kit card expands with the override")

        // Clean re-import: idempotent, no drift.
        guard case .object(let second) = try call("canvas_kit_import", ["doc": .string(doc)]) else {
            return XCTFail("re-import shape")
        }
        XCTAssertEqual(second["imported"], .bool(true))
        XCTAssertEqual(second["driftDetected"], .bool(false))

        // EDIT a kit component (vendored copy diverges), then re-import:
        // drift is DETECTED and nothing is overwritten.
        let rev2 = try openDoc.adapter.currentRev()
        _ = try openDoc.adapter.applyDSL(
            baseRev: rev2, "set #kit-card-title \"Locally edited\"")
        guard case .object(let third) = try call("canvas_kit_import", ["doc": .string(doc)]) else {
            return XCTFail("drift shape")
        }
        XCTAssertEqual(third["imported"], .bool(false), "drift must block")
        XCTAssertEqual(third["driftDetected"], .bool(true))
        XCTAssertTrue(try openDoc.adapter.html().contains(">Locally edited<") ||
                      (try openDoc.adapter.renderDSL().contains("Locally edited")),
                      "the local edit survives — never silently overwritten")
    }

    // MARK: M4.S9 — the measured-lint merge (TSK-1388)

    func test_canvas_lint_merges_the_measured_stage_with_a_marker() throws {
        guard case .object(let n) = try call("canvas_new", [:]),
              case .string(let doc)? = n["doc"] else { return XCTFail("new") }
        _ = try call("canvas_apply", [
            "doc": .string(doc), "baseRev": .int(0),
            "dsl": .string("hole #todo note=\"pending\""),
        ])
        // UNMOUNTED: static only, measured=false.
        guard case .object(let l1) = try call("canvas_lint", ["doc": .string(doc)]),
              case .array(let static1)? = l1["lint"] else { return XCTFail("lint1") }
        XCTAssertEqual(l1["measured"], .bool(false), "unmounted docs say so")
        XCTAssertTrue(static1.contains { v in
            if case .object(let f) = v, case .string(let code)? = f["code"] { return code == "hole" }
            return false
        })
        // The rendered lens's controller caches measured findings (simulated
        // here — the live push is the webview test's half).
        let openDoc = try host.automationCanvasStore.doc(doc)
        openDoc.cacheMeasuredLint([
            CanvasDocLint(severity: "warn", code: "overflow", id: "nd:todo",
                          message: "content overflows its box")
        ])
        guard case .object(let l2) = try call("canvas_lint", ["doc": .string(doc)]),
              case .array(let merged)? = l2["lint"] else { return XCTFail("lint2") }
        XCTAssertEqual(l2["measured"], .bool(true))
        XCTAssertTrue(merged.count > static1.count, "measured findings merged in")
        XCTAssertTrue(merged.contains { v in
            if case .object(let f) = v, case .string(let code)? = f["code"] {
                return code == "overflow"
            }
            return false
        }, "the geometry stage rides the same tool: \(merged)")
    }

    // MARK: M5.S1 — the UI-Design mode template (TSK-1389)

    func test_mode_new_seeds_kit_artboards_and_token_and_survives_io() throws {
        guard case .object(let n) = try call("canvas_new", [
            "mode": .string("ui-design"), "template": .string("both"),
        ]), case .string(let doc)? = n["doc"] else { return XCTFail("new") }

        let openDoc = try host.automationCanvasStore.doc(doc)
        XCTAssertTrue(CanvasUIDesignMode.isUIDesign(openDoc), "the mode token seeds")
        // Both artboards + the kit landed (read through the projection).
        guard case .object(let read) = try call("canvas_read", ["doc": .string(doc)]),
              case .string(let dsl)? = read["dsl"] else { return XCTFail("read") }
        XCTAssertTrue(dsl.contains("#artboard-desktop"), "\(dsl.prefix(400))")
        XCTAssertTrue(dsl.contains("#artboard-mobile"))
        XCTAssertTrue(dsl.contains("role=\"artboard\""), "canonical projection quotes strings")
        XCTAssertTrue(dsl.contains("component #kit-card"), "kit imported")
        // The artboards carry the viewport presets.
        XCTAssertTrue(dsl.contains("minW=1280") && dsl.contains("minW=390"))

        // The mode survives save/load (tokens ride io).
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("mode-\(UUID().uuidString).canvas")
        defer { try? FileManager.default.removeItem(at: target) }
        _ = try call("canvas_save", ["doc": .string(doc), "path": .string(target.path)])
        host.automationCanvasStore.close(CanvasDocumentStore.docID(for: target))
        let reopened = try host.automationCanvasStore.open(url: target)
        XCTAssertTrue(CanvasUIDesignMode.isUIDesign(reopened), "mode rides io")
    }

    func test_plain_new_is_untouched_by_the_mode_machinery() throws {
        guard case .object(let n) = try call("canvas_new", [:]),
              case .string(let doc)? = n["doc"] else { return XCTFail("new") }
        let openDoc = try host.automationCanvasStore.doc(doc)
        XCTAssertFalse(CanvasUIDesignMode.isUIDesign(openDoc))
        XCTAssertEqual(n["rev"], .int(0), "plain new stays empty at rev 0")
        guard case .object(let read) = try call("canvas_read", ["doc": .string(doc)]),
              case .string(let dsl)? = read["dsl"] else { return XCTFail("read") }
        XCTAssertFalse(dsl.contains("artboard"))
    }

    // MARK: M5.S3 — export flavors (TSK-1391)

    func test_export_standalone_vs_fragment() throws {
        guard case .object(let n) = try call("canvas_new", [
            "mode": .string("ui-design"), "template": .string("desktop"),
        ]), case .string(let doc)? = n["doc"] else { return XCTFail("new") }
        // Put a token-colored node inside the desktop artboard.
        let openDoc = try host.automationCanvasStore.doc(doc)
        _ = try openDoc.adapter.apply(baseRev: try openDoc.adapter.currentRev(), [
            .insert(id: "nd:hi", kind: "text", parent: "nd:artboard-desktop", pos: .last,
                    props: [("text", .str("hello")), ("color", .token("color.accent"))]),
        ])

        let tmp = FileManager.default.temporaryDirectory
        let standalone = tmp.appendingPathComponent("s-\(UUID().uuidString).html")
        let fragment = tmp.appendingPathComponent("f-\(UUID().uuidString).html")
        defer { try? FileManager.default.removeItem(at: standalone)
                try? FileManager.default.removeItem(at: fragment) }

        // Standalone: theme block + var() refs present.
        guard case .object(let s) = try call("canvas_export", [
            "doc": .string(doc), "path": .string(standalone.path),
        ]) else { return XCTFail("standalone") }
        XCTAssertEqual(s["flavor"], .string("standalone"))
        let sHTML = try String(contentsOf: standalone, encoding: .utf8)
        XCTAssertTrue(sHTML.contains("cv-theme"), "standalone carries the theme")
        XCTAssertTrue(sHTML.contains("var(--cv-"), "standalone keeps var refs")

        // Fragment (first artboard auto-picked): NO theme, NO var(), scoped.
        guard case .object(let f) = try call("canvas_export", [
            "doc": .string(doc), "path": .string(fragment.path),
            "flavor": .string("fragment"),
        ]) else { return XCTFail("fragment") }
        XCTAssertEqual(f["flavor"], .string("fragment"))
        let fHTML = try String(contentsOf: fragment, encoding: .utf8)
        XCTAssertFalse(fHTML.contains("cv-theme"), "fragment drops the theme block")
        XCTAssertFalse(fHTML.contains("var(--cv-"), "fragment inlines literals: \(fHTML.prefix(300))")
        XCTAssertTrue(fHTML.contains(">hello<"), "scoped to the artboard subtree")
        XCTAssertTrue(fHTML.contains("data-cv-id=\"nd:artboard-desktop\""))

        // Explicit artboard arg + bad flavor.
        guard case .object(let f2) = try call("canvas_export", [
            "doc": .string(doc), "path": .string(fragment.path),
            "flavor": .string("fragment"), "artboard": .string("#artboard-desktop"),
        ]) else { return XCTFail("explicit") }
        XCTAssertEqual(f2["flavor"], .string("fragment"))
        XCTAssertThrowsError(try call("canvas_export", [
            "doc": .string(doc), "path": .string(fragment.path),
            "flavor": .string("react"),
        ]), "unknown flavor rejects")
    }

    // MARK: M6.S1 — the presentation mode template (TSK-1395)

    func test_presentation_mode_seeds_slides_token_and_survives_io() throws {
        guard case .object(let n) = try call("canvas_new", [
            "mode": .string("presentation"), "slides": .int(4),
        ]), case .string(let doc)? = n["doc"] else { return XCTFail("new") }

        let openDoc = try host.automationCanvasStore.doc(doc)
        XCTAssertTrue(CanvasPresentationMode.isPresentation(openDoc), "deck token seeds")
        guard case .object(let read) = try call("canvas_read", ["doc": .string(doc)]),
              case .string(let dsl)? = read["dsl"] else { return XCTFail("read") }
        XCTAssertTrue(dsl.contains("#slide-0") && dsl.contains("#slide-3"), "4 slides")
        XCTAssertFalse(dsl.contains("#slide-4"), "exactly 4")
        XCTAssertTrue(dsl.contains("role=\"slide\""), "slides carry role")
        XCTAssertTrue(dsl.contains("minH=720"), "16:9 preset")
        XCTAssertTrue(dsl.contains("component #kit-card"), "kit imported")

        // Deck survives save/load.
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-\(UUID().uuidString).canvas")
        defer { try? FileManager.default.removeItem(at: target) }
        _ = try call("canvas_save", ["doc": .string(doc), "path": .string(target.path)])
        host.automationCanvasStore.close(CanvasDocumentStore.docID(for: target))
        let reopened = try host.automationCanvasStore.open(url: target)
        XCTAssertTrue(CanvasPresentationMode.isPresentation(reopened), "deck rides io")

        // Plain new: not a deck.
        guard case .object(let p) = try call("canvas_new", [:]),
              case .string(let plain)? = p["doc"] else { return XCTFail("plain") }
        XCTAssertFalse(CanvasPresentationMode.isPresentation(
            try host.automationCanvasStore.doc(plain)))
    }

    // MARK: M6.S3 — the timeline tool (TSK-1397)

    func test_canvas_timeline_reports_per_slide_step_snapshots() throws {
        guard case .object(let n) = try call("canvas_new", [
            "mode": .string("presentation"), "slides": .int(2),
        ]), case .string(let doc)? = n["doc"] else { return XCTFail("new") }
        let openDoc = try host.automationCanvasStore.doc(doc)
        // Add stepped reveals into slide-0.
        _ = try openDoc.adapter.apply(baseRev: try openDoc.adapter.currentRev(), [
            .insert(id: "nd:base", kind: "text", parent: "nd:slide-0", pos: .last,
                    props: [("text", .str("base"))]),
            .insert(id: "nd:r1", kind: "text", parent: "nd:slide-0", pos: .last,
                    props: [("text", .str("one")), ("step", .num(1))]),
            .insert(id: "nd:r2", kind: "text", parent: "nd:slide-0", pos: .last,
                    props: [("text", .str("two")), ("step", .num(2))]),
        ])

        guard case .object(let tl) = try call("canvas_timeline", ["doc": .string(doc)]),
              case .array(let slides)? = tl["slides"] else { return XCTFail("timeline") }
        XCTAssertEqual(slides.count, 2, "two slides")
        // slide-0 has stepCount 2 and monotone reveals.
        guard case .object(let s0) = slides[0] else { return XCTFail("s0") }
        XCTAssertEqual(s0["id"], .string("nd:slide-0"))
        XCTAssertEqual(s0["stepCount"], .int(2))
        guard case .array(let steps)? = s0["steps"] else { return XCTFail("steps") }
        XCTAssertEqual(steps.count, 3, "steps 0,1,2")
        func visible(_ v: MCP.Value) -> Set<String> {
            guard case .object(let o) = v, case .array(let ids)? = o["visibleIds"] else { return [] }
            return Set(ids.compactMap { if case .string(let s) = $0 { return s }; return nil })
        }
        let at0 = visible(steps[0]), at1 = visible(steps[1]), at2 = visible(steps[2])
        XCTAssertTrue(at0.contains("nd:base") && !at0.contains("nd:r1"), "base only at 0")
        XCTAssertTrue(at1.contains("nd:r1") && !at1.contains("nd:r2"))
        XCTAssertTrue(at2.isSuperset(of: at1) && at2.contains("nd:r2"))
        // slide-1 has no steps → stepCount 0.
        guard case .object(let s1) = slides[1] else { return XCTFail("s1") }
        XCTAssertEqual(s1["stepCount"], .int(0))
    }
}
