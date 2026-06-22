import Foundation

/// TSK-1127 (slice 1) — the zero-server fallback completion core: when no LSP
/// server is installed for a file's language, offer instant in-file word/identifier
/// completions drawn from the buffer itself (the editor-fallback every code editor
/// ships, e.g. vim Ctrl-N). PURE (text in, ranked candidates out) so it is fully
/// host-testable; wiring it into the completion provider when the LSP pool has no
/// server, and the optional TreeSitter-symbol refinement, are the integration tail.
public enum InFileCompletion {

    /// Unique identifier tokens in `text` that start with `prefix` (excluding
    /// `prefix` itself), ranked by frequency (desc), then length (asc, shorter
    /// completions first), then alphabetically — a stable, deterministic order.
    /// Identifiers are `[A-Za-z_][A-Za-z0-9_]*` (a digit-leading run is ignored).
    /// Case-sensitive prefix match. Empty prefix → no suggestions.
    public static func completions(in text: String, prefix: String, limit: Int = 50) -> [String] {
        guard !prefix.isEmpty, limit > 0 else { return [] }

        var freq: [String: Int] = [:]
        var current = ""
        func flush() {
            if let first = current.first, first.isLetter || first == "_" {
                freq[current, default: 0] += 1
            }
            current = ""
        }
        for ch in text {
            if ch == "_" || ch.isLetter || ch.isNumber {
                current.append(ch)
            } else {
                flush()
            }
        }
        flush()

        let ranked = freq
            .filter { $0.key.hasPrefix(prefix) && $0.key != prefix }
            .sorted { a, b in
                if a.value != b.value { return a.value > b.value }          // frequency desc
                if a.key.count != b.key.count { return a.key.count < b.key.count } // length asc
                return a.key < b.key                                         // alphabetical
            }
        return ranked.prefix(limit).map(\.key)
    }

    /// Cursor-aware entry point the editor wiring uses: completions for the
    /// identifier prefix ending at `column` (0-based, in UTF-16-agnostic Character
    /// units) on 0-based `line` of `text`. Walks back from the column over the
    /// trailing `[A-Za-z0-9_]` run; if that run doesn't begin with a letter/`_`
    /// (e.g. the cursor follows whitespace, punctuation, or a digit-led token)
    /// there is no prefix and no suggestions. Out-of-range line/column → none.
    public static func completions(
        in text: String, line: Int, column: Int, limit: Int = 50
    ) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard line >= 0, line < lines.count else { return [] }
        let chars = Array(lines[line])
        guard column >= 0, column <= chars.count else { return [] }
        var start = column
        while start > 0 {
            let c = chars[start - 1]
            if c == "_" || c.isLetter || c.isNumber { start -= 1 } else { break }
        }
        let prefixChars = chars[start..<column]
        guard let first = prefixChars.first, first.isLetter || first == "_" else { return [] }
        return completions(in: text, prefix: String(prefixChars), limit: limit)
    }
}
