import XCTest
import Foundation
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// P0a script-bus action surface: the `goto-line <n>` verb scrolls the active
/// editor/source to a 1-based line by setting the SourceViewChannel scroll
/// target — agent-drivable navigation (`run_verb goto-line N`) + a headless
/// scripting primitive. Mirrors the SplitAndMoveTabVerbTests Omni-invokability
/// pattern.
@MainActor
final class GoToLineVerbTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: "GoToLineVerbTests")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    func test_gotoLineVerb_setsScrollTarget() throws {
        let url = try harness.writeFile("doc.txt", "l1\nl2\nl3\nl4\nl5\n")
        let model = harness.model
        model.open(url: url)
        XCTAssertTrue(ScriptVerb.apply(verb: "goto-line 4", to: model, sessions: harness.sessions))
        XCTAssertEqual(model.sourceView.sourceScrollLineTarget, 4,
                       "goto-line sets the 1-based scroll-to-line target")
    }

    func test_gotoLineVerb_ignoresInvalidArg() throws {
        let url = try harness.writeFile("d2.txt", "x")
        let model = harness.model
        model.open(url: url)
        model.sourceView.sourceScrollLineTarget = nil
        // Recognized (returns true) but a 0/negative/non-numeric arg is a no-op (1-based).
        XCTAssertTrue(ScriptVerb.apply(verb: "goto-line 0", to: model, sessions: harness.sessions))
        XCTAssertNil(model.sourceView.sourceScrollLineTarget, "line 0 ignored (1-based)")
        XCTAssertTrue(ScriptVerb.apply(verb: "goto-line nope", to: model, sessions: harness.sessions))
        XCTAssertNil(model.sourceView.sourceScrollLineTarget, "non-numeric arg ignored")
    }

    func test_gotoLineVerb_isKnownVocabulary() {
        XCTAssertTrue(ScriptVerbCatalog.tokens.contains("goto-line"),
                      "goto-line must be in the catalog (run_verb vocabulary)")
    }
}
