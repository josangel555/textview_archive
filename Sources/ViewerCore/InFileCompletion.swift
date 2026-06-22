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
}
