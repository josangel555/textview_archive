import XCTest
import Foundation
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// Host wiring coverage for the `editor-focus` script verb (TSK-1020).
///
/// KEY_01 (`KeySynthUATTests.test_KEY_01_typeStringReachesEditorModel`) failed
/// on the VM because `editor-set-mode editor` flips the active tab to CM6 but
/// does NOT give the CM6 WKWebView keyboard first-responder — so synthesized
/// `ui-type` keydowns insert into nothing and never reach the editor model.
///
/// The fix adds an `editor-focus` verb that routes to the mode-aware,
/// host-tested `DocumentModel.returnFocusToActiveDocument`. For an `.editor`
/// tab that bumps `editorFocusRequest` — the SAME nonce the CM6 representable
/// consumes (`webView.window?.makeFirstResponder(webView)` + JS `.focus()`).
/// The live keystroke insertion is the VM tail; these tests pin the verb's
/// model-state outcome so a wiring regression fails on the host gate.
@MainActor
final class EditorFocusVerbTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: "EditorFocusVerbTests")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    /// In editor mode, `editor-focus` bumps the editor focus-request nonce the
    /// CM6 representable observes — the wiring KEY_01 depends on. A logic
    /// regression that stops bumping it fails here on the host gate.
    func test_editorFocusVerb_inEditorMode_bumpsEditorFocusRequest() throws {
        let url = try harness.writeFile("note.md", "")
        let model = harness.model
        model.open(url: url)
        XCTAssertTrue(
            ScriptVerb.apply(verb: "editor-set-mode editor",
                             to: model, sessions: harness.sessions))
        XCTAssertEqual(model.currentViewMode, .editor,
                       "precondition: the active tab is in editor mode")

        let before = model.editorFocusRequest
        XCTAssertTrue(
            ScriptVerb.apply(verb: "editor-focus",
                             to: model, sessions: harness.sessions),
            "editor-focus must be a recognised in-process verb")
        XCTAssertEqual(model.editorFocusRequest, before &+ 1,
                       "editor-focus in editor mode must bump editorFocusRequest "
                       + "so the CM6 webview re-takes first responder before ui-type")
    }

    /// The verb is a focus-request bump, so firing it twice advances the nonce
    /// twice — each invocation is a distinct one-shot focus request (matches
    /// the nonce idiom; a stable redraw doesn't steal focus, but an explicit
    /// re-focus does).
    func test_editorFocusVerb_isRepeatable() throws {
        let url = try harness.writeFile("note.md", "")
        let model = harness.model
        model.open(url: url)
        _ = ScriptVerb.apply(verb: "editor-set-mode editor",
                             to: model, sessions: harness.sessions)

        let before = model.editorFocusRequest
        _ = ScriptVerb.apply(verb: "editor-focus", to: model, sessions: harness.sessions)
        _ = ScriptVerb.apply(verb: "editor-focus", to: model, sessions: harness.sessions)
        XCTAssertEqual(model.editorFocusRequest, before &+ 2,
                       "each editor-focus is a distinct focus request")
    }

    /// In source mode the document surface owns its own first responder (an
    /// NSTextView, not a nonce-driven CM6/WKWebView), so `editor-focus` is a
    /// no-op on the editor nonce — it must NOT spuriously bump it.
    func test_editorFocusVerb_inSourceMode_doesNotBumpEditorFocusRequest() throws {
        let url = try harness.writeFile("note.md", "x")
        let model = harness.model
        model.open(url: url)
        XCTAssertTrue(
            ScriptVerb.apply(verb: "editor-set-mode source",
                             to: model, sessions: harness.sessions))
        XCTAssertEqual(model.currentViewMode, .source,
                       "precondition: the active tab is in source mode")

        let before = model.editorFocusRequest
        XCTAssertTrue(
            ScriptVerb.apply(verb: "editor-focus",
                             to: model, sessions: harness.sessions),
            "editor-focus is still a recognised verb in source mode")
        XCTAssertEqual(model.editorFocusRequest, before,
                       "source mode owns its first responder by other means — "
                       + "editor-focus must not bump the editor nonce")
    }

    /// With no open document there is nothing to focus, so the verb is a safe
    /// no-op and must not bump the nonce.
    func test_editorFocusVerb_withNoDocument_isNoOp() throws {
        let model = harness.model
        let before = model.editorFocusRequest
        XCTAssertTrue(
            ScriptVerb.apply(verb: "editor-focus",
                             to: model, sessions: harness.sessions),
            "editor-focus is recognised even with no open document")
        XCTAssertEqual(model.editorFocusRequest, before,
                       "no active document ⇒ editor-focus is a no-op")
    }
}
