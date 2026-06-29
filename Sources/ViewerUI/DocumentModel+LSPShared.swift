import Foundation

// Shared LSP gate + position conversion (TSK-1110 SRP slice; TSK-963) — the
// single source of truth for "is a server configured for this url" and the
// CM6→LSP position conversion, used by every LSP entry point (hover, go-to,
// completion, the active-file gates). Pure helpers over lspPool. Behavior-
// preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// True when the pool has a language server configured for `url`. THE gate
    /// for every LSP feature (hover, go-to, references, format, rename, code
    /// actions, completion). Uses the POOL's registry — the one it actually
    /// routes with — not `LSPLanguageRegistry.default`.
    func lspLanguageConfigured(for url: URL) -> Bool {
        lspPool.registry.language(for: url) != nil
    }

    /// Convert a CM6 editor position (1-based line, 0-based UTF-16 character)
    /// to the LSP wire position (0-based line + character), clamped non-negative.
    /// The pool re-encodes the character offset if the server negotiated a
    /// non-UTF-16 position encoding.
    func lspPosition(line: Int, character: Int) -> (line: Int, character: Int) {
        (line: max(0, line - 1), character: max(0, character))
    }
}
