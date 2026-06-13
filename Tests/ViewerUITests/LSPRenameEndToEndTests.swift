import XCTest
import Foundation
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-640 stage 2 — `renameActiveEditorSymbolViaLSP`: dispatch guards,
/// the REAL fake-server round trip (two edits in one response → reverse
/// application via `LSPTextEditApplier`), the snapshot guard under a
/// simulated race, and the not-open-file skip policy. Same harness as
/// `LSPFormatEndToEndTests` (DocumentModel `lspPool` injection + a
/// registry routing `.fakelsp` to `MDVFakeLSPServer`). Skips when the
/// fake-server binary isn't built.
@MainActor
final class LSPRenameEndToEndTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!
    private var pool: LSPPool!

    override func setUp() async throws {
        try await super.setUp()
        harness = nil
        pool = nil
    }

    override func tearDown() async throws {
        if let pool { await pool.closeAll() }
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    private func locateFakeServer() throws -> URL {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while dir.path != "/",
              !fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            dir = dir.deletingLastPathComponent()
        }
        let build = dir.appendingPathComponent(".build")
        for config in ["debug", "release"] {
            for triple in (try? fm.contentsOfDirectory(
                at: build, includingPropertiesForKeys: nil)) ?? [] {
                let candidate = triple.appendingPathComponent(config)
                    .appendingPathComponent("MDVFakeLSPServer")
                if fm.isExecutableFile(atPath: candidate.path) { return candidate }
            }
        }
        throw XCTSkip("MDVFakeLSPServer not built — run swift build --product MDVFakeLSPServer")
    }

    private func makeModelWithFakeLSP() throws -> DocumentModel {
        let binary = try locateFakeServer()
        let env = ProcessInfo.processInfo.environment
        let entry = LSPLanguageEntry(
            language: .swift,
            fileExtensions: ["fakelsp"],
            rootFinder: { $0.deletingLastPathComponent() },
            serverLauncher: { root in
                LSPClient.Config(
                    executable: binary, arguments: [],
                    workspaceRoot: root, environment: env)
            })
        pool = LSPPool(registry: LSPLanguageRegistry(entries: [entry]))
        harness = HeadlessHarness(label: "LSPRenameEndToEndTests", lspPool: pool)
        return harness.model
    }

    private func waitUntil(
        _ timeout: TimeInterval = 5.0, _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    /// Fake-server fixture: rename returns TWO edits in the requested
    /// file — line 0 chars 4–7 and line 2 chars 8–11 → newName. This doc
    /// puts "foo" at both spans, so a correct apply renames both.
    private let doc = "let foo = 1\nlet unrelated = 2\nlet y = foo"
    private let renamed = "let walrus = 1\nlet unrelated = 2\nlet y = walrus"

    private func seedCursor(_ model: DocumentModel, tabID: UUID) {
        model.recordEditorCursor(
            CMCursorPosition(line: 0, column: 4, head: 4, rangeCount: 1),
            forTabID: tabID)
    }

    func test_rename_appliesBothServerEditsToTheBuffer() async throws {
        let model = try makeModelWithFakeLSP()
        let url = try harness.writeFile("doc.fakelsp", doc)
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)
        seedCursor(model, tabID: id)

        XCTAssertTrue(model.renameActiveEditorSymbolViaLSP(newName: "walrus"))
        XCTAssertEqual(model._lastRenameDispatch?.newName, "walrus")
        await waitUntil { model.editor.editorBuffers[id]?.text == self.renamed }
        XCTAssertEqual(model.editor.editorBuffers[id]?.text, renamed,
            "both WorkspaceEdit spans must land (reverse application)")
        XCTAssertEqual(model.editor.editorBuffers[id]?.isDirty, true,
            "a renamed buffer is unsaved work — must be dirty")
    }

    /// The `lsp-rename <newName>` script verb (TSK-640) — the headless/automation
    /// entry the future VM T4 UAT + scripting drive. Pins verb → the tested
    /// rename engine end-to-end through the fake server (both server edits land).
    func test_lspRenameVerb_dispatchesRenameThroughTheEngine() async throws {
        let model = try makeModelWithFakeLSP()
        let url = try harness.writeFile("verb.fakelsp", doc)
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)
        seedCursor(model, tabID: id)

        ScriptVerb.apply(verb: "lsp-rename walrus", to: model, sessions: harness.sessions)
        XCTAssertEqual(model._lastRenameDispatch?.newName, "walrus",
                       "the verb must dispatch the rename with its arg as the new name")
        await waitUntil { model.editor.editorBuffers[id]?.text == self.renamed }
        XCTAssertEqual(model.editor.editorBuffers[id]?.text, renamed,
                       "the verb drives the full engine — both WorkspaceEdit spans land")
    }

    /// The interactive rename PROMPT (TSK-640): the show-lsp-rename verb (the
    /// command/menu entry) presents it; submit drives the host-tested engine and
    /// dismisses. Pins the model state machine + submit wiring (the prompt VIEW
    /// render is the VM/review tail).
    func test_renamePrompt_showThenSubmit_drivesEngine_andDismisses() async throws {
        let model = try makeModelWithFakeLSP()
        let url = try harness.writeFile("prompt.fakelsp", doc)
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)
        seedCursor(model, tabID: id)

        XCTAssertTrue(model.canRenameActiveEditorSymbol,
                      "an LSP editor with a recorded cursor is rename-able")
        ScriptVerb.apply(verb: "show-lsp-rename", to: model, sessions: harness.sessions)
        XCTAssertTrue(model.isLSPRenamePromptPresented, "show-lsp-rename presents the prompt")

        XCTAssertTrue(model.submitLSPRename("walrus"), "submit dispatches the rename")
        XCTAssertFalse(model.isLSPRenamePromptPresented, "submit dismisses the prompt")
        await waitUntil { model.editor.editorBuffers[id]?.text == self.renamed }
        XCTAssertEqual(model.editor.editorBuffers[id]?.text, renamed,
                       "the prompt's submit drives the full engine (both spans land)")
    }

    func test_rename_droppedWhenBufferChangedSinceDispatch() async throws {
        let model = try makeModelWithFakeLSP()
        let url = try harness.writeFile("race.fakelsp", doc)
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)
        seedCursor(model, tabID: id)

        XCTAssertTrue(model.renameActiveEditorSymbolViaLSP(newName: "walrus"))
        model.updateEditorText("user typed this\n", forTabID: id)

        try? await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(model.editor.editorBuffers[id]?.text, "user typed this\n",
            "a stale rename response must NOT clobber text typed during the round trip")
    }

    func test_rename_guardSet() async throws {
        let model = try makeModelWithFakeLSP()
        let url = try harness.writeFile("guards.fakelsp", doc)
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)

        // No cursor recorded yet → refuse.
        XCTAssertFalse(model.renameActiveEditorSymbolViaLSP(newName: "x"),
                       "no cursor position = nothing to rename")
        seedCursor(model, tabID: id)
        // Empty / whitespace name → refuse.
        XCTAssertFalse(model.renameActiveEditorSymbolViaLSP(newName: "   "))
        // Whitespace-trimmed name is what dispatches.
        XCTAssertTrue(model.renameActiveEditorSymbolViaLSP(newName: " ok "))
        XCTAssertEqual(model._lastRenameDispatch?.newName, "ok")
    }

    /// Code actions (TSK-640, same harness): fetch at the cursor, refuse
    /// command-only picks, apply the edit-bearing one to the buffer.
    func test_codeActions_fetchAtCursor_andApplyEditBearingOnly() async throws {
        let model = try makeModelWithFakeLSP()
        let url = try harness.writeFile("ca.fakelsp", doc)
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)
        seedCursor(model, tabID: id)

        let actions = await model.codeActionsAtCursor()
        XCTAssertEqual(actions.count, 2, "fixture: edit-bearing + command-only")

        let commandOnly = try XCTUnwrap(actions.first { $0.edit.isEmpty })
        XCTAssertFalse(model.applyCodeAction(commandOnly),
                       "command-only actions are refused, never executed")
        XCTAssertEqual(model.editor.editorBuffers[id]?.text, doc,
                       "a refused action must not touch the buffer")

        let editBearing = try XCTUnwrap(actions.first { !$0.edit.isEmpty })
        XCTAssertTrue(model.applyCodeAction(editBearing))
        XCTAssertTrue(model.editor.editorBuffers[id]!.text.hasPrefix("FIXED foo = 1"),
                      "the fixture edit (line 0 chars 0-3 → FIXED) must land")
    }

    /// Edits addressed to a file that is NOT open in any tab are skipped —
    /// never written to disk. Proven through the private apply step's
    /// public effects: the open buffer changes, the skip list records the
    /// foreign uri, and the foreign file's bytes are untouched.
    func test_workspaceEdit_forUnopenedFile_isSkippedNotWrittenToDisk() async throws {
        let model = try makeModelWithFakeLSP()
        let url = try harness.writeFile("open.fakelsp", doc)
        let closedURL = try harness.writeFile("closed.fakelsp", doc)
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id)

        let edits = [LSPTextEdit(
            range: LSPRange(
                start: LSPPosition(line: 0, character: 4),
                end: LSPPosition(line: 0, character: 7)),
            newText: "walrus")]
        let workspaceEdit = [
            url.absoluteString: edits,
            closedURL.absoluteString: edits,
        ]
        model._applyRenameWorkspaceEditForTesting(
            workspaceEdit, dispatchTabID: id,
            dispatchSnapshot: model.editor.editorBuffers[id]!.text)

        XCTAssertTrue(model.editor.editorBuffers[id]!.text.hasPrefix("let walrus = 1"),
            "the OPEN tab's edits apply")
        XCTAssertEqual(model._lastRenameSkippedURIs, [closedURL.absoluteString],
            "the unopened file's uri must be recorded as skipped")
        XCTAssertEqual(try String(contentsOf: closedURL, encoding: .utf8), doc,
            "an unopened file must NEVER be modified on disk")
    }
}
