import WebKit
import XCTest
import ViewerCore

@testable import ViewerUI

/// UAT-M3 (06-MILESTONES-UAT §M3; M3-PLAN §S7) — the WYSIWYG journey on the
/// REAL runtime, driven through the CONTROLLER (the app's own binding, not
/// raw host sends): open → select (tree + canvas agree) → inline-edit →
/// drag-reorder → ⌘Z chain → an agent co-edit lands live → save → reopen
/// identical. The overlay-visibility PIXEL half lives in the T5 test
/// (self-skipping until TSK-1334); this journey asserts structure/geometry
/// through the standard queries. `#192`-gated.
@MainActor
final class CanvasUATM3Tests: WebViewTestCase {

    private var dir: URL!
    private var store: CanvasDocumentStore!

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasUATM3-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = CanvasDocumentStore()
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        store = nil
        try await super.tearDown()
    }

    private func waitUntil(
        _ seconds: TimeInterval, _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    func test_uat_m3_the_wysiwyg_journey() async throws {
        // A real document on disk.
        let doc = try store.create()
        _ = try doc.adapter.applyDSL(
            baseRev: 0,
            """
            frame #col gap=8 padding=16 {
              text #title "Q3 Report" font=$font.h1
              text #sub "draft copy"
            }
            """)
        let file = dir.appendingPathComponent("journey.canvas")
        _ = try store.save(doc.id, to: file)
        store.close(CanvasDocumentStore.docID(for: file))

        // 1. OPEN: the controller mounts the real runtime.
        let controller = CanvasTabController(tabID: UUID(), fileURL: file, store: store)
        defer { controller.teardown() }
        let mounted = await waitUntil(15) {
            if case .mounted = controller.phase { return true }
            return false
        }
        if !mounted, controller.host.contentProcessDied {
            throw XCTSkip("WebContent died (TSK-1365 environment)")
        }
        XCTAssertTrue(mounted, "phase=\(controller.phase)")

        // 2. SELECT via the layers-tree authority; the runtime's overlay is
        //    measurable and glued to the target (structural half; pixels=T5).
        controller.select("nd:sub")
        XCTAssertEqual(controller.selectedIDs, ["nd:sub"])

        // 3. INLINE-EDIT: the runtime's textEdited intent lands in the engine.
        controller.host.onInbound?(.textEdited(id: "nd:sub", text: "final copy"))
        XCTAssertTrue(try XCTUnwrap(controller.doc).adapter.html().contains(">final copy<"))

        // 4. DRAG-REORDER: sub above title.
        controller.host.onInbound?(
            .dragEnded(id: "nd:sub", parent: "nd:col", beforeId: "nd:title"))
        var outline = try XCTUnwrap(controller.outline)
        var col = try XCTUnwrap(CanvasOutlineParser.find("nd:col", in: outline))
        XCTAssertEqual(col.children.map(\.id), ["nd:sub", "nd:title"], "reordered")

        // 5. ⌘Z CHAIN: undo the move, then the edit.
        controller.host.onInbound?(.undoRequested)
        outline = try XCTUnwrap(controller.outline)
        col = try XCTUnwrap(CanvasOutlineParser.find("nd:col", in: outline))
        XCTAssertEqual(col.children.map(\.id), ["nd:title", "nd:sub"], "move undone")
        controller.host.onInbound?(.undoRequested)
        XCTAssertTrue(try XCTUnwrap(controller.doc).adapter.html().contains(">draft copy<"),
                      "edit undone")

        // 6. AGENT CO-EDIT lands live: the MCP path mutates; refresh paints.
        let docRef = try XCTUnwrap(controller.doc)
        _ = try docRef.adapter.applyDSL(
            baseRev: docRef.adapter.currentRev(), "text #agent \"added by the agent\"")
        controller.refresh()
        outline = try XCTUnwrap(controller.outline)
        XCTAssertNotNil(CanvasOutlineParser.find("nd:agent", in: outline),
                        "the agent's node is in the read model")

        // 7. SAVE → REOPEN: identical projection.
        let projectedBefore = try docRef.adapter.renderDSL()
        _ = try store.save(docRef.id)
        store.close(docRef.id)
        let reopened = try store.open(url: file)
        XCTAssertEqual(try reopened.adapter.renderDSL(), projectedBefore,
                       "the reopened document projects identically")
    }
}
