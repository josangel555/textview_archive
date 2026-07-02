import XCTest
import ViewerCore

@testable import ViewerUI

/// Canvas M2.S6 (TSK-1371): the script-verb bus reaches the canvas engine —
/// `canvas-apply-file` mutates a doc referenced BY PATH (auto-opened) and
/// `canvas-export` writes the standalone HTML, both as one-line `--script`
/// verbs through the REAL dispatch (`ScriptVerb.apply`). Host-safe
/// (HeadlessHarness — no window, no app spawn).
@MainActor
final class CanvasVerbTests: XCTestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        harness = HeadlessHarness(label: "CanvasVerbTests")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
    }

    func test_canvasVerbs_applyFile_and_export_through_the_bus() throws {
        let model = harness.model
        // Seed a .canvas file through the store; close it so the verb's
        // by-path auto-open is what's exercised.
        let store = model.automationCanvasStore
        let doc = try store.create()
        _ = try doc.adapter.applyDSL(baseRev: 0, "text #t \"v1\"")
        let file = try harness.writeFile("verb.canvas", "")
        _ = try store.save(doc.id, to: file)
        store.close(CanvasDocumentStore.docID(for: file))

        // The verbs are catalogued (run_verb's gate) — pin that first.
        XCTAssertTrue(ScriptVerbCatalog.tokens.contains("canvas-export"))
        XCTAssertTrue(ScriptVerbCatalog.tokens.contains("canvas-apply-file"))

        // canvas-apply-file: DSL from a file, doc by path.
        let dsl = try harness.writeFile("edit.dsl", "set #t \"v2-via-verb\"")
        let handled = ScriptVerb.apply(
            verb: "canvas-apply-file \(file.path) 1 \(dsl.path)",
            to: model, sessions: harness.sessions)
        XCTAssertTrue(handled, "the bus recognises the canvas verb")
        let reopened = try store.doc(CanvasDocumentStore.docID(for: file))
        XCTAssertTrue(try reopened.adapter.html().contains(">v2-via-verb<"),
                      "the verb's edit reached the engine")

        // canvas-export: standalone HTML lands on disk.
        let out = try harness.writeFile("verb-out.html", "")
        let exported = ScriptVerb.apply(
            verb: "canvas-export \(file.path) \(out.path)",
            to: model, sessions: harness.sessions)
        XCTAssertTrue(exported)
        let html = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(html.contains(">v2-via-verb<"))
        XCTAssertTrue(html.contains("--cv-color-accent"), "theme block present")
    }
}
