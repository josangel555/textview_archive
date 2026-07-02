import XCTest
import ViewerCore
import ViewerKit

@testable import ViewerUI

/// Canvas M3.S1 (TSK-1372): the tab↔engine binding — controller state
/// machine (driven by injected bridge messages, no WebKit navigation),
/// mode routing, and teardown-on-close. Host-safe; the REAL runtime's
/// behavior is the VM webview suite's half of this slice.
@MainActor
final class CanvasTabControllerTests: XCTestCase {

    private var harness: HeadlessHarness!
    private var file: URL!

    override func setUp() async throws {
        harness = HeadlessHarness(label: "CanvasTabControllerTests")
        // A real .canvas file via the engine.
        let store = harness.model.automationCanvasStore
        let doc = try store.create()
        _ = try doc.adapter.applyDSL(baseRev: 0, "text #t \"mounted\"")
        file = try harness.writeFile("view.canvas", "")
        _ = try store.save(doc.id, to: file)
        store.close(CanvasDocumentStore.docID(for: file))
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
    }

    func test_canvas_offers_rendered_lens_source_default() {
        let modes = ViewModeOptions.availableModes(for: file, forcedCategory: nil)
        XCTAssertTrue(modes.contains(.rendered), "M3.S1: the WYSIWYG lens exists")
        XCTAssertEqual(modes.first, .source, "source stays default until S7")
        XCTAssertEqual(
            ViewModeOptions.defaultMode(for: file, isRenderableText: true), .source)
    }

    func test_controller_mounts_selects_and_clears_via_bridge_messages() throws {
        let model = harness.model
        let controller = model.canvasController(forTab: UUID(), fileURL: file)
        XCTAssertEqual(controller.phase, .mounting)

        // Drive the bridge inbound path directly (the JS runtime's messages).
        controller.host.onInbound?(.ready(tsMs: 1))
        // ready → refresh() sent setContent; the runtime acks:
        controller.host.onInbound?(.contentSet(seq: 1, nodeCount: 2, tsMs: 2))
        XCTAssertEqual(controller.phase, .mounted(nodeCount: 2))

        controller.host.onInbound?(.nodeClicked(id: "nd:t", shift: false))
        XCTAssertEqual(controller.selectedIDs, ["nd:t"])
        controller.host.onInbound?(.escapePressed)
        XCTAssertEqual(controller.selectedIDs, [])

        // A protocol mismatch fails LOUDLY, not silently.
        controller.host.onInbound?(.unsupportedVersion(v: 99))
        guard case .failed(let why) = controller.phase else {
            return XCTFail("expected failed phase")
        }
        XCTAssertTrue(why.contains("v99"))
    }

    func test_controller_shares_the_store_doc_with_agent_tools() throws {
        let model = harness.model
        let controller = model.canvasController(forTab: UUID(), fileURL: file)
        // The controller's doc IS the store's doc (one revision stream).
        let store = model.automationCanvasStore
        let storeDoc = try store.doc(CanvasDocumentStore.docID(for: file))
        XCTAssertTrue(controller.doc === storeDoc)
        // An agent-path edit is visible through the controller's doc.
        _ = try storeDoc.adapter.applyDSL(baseRev: 1, "set #t \"agent-edited\"")
        XCTAssertTrue(try controller.doc?.adapter.html().contains(">agent-edited<") == true)
    }

    func test_close_drops_the_controller_but_not_the_store_doc() throws {
        let model = harness.model
        model.open(url: file)
        let tabID = try XCTUnwrap(model.tabs.selected?.id)
        _ = model.canvasController(forTab: tabID, fileURL: file)
        XCTAssertNotNil(model.canvasControllers[tabID])

        model.closeTab(at: 0)
        XCTAssertNil(model.canvasControllers[tabID], "controller dies with the tab")
        // The STORE doc survives (agents may hold it).
        XCTAssertNoThrow(
            try model.automationCanvasStore.doc(CanvasDocumentStore.docID(for: file)))
    }
}
