import Foundation
import ViewerCore

// CM6 LSP completion request/response bridge + resolution engine (TSK-1110 SRP
// slice; TSK-1136/463) — JS posts a completion request; we resolve via
// `handleCompletionRequest` (LSP `textDocument/completion` round-trip when a
// language server is configured, else the in-file buffer-word fallback) and reply
// through the CM6 bridge so the editor's autocomplete source resolves. The
// `_lastCompletionRequest` DEBUG probe + the shared `lspPosition`/
// `lspLanguageConfigured` helpers stay on DocumentModel. Behavior-preserving move.
extension DocumentModel {

    /// JS posted a completion request (TSK-1136). Resolve asynchronously via the
    /// existing `handleCompletionRequest` seam (LSP when a language server is
    /// configured, else the in-file buffer-word fallback) and reply through the
    /// bridge so the CM6 autocomplete source resolves. Empty items → no popup.
    public func respondToEditorCompletion(
        tabID: UUID, fileURL: URL, request: CMHoverRequest
    ) {
        Task { [weak self] in
            guard let self = self else { return }
            let items = await self.handleCompletionRequest(
                tabID: tabID, fileURL: fileURL, request: request)
            await MainActor.run {
                self.sendEditorCompletionResponse(
                    replyId: request.replyId, items: items)
            }
        }
    }

    private func sendEditorCompletionResponse(
        replyId: String, items: [EditorCompletionItem]
    ) {
        guard let webView = CodeMirrorEditorRegistry.shared.current() else { return }
        let cmItems = items.map {
            CMCompletionItem(label: $0.label, detail: $0.detail, insertText: $0.insertText)
        }
        let json = CMBridgeCodec.encodeOutboundJSON(
            .completionResponse(replyId: replyId, items: cmItems))
        webView.evaluateJavaScript("window.cmDispatch(\(json));")
    }

    /// Map LSP completion items to editor items, ordered by the server's `sortText`
    /// (the LSP-prescribed presentation order) with `label` as a stable tiebreak, and
    /// committing `insert` (the spec-resolved text). Pure + `nonisolated` → fully
    /// host-testable without a live server or the MainActor (TSK-1136).
    nonisolated static func editorCompletions(
        from lspItems: [LSPCompletionItem]
    ) -> [EditorCompletionItem] {
        lspItems
            .sorted { ($0.sortText, $0.label) < ($1.sortText, $1.label) }
            .map { EditorCompletionItem(label: $0.label, detail: $0.detail, insertText: $0.insert) }
    }

    /// Resolve completions at a CM6 editor position. Returns `[]` immediately
    /// (no Task, no pool touch, no server spawn) when the file has no LSP
    /// language — the same honest gate as hover/go-to. When a language IS
    /// configured it records the (converted) request and delegates to the
    /// `requestCompletions` seam, which the pool round-trip will fill in.
    /// `async` so the future pool call slots in without changing callers.
    @discardableResult
    public func handleCompletionRequest(
        tabID: UUID, fileURL: URL, request: CMHoverRequest
    ) async -> [EditorCompletionItem] {
        let (lspLine, lspChar) = lspPosition(
            line: request.line, character: request.character)
        // TSK-1127: zero-server fallback. With NO LSP language configured, serve
        // in-file buffer-word completions from the live editor buffer (the
        // vim-Ctrl-N class every editor ships) instead of replying empty — and
        // WITHOUT any server spawn/dispatch. `InFileCompletion` walks back over the
        // identifier prefix ending at the 0-based column itself. (Was the orphaned
        // built-but-unwired core flagged in TSK-1268; this is the wiring slice.)
        guard lspLanguageConfigured(for: fileURL) else {
            guard let text = editorBuffer(forTabID: tabID)?.text else { return [] }
            return InFileCompletion
                .completions(in: text, line: lspLine, column: lspChar)
                .map { EditorCompletionItem(label: $0, detail: "in-file", insertText: $0) }
        }
        #if DEBUG
        _lastCompletionRequest = (fileURL, lspLine, lspChar)
        #endif
        return await requestCompletions(
            fileURL: fileURL, line: lspLine, character: lspChar)
    }

    /// The pool seam for completion (0-based LSP position). Invokes the LSP
    /// `textDocument/completion` round-trip (the wire layer landed in TSK-463) via
    /// `LSPPool.completion` and maps the result to editor items (TSK-1136). The caller
    /// already gated on a configured LSP language, so this never spawns a server for a
    /// non-LSP file. A server error or cancellation degrades honestly to "no
    /// completions". The CM6 autocomplete extension that drives this seam (and a
    /// no-LSP in-file/buffer-word fallback source) are the remaining render-side slice.
    private func requestCompletions(
        fileURL: URL, line: Int, character: Int
    ) async -> [EditorCompletionItem] {
        do {
            let list = try await lspPool.completion(
                fileURL: fileURL, line: line, character: character)
            return Self.editorCompletions(from: list.items)
        } catch {
            return []
        }
    }
}
