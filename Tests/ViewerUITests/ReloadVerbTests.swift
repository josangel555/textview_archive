import XCTest
import Foundation
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Wiring coverage for the `reload` script verb that makes the shipped
/// `file.reload` command Omni-invokable + automatable (it previously had
/// `scriptVerb: nil`, so Reload was menu/⌘R-only — absent from the command
/// palette and untestable headlessly). Mirrors the HeadlessHarness pattern.
@MainActor
final class ReloadVerbTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: "ReloadVerbTests")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    func test_reloadVerb_isHandled_andPicksUpDiskChanges() throws {
        let url = try harness.writeFile("r.txt", "v1")
        let model = harness.model
        model.open(url: url)
        guard case .loaded(let f0) = model.tabs.tabs[0].state else {
            return XCTFail("precondition: file should load as text")
        }
        XCTAssertEqual(f0.contents, "v1")

        // Mutate on disk behind the app's back, then fire the verb.
        try "v2 reloaded".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(
            ScriptVerb.apply(verb: "reload", to: model, sessions: harness.sessions),
            "reload verb must be recognised + handled in-process")

        guard case .loaded(let f1) = model.tabs.tabs[0].state else {
            return XCTFail("tab should still be loaded after reload")
        }
        XCTAssertEqual(f1.contents, "v2 reloaded",
            "reload must re-read the new disk content")
    }

    func test_reloadVerb_noSelection_isHandledNoCrash() {
        // reloadCurrentFile() guards on selection, so an empty-state reload is
        // a recognised no-op (returns true: the verb is handled here, not a
        // window/NSApp residual).
        XCTAssertTrue(
            ScriptVerb.apply(verb: "reload", to: harness.model, sessions: harness.sessions))
    }
}
