import XCTest
import Foundation
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-464 — the LSP go-to verbs as deliberate commands. `declaration`,
/// `typeDefinition`, and `implementation` existed on the client/pool but
/// were unreachable from any command/verb (definition was Cmd-click-only).
/// These tests pin the new routing headlessly via the DEBUG
/// `_lastLSPNavigation` seam: kind selection, active-tab/cursor sourcing,
/// the 1-based→0-based position conversion, and the no-cursor no-op.
/// The pool/server round-trip itself is covered by the LSP pool suites.
@MainActor
final class LSPGotoCommandTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: "LSPGotoCommandTests")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    /// Open a Swift file (an LSP-mapped language) and record a cursor.
    private func openWithCursor(line: Int, column: Int) throws -> DocumentModel {
        let url = try harness.writeFile("goto.swift", "let x = 1\nlet y = x\n")
        let model = harness.model
        model.open(url: url)
        let id = model.tabs.selected!.id
        model.editor.recordEditorCursor(
            CMCursorPosition(line: line, column: column, head: 0, rangeCount: 1),
            forTabID: id)
        return model
    }

    func test_eachVerb_dispatchesItsKind_atTheRecordedCursor() throws {
        let model = try openWithCursor(line: 2, column: 8)
        let cases: [(String, DocumentModel.LSPNavigationKind)] = [
            ("editor-goto-definition", .definition),
            ("editor-goto-declaration", .declaration),
            ("editor-goto-type-definition", .typeDefinition),
            ("editor-goto-implementation", .implementation),
        ]
        for (verb, kind) in cases {
            model._lastLSPNavigation = nil
            XCTAssertTrue(
                ScriptVerb.apply(verb: verb, to: model, sessions: harness.sessions),
                "\(verb) must be a recognized script verb (TSK-464)")
            XCTAssertEqual(model._lastLSPNavigation?.kind, kind,
                "\(verb) must dispatch the \(kind) pool verb")
            // 1-based cursor (line 2, col 8) → 0-based LSP position (1, 8).
            XCTAssertEqual(model._lastLSPNavigation?.line, 1,
                "LSP line must be the 0-based cursor line")
            XCTAssertEqual(model._lastLSPNavigation?.character, 8)
            XCTAssertEqual(
                model._lastLSPNavigation?.url.lastPathComponent, "goto.swift")
        }
    }

    func test_noRecordedCursor_isANoOp() throws {
        let url = try harness.writeFile("nocursor.swift", "let x = 1\n")
        let model = harness.model
        model.open(url: url)
        XCTAssertFalse(model.navigateViaLSPAtCursor(kind: .declaration),
            "without a recorded editor cursor the command must no-op, not guess line 1")
        XCTAssertNil(model._lastLSPNavigation)
    }

    func test_nonLSPLanguage_doesNotDispatch() throws {
        let url = try harness.writeFile("plain.txt", "hello\n")
        let model = harness.model
        model.open(url: url)
        let id = model.tabs.selected!.id
        model.editor.recordEditorCursor(
            CMCursorPosition(line: 1, column: 0, head: 0, rangeCount: 1), forTabID: id)
        // Returns true (tab + cursor exist) but the language guard stops
        // the dispatch before any pool call is recorded.
        _ = model.navigateViaLSPAtCursor(kind: .implementation)
        XCTAssertNil(model._lastLSPNavigation,
            "a language with no LSP mapping must not dispatch (same guard as Cmd-click)")
    }

    func test_commandCatalog_carriesTheFourGotoCommands() {
        let registry = CommandRegistry.builtIn
        let expected: [(String, String)] = [
            ("lsp.gotoDefinition", "editor-goto-definition"),
            ("lsp.gotoDeclaration", "editor-goto-declaration"),
            ("lsp.gotoTypeDefinition", "editor-goto-type-definition"),
            ("lsp.gotoImplementation", "editor-goto-implementation"),
        ]
        for (id, verb) in expected {
            let cmd = registry.commands.first { $0.id == id }
            XCTAssertNotNil(cmd, "\(id) must be in the built-in catalog (TSK-464)")
            XCTAssertEqual(cmd?.scriptVerb, verb,
                "\(id) must be palette/keybinding-invokable via \(verb)")
        }
    }
}
