import XCTest
import Foundation
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-951 — the menu-only Edit text-transforms (and the two view toggles) are
/// now palette-invokable via script verbs. These pin the WIRING end-to-end on
/// the host: invoking the verb through `ScriptVerb.apply` (the same path the
/// palette's `invokeCommand` takes) drives the model transform and mutates the
/// active file. The transforms' pure logic is covered at the LineOps/helper
/// layer; this proves the new palette → dispatch → model hop.
@MainActor
final class PaletteEditTransformVerbTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: "PaletteEditTransformVerbTests")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    private func openText(_ name: String, _ contents: String) throws -> (DocumentModel, URL) {
        let url = try harness.writeFile(name, contents)
        let model = harness.model
        model.open(url: url)
        return (model, url)
    }

    private func apply(_ verb: String, on model: DocumentModel) -> Bool {
        ScriptVerb.apply(verb: verb, to: model, sessions: harness.sessions)
    }

    func test_removeEmptyLines_verb_transformsActiveFile() throws {
        let (model, url) = try openText("rm.txt", "a\n\n\nb\n\nc\n")
        XCTAssertTrue(apply("edit-remove-empty-lines", on: model),
            "the verb must be recognized + dispatched")
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(after.contains("\n\n"), "empty lines must be gone after the verb runs")
        XCTAssertEqual(after, "a\nb\nc\n")
    }

    func test_trimTrailing_verb_transformsActiveFile() throws {
        let (model, url) = try openText("trim.txt", "a   \nb\t\nc\n")
        XCTAssertTrue(apply("edit-trim-trailing", on: model))
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(after, "a\nb\nc\n", "trailing whitespace must be stripped")
    }

    func test_minifyJSON_verb_transformsActiveJSON() throws {
        let (model, url) = try openText("d.json", "{\n  \"a\" : 1,\n  \"b\" : 2\n}\n")
        XCTAssertTrue(apply("edit-minify-json", on: model))
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(after, "{\"a\":1,\"b\":2}", "JSON must be minified")
    }

    func test_uppercase_verb_transformsActiveFile() throws {
        let (model, url) = try openText("up.txt", "Hello World\n")
        XCTAssertTrue(apply("edit-uppercase", on: model))
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(after, "HELLO WORLD\n", "TSK-1113: text must be uppercased")
    }

    func test_lowercase_verb_transformsActiveFile() throws {
        let (model, url) = try openText("low.txt", "Hello WORLD\n")
        XCTAssertTrue(apply("edit-lowercase", on: model))
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(after, "hello world\n", "TSK-1113: text must be lowercased")
    }

    func test_capitalize_verb_transformsActiveFile() throws {
        let (model, url) = try openText("cap.txt", "hello world\n")
        XCTAssertTrue(apply("edit-capitalize", on: model))
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(after, "Hello World\n", "TSK-1113: each word must be title-cased")
    }

    func test_demoteHeading_verb_transformsActiveFile() throws {
        let (model, url) = try openText("h.md", "# Title\n\nbody\n")
        XCTAssertTrue(apply("edit-demote-heading", on: model))
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(after, "## Title\n\nbody\n",
            "TSK-1186: demote increases the heading level (# → ##)")
    }

    func test_promoteHeading_verb_transformsActiveFile() throws {
        let (model, url) = try openText("h2.md", "## Title\n\nbody\n")
        XCTAssertTrue(apply("edit-promote-heading", on: model))
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(after, "# Title\n\nbody\n",
            "TSK-1186: promote decreases the heading level (## → #)")
    }

    /// Every new verb must be RECOGNIZED by the dispatcher (a no-op on a
    /// non-applicable file still returns true — the verb is known). Guards the
    /// registry↔dispatcher vocabulary wiring for every command in the slice.
    func test_allNewVerbs_areRecognized() throws {
        let (model, _) = try openText("x.txt", "hello\n")
        for verb in [
            "toggle-word-wrap", "toggle-invisibles",
            "edit-remove-empty-lines", "edit-collapse-blank-lines",
            "edit-trim-trailing", "edit-ensure-final-newline",
            "edit-minify-json", "edit-insert-toc", "edit-insert-date",
            "edit-uppercase", "edit-lowercase", "edit-capitalize",
            "edit-promote-heading", "edit-demote-heading",
            "toggle-view-only",
        ] {
            XCTAssertTrue(apply(verb, on: model), "\(verb) must be a recognized script verb")
        }
    }

    /// TSK-936 — the verb flips the active tab's View-only (read-only) lock.
    /// Open an editable text file in the Editor lens (viewOnly == false), then
    /// the verb must flip it on, and again off.
    func test_toggleViewOnly_verb_flipsLockState() throws {
        let (model, _) = try openText("lock.txt", "let x = 1\n")
        model.selectViewPrimary(.editor, viewOnly: false)
        XCTAssertFalse(model.viewModePresentation.viewOnly, "precondition: editing")
        XCTAssertTrue(apply("toggle-view-only", on: model))
        XCTAssertTrue(model.viewModePresentation.viewOnly, "verb must turn the lock ON")
        XCTAssertTrue(apply("toggle-view-only", on: model))
        XCTAssertFalse(model.viewModePresentation.viewOnly, "verb must turn the lock OFF again")
    }

    func test_toggleWordWrap_verb_flipsModelState() throws {
        let model = harness.model
        let before = model.sourceWordWrap
        XCTAssertTrue(apply("toggle-word-wrap", on: model))
        XCTAssertNotEqual(model.sourceWordWrap, before, "the verb must flip word-wrap state")
    }

    func test_toggleInvisibles_verb_flipsModelState() throws {
        let model = harness.model
        let before = model.showInvisibleChars
        XCTAssertTrue(apply("toggle-invisibles", on: model))
        XCTAssertNotEqual(model.showInvisibleChars, before, "the verb must flip invisibles state")
    }
}
