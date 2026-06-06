import XCTest
import Foundation
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Wiring coverage for the view/tab commands that gained script verbs so
/// they're Omni-invokable + automatable (they previously shipped
/// `scriptVerb: nil` — menu/keyboard-only): toggle-split / swap-split /
/// move-tab-left / move-tab-right. Each routes to an existing @MainActor
/// model method. Mirrors the HeadlessHarness pattern.
@MainActor
final class SplitAndMoveTabVerbTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: "SplitAndMoveTabVerbTests")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    func test_toggleSplitVerb_opensAndClosesSplit() throws {
        let url = try harness.writeFile("s.txt", "content")
        let model = harness.model
        model.open(url: url)
        XCTAssertFalse(model.isSplitOpen, "precondition: no split")

        XCTAssertTrue(ScriptVerb.apply(verb: "toggle-split", to: model, sessions: harness.sessions))
        XCTAssertTrue(model.isSplitOpen, "toggle-split should open a split for the current file")

        XCTAssertTrue(ScriptVerb.apply(verb: "toggle-split", to: model, sessions: harness.sessions))
        XCTAssertFalse(model.isSplitOpen, "toggle-split again should close it")
    }

    func test_swapSplitVerb_isHandled() throws {
        // swap-split's pane state is opaque from here; assert the verb is
        // recognised + applied in-process (returns true) without crashing,
        // both with and without an active split.
        let url = try harness.writeFile("sw.txt", "x")
        let model = harness.model
        model.open(url: url)
        XCTAssertTrue(ScriptVerb.apply(verb: "swap-split", to: model, sessions: harness.sessions))
        _ = ScriptVerb.apply(verb: "toggle-split", to: model, sessions: harness.sessions)
        XCTAssertTrue(ScriptVerb.apply(verb: "swap-split", to: model, sessions: harness.sessions))
    }

    func test_moveTabRightAndLeftVerbs_reorderTheSelectedTab() throws {
        let a = try harness.writeFile("a.txt", "a")
        let b = try harness.writeFile("b.txt", "b")
        let c = try harness.writeFile("c.txt", "c")
        let model = harness.model
        model.open(url: a)
        model.openInNewTab(b)
        model.openInNewTab(c)
        // Select the first tab, then move it right.
        let firstID = model.tabs.tabs[0].id
        model.selectTab(at: 0)
        XCTAssertTrue(ScriptVerb.apply(verb: "move-tab-right", to: model, sessions: harness.sessions))
        XCTAssertEqual(model.tabs.tabs[1].id, firstID,
                       "move-tab-right must shift the first tab to position 1")

        // Move it back left to position 0.
        if let idx = model.tabs.tabs.firstIndex(where: { $0.id == firstID }) {
            model.selectTab(at: idx)
        }
        XCTAssertTrue(ScriptVerb.apply(verb: "move-tab-left", to: model, sessions: harness.sessions))
        XCTAssertEqual(model.tabs.tabs[0].id, firstID,
                       "move-tab-left must shift it back to position 0")
    }

    func test_allFourCommands_arePaletteInvokable() {
        for id in ["view.toggleSplit", "view.swapSplit", "tabs.moveLeft", "tabs.moveRight"] {
            XCTAssertNotNil(CommandRegistry.builtIn.command(id: id)?.scriptVerb,
                            "\(id) should carry a script verb")
            XCTAssertTrue(CommandRegistry.builtIn.paletteInvokable.contains { $0.id == id },
                          "\(id) must be palette-invokable")
        }
    }
}
