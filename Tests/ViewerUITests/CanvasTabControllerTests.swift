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

    // MARK: M3.S4 — intents → ops (TSK-1375)

    /// Human gestures land in the ENGINE through the bridge intents — text
    /// edit, drag-move, delete — and the projection reflects each.
    func test_gesture_intents_mutate_the_engine() throws {
        let model = harness.model
        let controller = model.canvasController(forTab: UUID(), fileURL: file)
        let doc = try XCTUnwrap(controller.doc)
        // Seed a second node so moves/deletes have structure.
        _ = try doc.adapter.applyDSL(baseRev: 1, "frame #row direction=row {\n}")
        controller.host.onInbound?(.contentSet(seq: 1, nodeCount: 3, tsMs: 0))
        // (trackedRev is stale=1 now: the seed bumped to 2 out-of-band —
        // exactly the agent-co-edit case; the conflict path must absorb it.)

        // Text edit via intent.
        controller.host.onInbound?(.textEdited(id: "nd:t", text: "typed by hand"))
        XCTAssertTrue(try doc.adapter.html().contains(">typed by hand<"),
                      "textEdited must land in the engine (through conflict-retry)")

        // Drag-move via intent: nd:t into #row.
        controller.host.onInbound?(.dragEnded(id: "nd:t", parent: "nd:row", beforeId: nil))
        let projected = try doc.adapter.renderDSL(node: "nd:row")
        XCTAssertTrue(projected?.contains("#t") == true, "moved under #row: \(projected ?? "nil")")

        // Delete via intent (selection first).
        controller.host.onInbound?(.nodeClicked(id: "nd:t", shift: false))
        controller.host.onInbound?(.deletePressed)
        XCTAssertFalse(try doc.adapter.html().contains(">typed by hand<"),
                       "deletePressed removes the selection")
        XCTAssertEqual(controller.selectedIDs, [], "selection cleared after delete")
    }

    /// ⌘Z (undoRequested) walks the engine's undo stack.
    func test_undoRequested_restores_prior_state() throws {
        let model = harness.model
        let controller = model.canvasController(forTab: UUID(), fileURL: file)
        let doc = try XCTUnwrap(controller.doc)
        controller.host.onInbound?(.textEdited(id: "nd:t", text: "v2"))
        XCTAssertTrue(try doc.adapter.html().contains(">v2<"))
        controller.host.onInbound?(.undoRequested)
        XCTAssertTrue(try doc.adapter.html().contains(">mounted<"),
                      "undo restored the pre-edit text")
    }

    /// The conflict path: an agent edit bumps the rev out-of-band; the very
    /// next gesture must adopt currentRev and land (the one-retry loop).
    func test_agent_coedit_conflict_is_absorbed_in_one_retry() throws {
        let model = harness.model
        let controller = model.canvasController(forTab: UUID(), fileURL: file)
        let doc = try XCTUnwrap(controller.doc)
        XCTAssertEqual(controller.trackedRev, 1)
        // Agent co-edits (rev 1 → 2) behind the controller's back.
        _ = try doc.adapter.applyDSL(baseRev: 1, "text #agent \"from the agent\"")
        // Human gesture with the stale trackedRev.
        controller.host.onInbound?(.textEdited(id: "nd:t", text: "human wins"))
        XCTAssertTrue(try doc.adapter.html().contains(">human wins<"))
        XCTAssertTrue(try doc.adapter.html().contains(">from the agent<"),
                      "both edits survive — no clobber")
        XCTAssertEqual(controller.trackedRev, 3, "controller adopted the stream")
    }

    // MARK: M3.S8 — inspector + layers (TSK-1379)

    /// The outline snapshot mirrors the engine (structure, order, values) and
    /// refreshes on every mutation.
    func test_outline_tracks_the_engine_through_edits() throws {
        let model = harness.model
        let controller = model.canvasController(forTab: UUID(), fileURL: file)
        let doc = try XCTUnwrap(controller.doc)

        var root = try XCTUnwrap(controller.outline)
        XCTAssertEqual(root.kind, "page")
        XCTAssertEqual(root.children.map(\.id), ["nd:t"], "the seeded text node")

        // A gesture edit refreshes the outline.
        controller.host.onInbound?(.textEdited(id: "nd:t", text: "outlined"))
        root = try XCTUnwrap(controller.outline)
        let node = try XCTUnwrap(CanvasOutlineParser.find("nd:t", in: root))
        XCTAssertTrue(node.props.contains { $0.name == "text" && $0.value == .str("outlined") })

        // Ordering follows the engine's sibling order (FracIndex-sorted).
        _ = try doc.adapter.applyDSL(baseRev: controller.trackedRev, "text #z \"last\"")
        controller.refresh() // out-of-band (agent) edit → refresh re-reads
        root = try XCTUnwrap(controller.outline)
        XCTAssertEqual(root.children.map(\.id), ["nd:t", "nd:z"])
    }

    /// The registry-driven prop specs come from the live vocabulary.
    func test_propSpecs_derive_from_the_vocabulary() throws {
        let model = harness.model
        let controller = model.canvasController(forTab: UUID(), fileURL: file)
        let textSpecs = try XCTUnwrap(controller.propSpecs["text"])
        XCTAssertTrue(textSpecs.contains { $0.name == "text" })
        XCTAssertTrue(textSpecs.contains { $0.name == "color" })
        XCTAssertFalse(textSpecs.contains { $0.name == "src" }, "src is image-only")
        let opacity = controller.propSpecs["shape"]?.first { $0.name == "opacity" }
        XCTAssertEqual(opacity?.note, "0..1", "fence semantics ride the specs")
    }

    /// Tree-click selection = the same authority as canvas clicks; inspector
    /// commits lower through the op path (set + unset + value parsing).
    func test_select_and_inspector_edits_reach_the_engine() throws {
        let model = harness.model
        let controller = model.canvasController(forTab: UUID(), fileURL: file)
        let doc = try XCTUnwrap(controller.doc)

        controller.select("nd:t")
        XCTAssertEqual(controller.selectedIDs, ["nd:t"])

        // Inspector: set a token, a number, and a string; then unset.
        controller.setProp("nd:t", name: "color", value: CanvasInspectorView.parse("$color.accent"))
        controller.setProp("nd:t", name: "maxW", value: CanvasInspectorView.parse("240"))
        controller.setProp("nd:t", name: "text", value: CanvasInspectorView.parse("inspected"))
        var html = try doc.adapter.html()
        XCTAssertTrue(html.contains("color:var(--cv-color-accent)"))
        XCTAssertTrue(html.contains("max-width:240px"))
        XCTAssertTrue(html.contains(">inspected<"))

        controller.unsetProp("nd:t", name: "color")
        html = try doc.adapter.html()
        XCTAssertFalse(html.contains("color:var(--cv-color-accent)"), "unset removes")

        // The outline reflects the inspector's edits (read model in sync).
        let node = try XCTUnwrap(
            CanvasOutlineParser.find("nd:t", in: try XCTUnwrap(controller.outline)))
        XCTAssertTrue(node.props.contains { $0.name == "maxW" && $0.value == .num(240) })
        XCTAssertFalse(node.props.contains { $0.name == "color" })

        controller.select(nil)
        XCTAssertEqual(controller.selectedIDs, [])
    }
}
