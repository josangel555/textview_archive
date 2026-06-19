import XCTest
@testable import ViewerUI
import ViewerCore

/// Behavior tests for the `awaitUser` checkpoint wiring on
/// `WalkthroughPlayerController` (TSK-378). These pin the MODEL-layer
/// outcome of reaching a checkpoint and replying — the bidirectional
/// channel back to the agent — without any on-screen UI. They construct
/// a bare `DocumentModel` + controller (same host-safe pattern as
/// `WalkthroughBridgeTests`) and point the checkpoint store at a temp
/// dir so the persisted artifacts can be inspected.
///
/// The strip's *rendered* pills/text-field are VM-only (SwiftUI render
/// path); these tests guard the logic so a regression of "reaching a
/// checkpoint writes the prompt" / "replying persists the answer +
/// advances" fails on the host gate.
@MainActor
final class WalkthroughCheckpointWiringTests: XCTestCase {

    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-wiring-\(UUID().uuidString)", isDirectory: true)
    }

    /// A 3-step script: narrate → awaitUser checkpoint → narrate.
    private func makeScript() -> WalkthroughScript {
        WalkthroughScript(
            id: "tour-ckpt",
            title: "Checkpoint tour",
            steps: [
                Step(id: "s1", narration: "Welcome",
                     actions: [.narrateOnly]),
                Step(id: "s2", narration: "Pick one",
                     actions: [.awaitUser(AwaitUserPayload(
                        prompt: "Which theme?",
                        placeholder: "type…",
                        pills: ["Dark", "Light"]
                     ))]),
                Step(id: "s3", narration: "Done",
                     actions: [.narrateOnly]),
            ]
        )
    }

    func test_reachingCheckpoint_writesPromptAndPauses() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = DocumentModel()
        let controller = WalkthroughPlayerController(
            model: model,
            checkpointStore: WalkthroughCheckpointStore(directory: dir)
        )
        controller.start(makeScript())          // applies step 0 (s1)
        controller.next()                        // → step 1 (s2, awaitUser)

        // The checkpoint payload is pending and the engine paused.
        XCTAssertNotNil(controller.pendingAwaitUser)
        XCTAssertEqual(controller.pendingAwaitUser?.prompt, "Which theme?")
        XCTAssertTrue(controller.isPaused)

        // The prompt was persisted for a polling agent.
        let store = WalkthroughCheckpointStore(directory: dir)
        let ckpt = try XCTUnwrap(
            store.readCheckpoint(walkthroughId: "tour-ckpt", stepId: "s2")
        )
        XCTAssertEqual(ckpt.prompt, "Which theme?")
        XCTAssertEqual(ckpt.pills, ["Dark", "Light"])
    }

    func test_reply_persistsAnswerAndAdvances() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = DocumentModel()
        let controller = WalkthroughPlayerController(
            model: model,
            checkpointStore: WalkthroughCheckpointStore(directory: dir)
        )
        controller.start(makeScript())
        controller.next()                        // → checkpoint
        XCTAssertNotNil(controller.pendingAwaitUser)

        controller.reply(.option("Dark"))        // user picks a pill

        // Advanced past the checkpoint, pending cleared.
        XCTAssertNil(controller.pendingAwaitUser)
        XCTAssertEqual(controller.currentStepIndex, 2)   // on s3
        XCTAssertEqual(controller.currentStep?.id, "s3")

        // The reply is on disk — the channel back to Claude.
        let store = WalkthroughCheckpointStore(directory: dir)
        let reply = try XCTUnwrap(
            store.readReply(walkthroughId: "tour-ckpt", stepId: "s2")
        )
        XCTAssertEqual(reply.answer, .option("Dark"))
    }

    func test_replyFreeForm_persistsText() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = DocumentModel()
        let controller = WalkthroughPlayerController(
            model: model,
            checkpointStore: WalkthroughCheckpointStore(directory: dir)
        )
        controller.start(makeScript())
        controller.next()
        controller.reply(.freeForm("solarized please"))

        let store = WalkthroughCheckpointStore(directory: dir)
        let reply = try XCTUnwrap(
            store.readReply(walkthroughId: "tour-ckpt", stepId: "s2")
        )
        XCTAssertEqual(reply.answer, .freeForm("solarized please"))
        XCTAssertEqual(controller.currentStep?.id, "s3")
    }

    func test_replyWithNoPendingCheckpoint_isNoOp() throws {
        // A stray reply (e.g. double pill click) must not corrupt state
        // or write a bogus file.
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = DocumentModel()
        let controller = WalkthroughPlayerController(
            model: model,
            checkpointStore: WalkthroughCheckpointStore(directory: dir)
        )
        controller.start(makeScript())           // on s1, no checkpoint
        let idxBefore = controller.currentStepIndex
        controller.reply(.option("Dark"))
        XCTAssertEqual(controller.currentStepIndex, idxBefore,
                       "reply with no pending checkpoint must not advance")
        let store = WalkthroughCheckpointStore(directory: dir)
        XCTAssertNil(store.readReply(walkthroughId: "tour-ckpt", stepId: "s1"))
    }

    func test_noStore_checkpointStillPausesGracefully() {
        // No checkpoint store configured ⇒ persistence is skipped but
        // the tour must still pause at the checkpoint (the transport
        // simply isn't wired; the UX is unaffected).
        let model = DocumentModel()
        let controller = WalkthroughPlayerController(model: model)  // nil store
        controller.start(makeScript())
        controller.next()
        XCTAssertNotNil(controller.pendingAwaitUser)
        XCTAssertTrue(controller.isPaused)
        // Reply still advances even though nothing is persisted.
        controller.reply(.option("Dark"))
        XCTAssertNil(controller.pendingAwaitUser)
        XCTAssertEqual(controller.currentStep?.id, "s3")
    }
}
