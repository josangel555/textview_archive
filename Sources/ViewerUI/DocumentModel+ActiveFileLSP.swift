import Foundation
import ViewerCore

// Active-file LSP queries (TSK-1110 SRP slice; TSK-727) — the "is this file
// analyzed / does it expose symbols" gates plus the Goto-Anything `@`-palette
// code-symbol fetch. All read DocumentModel's LSP coordinators (lspPool /
// lspDiagnostics); no stored state moves. Behavior-preserving move out of
// DocumentModel.swift.
extension DocumentModel {

    /// True when the active file has a registered LSP language yet the
    /// diagnostics store holds no entry for it — i.e. no language server
    /// has analyzed it in this view. Source view never sends the
    /// `didOpen`/`didChange` that triggers `publishDiagnostics` (only the
    /// Editor / Outline paths do), so an empty store for a `.swift` file
    /// open in Source view is "not analyzed here", not a clean bill of
    /// health. The PROBLEMS panel reads this to avoid a falsely-
    /// reassuring "No problems detected." for an un-analyzed file
    /// (UAT LSP-01). Returns false for files with no LSP language (e.g.
    /// `.md`, `.txt`), where the all-clear copy is genuinely correct.
    public var activeFileUnanalyzedByLSP: Bool {
        guard let url = currentURL else { return false }
        guard lspLanguageConfigured(for: url) else { return false }
        return lspDiagnostics.byURL[url] == nil
    }

    /// Whether the active file is a code file with a registered LSP language —
    /// i.e. the Goto-Anything `@` palette can source its symbols from
    /// `textDocument/documentSymbol` (TSK-727). Markdown's `@` mode uses the
    /// heading extractor instead; this gates the code-symbol path only.
    public var activeFileHasLSPSymbols: Bool {
        guard let url = currentURL else { return false }
        return lspPool.registry.language(for: url) != nil
    }

    /// Fetch the active file's LSP `documentSymbol` tree and flatten it into the
    /// palette's `@`-mode jump targets (TSK-727 code-file `@`). Returns `[]` for
    /// a file with no LSP language, no text, or on any LSP failure (the palette
    /// shows its empty-state hint — there's no error surface for "no symbols").
    /// The flatten/rank logic is the host-tested `SymbolJump`; this is the thin
    /// async glue that opens the file with the server and issues the request,
    /// mirroring `LSPOutlineModel.setFile`.
    public func fetchActiveCodeSymbols() async -> [SymbolJump.CodeSymbol] {
        guard let url = currentURL,
              lspPool.registry.language(for: url) != nil,
              let text = activeFileText else { return [] }
        let pool = self.lspPool
        do {
            // Same open→change→request sequence the Outline panel uses so the
            // server reads the file's current text. ensureOpened/didChange
            // no-op when the file isn't tracked / unchanged.
            try await pool.ensureOpened(fileURL: url, text: text)
            try await pool.didChange(fileURL: url, text: text)
            let syms = try await pool.documentSymbol(fileURL: url)
            return SymbolJump.flatten(syms)
        } catch {
            // No UI surface for "LSP unavailable" in the palette — fall back to
            // an empty list, which renders the "no symbols" hint.
            return []
        }
    }
}
