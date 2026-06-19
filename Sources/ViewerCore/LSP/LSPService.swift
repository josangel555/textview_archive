import Foundation

/// Thin facade over `LSPPool` that centralizes the two things every LSP
/// call site repeats today: the **1-based editor position → 0-based LSP
/// position** conversion, and the **`registry.language(for:)` gate** that
/// decides whether a file is LSP-eligible at all.
///
/// Motivation (TSK-963, plan §2.5(3) / §4(d)): `DocumentModel` hand-rolls
/// both of these at ~a dozen call sites — `max(0, line - 1)` here,
/// `lspPool.registry.language(for:) != nil` there — so a single
/// off-by-one or a gate that drifts out of sync silently corrupts every
/// navigation/format/rename request. This facade owns the conversion + gate
/// ONCE so the call sites become a single keyed call.
///
/// Positioning contract (the conversion this facade centralizes):
///   • Editor cursors are **1-based line, 0-based character** (CodeMirror 6:
///     line numbers start at 1, columns at 0).
///   • LSP positions are **0-based line, 0-based character**
///     ([LSP 3.17 §Position]).
/// So the conversion is `line - 1` (floored at 0) and `character` unchanged.
/// `LSPServicePosition.lsp(fromEditorLine:character:)` is the single source
/// of truth; it is pure and host-testable.
///
/// Scope (deliberate): this is the FACADE + the conversion/gate helpers
/// only. Migrating `DocumentModel`'s call sites onto it is slice (e); this
/// slice does not touch `DocumentModel`. The facade is `Sendable` (it holds
/// only the `Sendable` `LSPPool` actor) so it can be shared freely.
///
/// Threading: every request method is `async` and forwards to the pool's
/// own actor-isolated, telemetry-recording entry points — no new
/// concurrency surface is introduced.
public struct LSPService: Sendable {

    /// The process pool every request routes through. The facade reuses the
    /// pool's `registry` for the language gate so the gate and the routing
    /// consult the SAME registry (matters for the fake-server e2e, which
    /// injects a custom registry — TSK-627).
    public let pool: LSPPool

    public init(pool: LSPPool) {
        self.pool = pool
    }

    // MARK: - Position conversion (pure, host-testable)

    /// The single 1-based-editor → 0-based-LSP conversion. Floors the line
    /// at 0 so a malformed `0` (or negative) editor line can never produce a
    /// negative LSP line; `character` is already 0-based in the editor so it
    /// passes through, floored at 0 for the same defensive reason.
    public static func lspPosition(
        fromEditorLine line: Int, character: Int
    ) -> LSPPosition {
        LSPPosition(line: max(0, line - 1), character: max(0, character))
    }

    /// Inverse: 0-based LSP line → 1-based editor line (character stays
    /// 0-based). The complement of `lspPosition(fromEditorLine:character:)`,
    /// used when mapping a server result location back to an editor jump
    /// target. Centralized here so the round-trip is provably symmetric.
    public static func editorLine(fromLSPLine line: Int) -> Int {
        line + 1
    }

    // MARK: - Language gate (pure, host-testable)

    /// Whether the pool's registry knows how to drive an LSP for `fileURL`
    /// (i.e. the extension maps to a registered language). This is the SAME
    /// predicate the request methods gate on, surfaced for callers that need
    /// to grey a menu item / refuse a command before issuing a request.
    public func canServe(_ fileURL: URL) -> Bool {
        pool.registry.language(for: fileURL) != nil
    }

    // MARK: - Single-location go-to requests
    //
    // Each takes EDITOR coordinates (1-based line, 0-based character),
    // converts ONCE via `lspPosition(...)`, gates on the language, and
    // forwards to the pool. Returns `[]` when the file has no LSP language —
    // the honest no-op contract every DocumentModel call site already wants.

    public func definition(
        url: URL, editorLine: Int, character: Int,
        token: LSPCancellationToken? = nil
    ) async throws -> [LSPLocation] {
        guard canServe(url) else { return [] }
        let pos = Self.lspPosition(fromEditorLine: editorLine, character: character)
        return try await pool.definition(
            fileURL: url, line: pos.line, character: pos.character, token: token)
    }

    public func declaration(
        url: URL, editorLine: Int, character: Int,
        token: LSPCancellationToken? = nil
    ) async throws -> [LSPLocation] {
        guard canServe(url) else { return [] }
        let pos = Self.lspPosition(fromEditorLine: editorLine, character: character)
        return try await pool.declaration(
            fileURL: url, line: pos.line, character: pos.character, token: token)
    }

    public func typeDefinition(
        url: URL, editorLine: Int, character: Int,
        token: LSPCancellationToken? = nil
    ) async throws -> [LSPLocation] {
        guard canServe(url) else { return [] }
        let pos = Self.lspPosition(fromEditorLine: editorLine, character: character)
        return try await pool.typeDefinition(
            fileURL: url, line: pos.line, character: pos.character, token: token)
    }

    public func implementation(
        url: URL, editorLine: Int, character: Int,
        token: LSPCancellationToken? = nil
    ) async throws -> [LSPLocation] {
        guard canServe(url) else { return [] }
        let pos = Self.lspPosition(fromEditorLine: editorLine, character: character)
        return try await pool.implementation(
            fileURL: url, line: pos.line, character: pos.character, token: token)
    }

    public func references(
        url: URL, editorLine: Int, character: Int,
        includeDeclaration: Bool = true,
        token: LSPCancellationToken? = nil
    ) async throws -> [LSPLocation] {
        guard canServe(url) else { return [] }
        let pos = Self.lspPosition(fromEditorLine: editorLine, character: character)
        return try await pool.references(
            fileURL: url, line: pos.line, character: pos.character,
            includeDeclaration: includeDeclaration, token: token)
    }

    // MARK: - Hover

    public func hover(
        url: URL, editorLine: Int, character: Int,
        token: LSPCancellationToken? = nil
    ) async throws -> LSPHover? {
        guard canServe(url) else { return nil }
        let pos = Self.lspPosition(fromEditorLine: editorLine, character: character)
        return try await pool.hover(
            fileURL: url, line: pos.line, character: pos.character, token: token)
    }

    // MARK: - Whole-document edits

    /// `textDocument/formatting` — whole-document, no position. Gated on the
    /// language; `[]` when the file has no LSP.
    public func format(
        url: URL, options: LSPFormattingOptions = LSPFormattingOptions(),
        token: LSPCancellationToken? = nil
    ) async throws -> [LSPTextEdit] {
        guard canServe(url) else { return [] }
        return try await pool.formatting(fileURL: url, options: options, token: token)
    }

    /// `textDocument/rename` — uri → edits. Gated on the language; an empty
    /// dictionary when the file has no LSP.
    public func rename(
        url: URL, editorLine: Int, character: Int, newName: String,
        token: LSPCancellationToken? = nil
    ) async throws -> [String: [LSPTextEdit]] {
        guard canServe(url) else { return [:] }
        let pos = Self.lspPosition(fromEditorLine: editorLine, character: character)
        return try await pool.rename(
            fileURL: url, line: pos.line, character: pos.character,
            newName: newName, token: token)
    }
}
