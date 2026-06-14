import Foundation

/// One in-file text match: a 1-based line number and the full line text.
public struct InFileMatch: Equatable, Sendable, Identifiable {
    public let lineNumber: Int
    public let line: String
    public var id: Int { lineNumber }

    public init(lineNumber: Int, line: String) {
        self.lineNumber = lineNumber
        self.line = line
    }
}

/// Pure in-file text search backing the unified palette's `#` operator
/// (TSK-727): scan the active file's text for a literal substring and return
/// the matching lines + their 1-based numbers, so the palette can list them and
/// jump on select. Host-testable; the palette result list / jump render is the
/// view tail.
public enum InFileSearch {

    /// Case-insensitive literal substring scan over `text`. Lines are counted
    /// 1-based via Foundation's `enumerateLines`, which terminates on LF, CRLF,
    /// AND bare CR and strips the terminator — so CRLF counts as one line
    /// (matching the editor's line numbering so jump-to-line lands correctly),
    /// without the `\r\n`-is-one-Swift-grapheme trap a `split(separator: "\n")`
    /// would hit. Empty/blank query → no matches. `limit` caps the result count.
    public static func matches(in text: String, query: String, limit: Int = 500) -> [InFileMatch] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, limit > 0 else { return [] }
        var out: [InFileMatch] = []
        var lineNo = 0
        text.enumerateLines { line, stop in
            lineNo += 1
            if line.range(of: q, options: .caseInsensitive) != nil {
                out.append(InFileMatch(lineNumber: lineNo, line: line))
                if out.count >= limit { stop = true }
            }
        }
        return out
    }
}
