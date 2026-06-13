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

    // MARK: - editor.format (TSK-627)

    func test_formatVerb_dispatchesWithBufferSnapshot() throws {
        let url = try harness.writeFile("fmt.swift", "let  x=1\n")
        let model = harness.model
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id) // materialize the buffer

        XCTAssertTrue(
            ScriptVerb.apply(verb: "editor-format", to: model, sessions: harness.sessions),
            "editor-format must be a recognized script verb (TSK-627)")
        XCTAssertEqual(model._lastFormatDispatch?.url.lastPathComponent, "fmt.swift")
        XCTAssertEqual(model._lastFormatDispatch?.snapshot, "let  x=1\n",
            "the dispatch must snapshot the buffer text the edits will apply against")
    }

    func test_format_noBuffer_isANoOp() throws {
        let url = try harness.writeFile("nobuf.swift", "let x = 1\n")
        let model = harness.model
        model.open(url: url)
        // No editor buffer materialized → refuse rather than format a
        // buffer that doesn't exist.
        XCTAssertFalse(model.formatActiveEditorViaLSP())
        XCTAssertNil(model._lastFormatDispatch)
    }

    func test_format_nonLSPLanguage_isANoOp() throws {
        let url = try harness.writeFile("plain.txt", "hello\n")
        let model = harness.model
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)
        XCTAssertFalse(model.formatActiveEditorViaLSP(),
            "a language with no LSP mapping must refuse, same as the go-to verbs")
        XCTAssertNil(model._lastFormatDispatch)
    }

    func test_commandCatalog_carriesTheFormatCommand() {
        let cmd = CommandRegistry.builtIn.command(id: "lsp.format")
        XCTAssertNotNil(cmd, "lsp.format must be in the built-in catalog (TSK-627)")
        XCTAssertEqual(cmd?.scriptVerb, "editor-format")
    }

    // MARK: - LSP rename prompt (TSK-640)
    // Host-reliable: a real LSP-mapped .swift file makes the rename guards pass
    // and `_lastRenameDispatch` records synchronously (the async pool round trip
    // fails silently without a server — irrelevant to the prompt state machine).
    // The buffer-rename end-to-end is the fake-LSP VM suite (LSPRenameEndToEndTests).

    func test_renamePrompt_showVerbPresents_submitDispatchesAndDismisses() throws {
        let model = try openWithCursor(line: 2, column: 8)
        _ = model.editor.editorBuffer(forTabID: model.tabs.selected!.id) // rename needs a live buffer
        XCTAssertTrue(model.canRenameActiveEditorSymbol, "swift + cursor + buffer ⇒ rename-able")

        XCTAssertTrue(
            ScriptVerb.apply(verb: "show-lsp-rename", to: model, sessions: harness.sessions),
            "show-lsp-rename must be a recognized verb")
        XCTAssertTrue(model.isLSPRenamePromptPresented, "the verb presents the prompt")

        model._lastRenameDispatch = nil
        XCTAssertTrue(model.submitLSPRename("renamed"), "submit dispatches the rename")
        XCTAssertEqual(model._lastRenameDispatch?.newName, "renamed",
                       "submit drives renameActiveEditorSymbolViaLSP with the typed name")
        XCTAssertFalse(model.isLSPRenamePromptPresented, "submit dismisses the prompt")
    }

    func test_renamePrompt_refusesWhenNotRenameable() throws {
        // Plain-text (no LSP language) → not rename-able → no present.
        let url = try harness.writeFile("plain.txt", "hello\n")
        let model = harness.model
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)
        model.editor.recordEditorCursor(
            CMCursorPosition(line: 1, column: 0, head: 0, rangeCount: 1), forTabID: id)
        XCTAssertFalse(model.canRenameActiveEditorSymbol, "a non-LSP language isn't rename-able")
        model.showLSPRenamePrompt()
        XCTAssertFalse(model.isLSPRenamePromptPresented,
                       "showLSPRenamePrompt must refuse a non-rename-able context")
    }

    func test_renamePrompt_dismissClearsPresentation() throws {
        let model = try openWithCursor(line: 1, column: 4)
        _ = model.editor.editorBuffer(forTabID: model.tabs.selected!.id)
        model.showLSPRenamePrompt()
        XCTAssertTrue(model.isLSPRenamePromptPresented)
        model.dismissLSPRenamePrompt()
        XCTAssertFalse(model.isLSPRenamePromptPresented, "dismiss clears the flag")
    }

    func test_commandCatalog_carriesTheRenameCommand() {
        let cmd = CommandRegistry.builtIn.command(id: "lsp.rename")
        XCTAssertNotNil(cmd, "lsp.rename must be in the built-in catalog (TSK-640)")
        XCTAssertEqual(cmd?.scriptVerb, "show-lsp-rename")
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
