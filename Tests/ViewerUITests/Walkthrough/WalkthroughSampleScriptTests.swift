import XCTest
@testable import ViewerUI
import ViewerCore

/// Verifies the sample walkthrough JSON (the one the user provided in
/// the task spec) loads cleanly, has the expected shape, and drives
/// the player's delegate through every step without crashing.
///
/// Runs on host because no NSWindow is involved — only model state +
/// engine state mutations, which are pure logic. The fixture's
/// `rootHint` is the markdown_viewer repo path; we substitute a
/// temp-dir root and re-emit the JSON so the path-escape validator
/// passes wherever the tests run from.
@MainActor
final class WalkthroughSampleScriptTests: XCTestCase {

    /// Inline copy of the fixture JSON (also lives on disk at
    /// `Tests/Fixtures/walkthroughs/sample.json` for manual smoke runs).
    /// Keeping it inline here lets the test stand alone without a
    /// resources-bundle dance.
    private static let sampleJSON: (String) -> String = { root in
        """
        {
          "schema": "textview.walkthrough/v1",
          "id": "sample",
          "title": "Sample walkthrough",
          "rootHint": "\(root)",
          "steps": [
            { "id": "s1", "narration": "Welcome — let's tour the source.", "actions": [{"kind":"narrateOnly"}] },
            { "id": "s2", "narration": "Open the main app file.", "actions": [{"kind":"openFile","path":"Sources/MarkdownViewer/main.swift"}] },
            { "id": "s3", "narration": "Highlight the lazy-tab restore.", "actions": [{"kind":"highlightRange","path":"Sources/ViewerUI/DocumentModel.swift","startLine":970,"endLine":985}] }
          ]
        }
        """
    }

    func test_sampleScript_loadsCleanly() throws {
        // Use a transient root that actually exists on disk so the
        // path-escape validator's `resolvingSymlinksInPath` doesn't
        // trip on `/Users/me/...` not existing in CI sandboxes.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-sample-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/MarkdownViewer"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/ViewerUI"),
            withIntermediateDirectories: true
        )

        let json = Self.sampleJSON(root.path)
        let result = WalkthroughLoader.load(data: Data(json.utf8))
        switch result {
        case .success(let script):
            XCTAssertEqual(script.id, "sample")
            XCTAssertEqual(script.steps.count, 3)
            XCTAssertEqual(script.steps[0].id, "s1")
            XCTAssertEqual(script.steps[1].id, "s2")
            XCTAssertEqual(script.steps[2].id, "s3")
        case .failure(let err):
            XCTFail("loader failed: \(err)")
        }
    }

    func test_playerController_walksSampleScript_endToEnd() throws {
        // Decode from JSON so we don't reach for the action payloads'
        // (non-public) memberwise inits. JSON round-trip is the
        // canonical construction path for scripts at runtime anyway.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wt-walk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let json = """
        {
          "schema": "textview.walkthrough/v1",
          "id": "sample",
          "title": "Sample",
          "rootHint": "\(root.path)",
          "steps": [
            { "id": "s1", "narration": "hi", "actions": [{"kind":"narrateOnly"}] },
            { "id": "s2", "narration": "open", "actions": [{"kind":"openFile","path":"missing.swift"}] },
            { "id": "s3", "narration": "highlight", "actions": [{"kind":"highlightRange","path":"missing.swift","startLine":10,"endLine":12,"style":"focus"}] }
          ]
        }
        """
        let script: WalkthroughScript
        switch WalkthroughLoader.load(data: Data(json.utf8)) {
        case .success(let s): script = s
        case .failure(let e): XCTFail("loader: \(e)"); return
        }
        let model = DocumentModel()
        let controller = WalkthroughPlayerController(model: model)
        controller.start(script)
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.currentStepIndex, 0)

        controller.next()
        XCTAssertEqual(controller.currentStepIndex, 1)

        controller.next()
        XCTAssertEqual(controller.currentStepIndex, 2)

        // Step 3 issued highlightRange; bridge should hold the range
        // even though the file doesn't exist (we still record the
        // user-visible request).
        XCTAssertNotNil(model.walkthroughBridge.highlight)
        XCTAssertEqual(model.walkthroughBridge.highlight?.startLine, 10)
        XCTAssertEqual(model.walkthroughBridge.highlight?.endLine, 12)

        // Past last step -> engine state .done, controller deactivates
        // on exit but not on .done — leave the visual on screen.
        controller.next()
        // exit clears.
        controller.exit()
        XCTAssertFalse(controller.isActive)
        XCTAssertNil(model.walkthroughBridge.highlight)
    }

    func test_playerController_pauseResume_togglesEngineState() throws {
        let model = DocumentModel()
        let controller = WalkthroughPlayerController(model: model)
        let json = """
        {"schema":"textview.walkthrough/v1","id":"t","title":"t","steps":[
            {"id":"s1","actions":[{"kind":"narrateOnly"}]},
            {"id":"s2","actions":[{"kind":"narrateOnly"}]}
        ]}
        """
        let script: WalkthroughScript
        switch WalkthroughLoader.load(data: Data(json.utf8)) {
        case .success(let s): script = s
        case .failure(let e): XCTFail("\(e)"); return
        }
        controller.start(script)
        XCTAssertFalse(controller.isPaused)
        controller.togglePlayPause()
        XCTAssertTrue(controller.isPaused)
        controller.togglePlayPause()
        XCTAssertFalse(controller.isPaused)
    }

    func test_playerController_jumpToStepID_movesCursor() throws {
        let model = DocumentModel()
        let controller = WalkthroughPlayerController(model: model)
        let json = """
        {"schema":"textview.walkthrough/v1","id":"t","title":"t","steps":[
            {"id":"a","actions":[{"kind":"narrateOnly"}]},
            {"id":"b","actions":[{"kind":"narrateOnly"}]},
            {"id":"c","actions":[{"kind":"narrateOnly"}]}
        ]}
        """
        let script: WalkthroughScript
        switch WalkthroughLoader.load(data: Data(json.utf8)) {
        case .success(let s): script = s
        case .failure(let e): XCTFail("\(e)"); return
        }
        controller.start(script)
        controller.jump(to: "c")
        XCTAssertEqual(controller.currentStepIndex, 2)
    }
}
