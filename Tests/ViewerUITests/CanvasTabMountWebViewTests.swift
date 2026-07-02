import WebKit
import XCTest
import ViewerCore

@testable import ViewerUI

/// Canvas M3.S1b (TSK-1372): the tab↔engine binding on the REAL runtime —
/// `CanvasTabController` end-to-end: store-open → host mount → ready →
/// setContent → contentSet, with the engine's real lowering in the real DOM.
/// `#192`-gated (VM webview lane; self-skips in the host gate).
@MainActor
final class CanvasTabMountWebViewTests: WebViewTestCase {

    private var dir: URL!

    override func setUp() async throws {
        try WebViewTestTeardown.skipUnlessEnabled()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CanvasTabMount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
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

    func test_controller_mounts_the_real_runtime_and_selection_round_trips() async throws {
        // A real .canvas file through the engine.
        let store = CanvasDocumentStore()
        let doc = try store.create()
        _ = try doc.adapter.applyDSL(
            baseRev: 0,
            """
            frame #hero gap=8 {
              text #title "mounted for real"
            }
            """)
        let file = dir.appendingPathComponent("mount.canvas")
        _ = try store.save(doc.id, to: file)
        store.close(CanvasDocumentStore.docID(for: file))

        // The controller does EVERYTHING (open, load, ready→setContent).
        let controller = CanvasTabController(
            tabID: UUID(), fileURL: file, store: store)
        defer { controller.teardown() }

        let mounted = await waitUntil(15) {
            if case .mounted = controller.phase { return true }
            return false
        }
        if !mounted, controller.host.contentProcessDied {
            throw XCTSkip("WebContent died (TSK-1365 environment) — not an S1 logic fault")
        }
        XCTAssertTrue(mounted, "controller must reach .mounted; phase=\(controller.phase)")
        guard case .mounted(let nodeCount) = controller.phase else { return }
        XCTAssertEqual(nodeCount, 3, "page + frame + text in the real DOM")

        // Selection round trip on the real runtime: drive the overlay
        // command; the runtime replies to geometry for the selected node
        // (the S3 overlay's data source).
        controller.host.send(.setSelection(ids: ["nd:title"]))
        var geometryArrived = false
        controller.host.onInbound = { message in
            if case .geometry = message { geometryArrived = true }
        }
        controller.host.send(.queryGeometry(replyId: 99, ids: ["nd:title"]))
        let ok = await waitUntil(5) { geometryArrived }
        XCTAssertTrue(ok, "the mounted runtime answers geometry for the lowered node")
    }
}
