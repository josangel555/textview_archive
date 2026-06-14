import Foundation

/// Word / character / line counts for the active text document (TSK-675, robust
/// plain-text editing) — the data a "Document Statistics" / word-count panel
/// shows, the way Word/Pages/Notepad++ do. Pure + host-testable; the on-screen
/// presentation (menu → panel) is the render tail.
public struct DocumentStats: Equatable, Sendable {
    /// User-perceived characters (grapheme clusters), including whitespace.
    public let characters: Int
    /// Characters excluding any Unicode whitespace.
    public let charactersNoWhitespace: Int
    /// Whitespace-separated tokens.
    public let words: Int
    /// Lines: terminator-separated, with a final un-terminated line counted; an
    /// empty document is 0 lines.
    public let lines: Int

    public init(characters: Int, charactersNoWhitespace: Int, words: Int, lines: Int) {
        self.characters = characters
        self.charactersNoWhitespace = charactersNoWhitespace
        self.words = words
        self.lines = lines
    }

    public static func compute(_ text: String) -> DocumentStats {
        let characters = text.count
        let charactersNoWhitespace = text.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }
        let words = text.split(whereSeparator: { $0.isWhitespace }).count

        // Line count, CRLF-aware (a `\r\n` pair is ONE break, not two).
        let cr: Unicode.Scalar = "\r"
        let lf: Unicode.Scalar = "\n"
        let scalars = text.unicodeScalars
        var breaks = 0
        var lastWasBreak = false
        var idx = scalars.startIndex
        while idx < scalars.endIndex {
            let u = scalars[idx]
            if u == cr {
                let next = scalars.index(after: idx)
                if next < scalars.endIndex, scalars[next] == lf {
                    breaks += 1; lastWasBreak = true
                    idx = scalars.index(after: next); continue
                }
                breaks += 1; lastWasBreak = true
            } else if u == lf {
                breaks += 1; lastWasBreak = true
            } else {
                lastWasBreak = false
            }
            idx = scalars.index(after: idx)
        }
        let lines = text.isEmpty ? 0 : breaks + (lastWasBreak ? 0 : 1)

        return DocumentStats(
            characters: characters, charactersNoWhitespace: charactersNoWhitespace,
            words: words, lines: lines)
    }

    /// A compact one-line summary for a status chip / alert.
    public var summary: String {
        "\(lines) lines · \(words) words · \(characters) characters"
    }
}
