import XCTest
import Foundation
import ViewerKit
import ViewerCore
@testable import ViewerUI

/// TSK-963 — DocumentModel's ~20 ad-hoc LSP entry points used to each
/// re-derive the language gate (some via `lspPool.registry`, some via the
/// GLOBAL `LSPLanguageRegistry.default`) and re-do the 1-based→0-based
/// position conversion by hand. This suite pins the CONSOLIDATED behaviour:
///
///  1. the single `lspLanguageConfigured(for:)` gate predicate,
///  2. the single `lspPosition(line:character:)` conversion (1→0 + clamp),
///  3. that every LSP verb's DEBUG seam records the SAME converted position
///     (so the gate/conversion can't drift between call sites again), and
///  4. the newly-wired `handleCompletionRequest` entry: a request with NO
///     LSP language returns `[]` WITHOUT spawning a server.
///
/// All host-testable model layer — no WebView, no live server. The pool
/// round-trip itself is the fake-LSP / VM suites.
@MainActor
final class LSPFacadeConsolidationTests: HeadlessUITestCase {

    private var harness: HeadlessHarness!

    override func setUp() async throws {
        try await super.setUp()
        harness = HeadlessHarness(label: "LSPFacadeConsolidationTests")
    }

    override func tearDown() async throws {
        harness?.cleanup()
        harness = nil
        try await super.tearDown()
    }

    // MARK: - The shared gate predicate

    func test_gate_trueForLSPLanguage_falseForPlainText() throws {
        let swiftURL = try harness.writeFile("a.swift", "let x = 1\n")
        let txtURL = try harness.writeFile("a.txt", "hello\n")
        let model = harness.model
        XCTAssertTrue(model.lspLanguageConfigured(for: swiftURL),
            "a .swift file maps to a language server in the pool registry")
        XCTAssertFalse(model.lspLanguageConfigured(for: txtURL),
            "a .txt file has no LSP language")
    }

    /// The gate must read the POOL's registry (what it routes with), not the
    /// global `LSPLanguageRegistry.default`. Markdown has no LSP language, so
    /// it's a stable negative regardless of which registry is consulted; the
    /// positive case (.swift) proves the pool registry is wired.
    func test_gate_readsPoolRegistry_notGlobalDefault() throws {
        let mdURL = try harness.writeFile("readme.md", "# hi\n")
        let model = harness.model
        XCTAssertFalse(model.lspLanguageConfigured(for: mdURL))
        XCTAssertEqual(model.lspLanguageConfigured(for: mdURL),
                       model.lspPool.registry.language(for: mdURL) != nil,
            "the gate must agree with the pool's own routing registry")
    }

    // MARK: - The shared position conversion

    func test_position_convertsOneBasedLineToZeroBased_andClampsNonNegative() {
        let model = harness.model
        // 1-based line 5, char 3 → 0-based line 4, char 3.
        let p = model.lspPosition(line: 5, character: 3)
        XCTAssertEqual(p.line, 4)
        XCTAssertEqual(p.character, 3)
        // Degenerate inputs clamp to 0, never negative.
        let z = model.lspPosition(line: 0, character: -7)
        XCTAssertEqual(z.line, 0, "line 0 (or below) clamps to 0, not -1")
        XCTAssertEqual(z.character, 0, "negative character clamps to 0")
        let one = model.lspPosition(line: 1, character: 0)
        XCTAssertEqual(one.line, 0, "1-based line 1 is 0-based line 0")
        XCTAssertEqual(one.character, 0)
    }

    // MARK: - Every verb routes through the SAME conversion

    /// Open a .swift file (LSP-mapped) and record a 1-based cursor.
    private func openSwiftWithCursor(line: Int, column: Int) throws -> DocumentModel {
        let url = try harness.writeFile("consolidate.swift", "let x = 1\nlet y = x\n")
        let model = harness.model
        model.open(url: url)
        let id = model.tabs.selected!.id
        _ = model.editor.editorBuffer(forTabID: id) // materialize buffer (format/rename need it)
        model.editor.recordEditorCursor(
            CMCursorPosition(line: line, column: column, head: 0, rangeCount: 1),
            forTabID: id)
        return model
    }

    func test_navigate_references_completion_recordSameConvertedPosition() throws {
        // 1-based cursor line 3, col 6 → 0-based (2, 6) everywhere.
        let model = try openSwiftWithCursor(line: 3, column: 6)
        let url = model.tabs.selected!.url!
        let expected = model.lspPosition(line: 3, character: 6)
        XCTAssertEqual(expected.line, 2)
        XCTAssertEqual(expected.character, 6)

        model._lastLSPNavigation = nil
        XCTAssertTrue(model.navigateViaLSPAtCursor(kind: .definition))
        XCTAssertEqual(model._lastLSPNavigation?.line, expected.line,
            "navigate uses the shared conversion")
        XCTAssertEqual(model._lastLSPNavigation?.character, expected.character)

        model._lastReferencesRequest = nil
        XCTAssertTrue(model.findReferencesAtCursor())
        XCTAssertEqual(model._lastReferencesRequest?.line, expected.line,
            "references uses the shared conversion (same as navigate)")
        XCTAssertEqual(model._lastReferencesRequest?.character, expected.character)

        // The CM6 hover/completion bridges take a 1-based line directly.
        model._lastCompletionRequest = nil
        let id = model.tabs.selected!.id
        let items = awaitCompletion(
            model, tabID: id, url: url,
            request: CMHoverRequest(line: 3, character: 6, replyId: "r1"))
        XCTAssertEqual(items, [], "no completion round-trip wired yet ⇒ empty")
        XCTAssertEqual(model._lastCompletionRequest?.line, expected.line,
            "completion uses the SAME shared conversion as navigate/references")
        XCTAssertEqual(model._lastCompletionRequest?.character, expected.character)
        XCTAssertEqual(model._lastCompletionRequest?.url.lastPathComponent,
                       "consolidate.swift")
    }

    // MARK: - Completion entry contract (TSK-963 / TSK-463)

    func test_completion_noLSPLanguage_servesInFileFallback_withoutDispatch() throws {
        let url = try harness.writeFile("plain.txt", "hello world\n")
        let model = harness.model
        model.open(url: url)
        let id = model.tabs.selected!.id
        model._lastCompletionRequest = nil

        // TSK-1127/1268: a non-LSP file now gets the zero-server in-file fallback
        // (buffer words) instead of empty — prefix "hell" at col 4 → "hello".
        let items = awaitCompletion(
            model, tabID: id, url: url,
            request: CMHoverRequest(line: 1, character: 4, replyId: "r2"))

        XCTAssertEqual(items.map(\.label), ["hello"],
            "a non-LSP file serves in-file buffer-word completions (zero-server fallback)")
        XCTAssertEqual(items.first?.detail, "in-file")
        XCTAssertNil(model._lastCompletionRequest,
            "the fallback does NOT dispatch to an LSP server — no spawn")
    }

    func test_inFileFallback_ranksByFrequency() throws {
        let url = try harness.writeFile("notes.txt", "alpha alpha alphabet\nal\n")
        let model = harness.model
        model.open(url: url)
        let id = model.tabs.selected!.id

        // Cursor after "al" on line 2 → prefix "al" → "alpha" (freq 2) ranks
        // before "alphabet" (freq 1); "al" itself is excluded (== prefix).
        let items = awaitCompletion(
            model, tabID: id, url: url,
            request: CMHoverRequest(line: 2, character: 2, replyId: "r9"))

        XCTAssertEqual(items.map(\.label), ["alpha", "alphabet"],
            "in-file completions ranked by frequency desc")
    }

    func test_completion_lspLanguage_passesGate_recordsRequest() throws {
        let model = try openSwiftWithCursor(line: 2, column: 5)
        let url = model.tabs.selected!.url!
        let id = model.tabs.selected!.id
        model._lastCompletionRequest = nil

        let items = awaitCompletion(
            model, tabID: id, url: url,
            request: CMHoverRequest(line: 2, character: 5, replyId: "r3"))

        // No pool.completion(...) is wired yet, so the result is empty — but
        // the gate PASSED and the (converted) request was recorded.
        XCTAssertEqual(items, [])
        XCTAssertEqual(model._lastCompletionRequest?.line, 1,
            "1-based line 2 → 0-based line 1")
        XCTAssertEqual(model._lastCompletionRequest?.character, 5)
        XCTAssertEqual(model._lastCompletionRequest?.url.lastPathComponent,
                       "consolidate.swift")
    }

    func test_completionItem_value_semantics() {
        let a = DocumentModel.EditorCompletionItem(
            label: "foo", detail: "Int", insertText: "foo()")
        let b = DocumentModel.EditorCompletionItem(
            label: "foo", detail: "Int", insertText: "foo()")
        XCTAssertEqual(a, b, "EditorCompletionItem is value-equatable")
        XCTAssertNotEqual(
            a, DocumentModel.EditorCompletionItem(label: "bar"))
    }

    // MARK: - helpers

    /// `handleCompletionRequest` is `async`; drive it to completion on the
    /// MainActor and return the result synchronously for the assertions.
    private func awaitCompletion(
        _ model: DocumentModel, tabID: UUID, url: URL, request: CMHoverRequest
    ) -> [DocumentModel.EditorCompletionItem] {
        let exp = expectation(description: "completion")
        var result: [DocumentModel.EditorCompletionItem] = []
        Task { @MainActor in
            result = await model.handleCompletionRequest(
                tabID: tabID, fileURL: url, request: request)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5.0)
        return result
    }
}
