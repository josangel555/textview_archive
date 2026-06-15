import Foundation

/// Conservative content-type detection for unknown / misnamed files (TSK-901):
/// a `.txt` that actually holds JSON, or a `.dat` that's really CSV, should be
/// able to use the JSON / CSV tools. Detection is deliberately STRICT — a false
/// positive (treating prose as data) is worse than a miss, since the worst case
/// of a miss is just a tool staying menu-disabled. Pure + host-testable; callers
/// cap the input size (a full JSON parse on a huge file would be wasteful).
public enum ContentTypeSniffer {

    public enum Kind: String, Equatable, Sendable {
        case json
        case csv
    }

    /// Best-effort content kind, or nil for prose / ambiguous / unrecognized.
    public static func detect(_ text: String) -> Kind? {
        if looksLikeJSON(text) { return .json }
        if looksLikeCSV(text) { return .csv }
        return nil
    }

    /// True when `text` is valid JSON (leading `{`/`[` AND it actually parses).
    /// The real parse is what keeps this strict — a code file or `[TODO]` note
    /// that merely starts with a bracket is rejected.
    public static func looksLikeJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return false }
        guard let data = trimmed.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    /// True when the first few non-empty lines share a CONSISTENT delimiter
    /// (`,` or `\t`) that splits each into the same field count ≥ 2. The
    /// consistency requirement is what rejects prose that merely contains commas
    /// (its per-line comma counts vary). Needs ≥ 2 data rows.
    public static func looksLikeCSV(_ text: String) -> Bool {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(5)
        guard lines.count >= 2 else { return false }
        for delim: Character in [",", "\t"] {
            let counts = lines.map {
                $0.split(separator: delim, omittingEmptySubsequences: false).count
            }
            if let first = counts.first, first >= 2, counts.allSatisfy({ $0 == first }) {
                return true
            }
        }
        return false
    }
}
