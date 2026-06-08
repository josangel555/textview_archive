import Foundation

/// One TODO-style annotation found in a file.
public struct SourceAnnotation: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case todo  = "TODO"
        case fixme = "FIXME"
        case hack  = "HACK"
        case xxx   = "XXX"
        case note  = "NOTE"
        case bug   = "BUG"
    }
    public let kind: Kind
    /// Text after the marker (and its optional `:`), trimmed. May be empty.
    public let message: String
    /// 1-based line number.
    public let line: Int

    public init(kind: Kind, message: String, line: Int) {
        self.kind = kind
        self.message = message
        self.line = line
    }
}

/// Scans source for the standard uppercase annotation markers so a viewer can
/// offer a navigable "Annotations" / jump-to list (the VS Code TODO-tree idea).
/// Pure + dependency-free, mirroring `MarkdownOutline` / `IndentDetector`.
///
/// Matching: a marker (`TODO`/`FIXME`/`HACK`/`XXX`/`NOTE`/`BUG`) must appear as
/// a WHOLE WORD (boundaries are non-`[A-Za-z0-9_]`), so `TODOS`, `aTODO`, and
/// `methodObj` never match. Case-SENSITIVE uppercase (the convention) to avoid
/// flagging the word "note"/"bug" in prose. The first marker per line wins; the
/// message is the rest of the line after an optional `:` separator, trimmed.
///
/// Language-agnostic by design (it does NOT require the marker to sit inside a
/// comment — the same behavior as editor TODO-tree plugins); a `"TODO"` string
/// literal would match. Good enough for a jump list.
public enum SourceAnnotationScanner {

    public static func scan(_ text: String, maxLines: Int? = nil) -> [SourceAnnotation] {
        var out: [SourceAnnotation] = []

        // Split on the LF *scalar* (CRLF-safe — `"\r\n"` is one grapheme, so a
        // Character-based split would miss it; see MarkdownOutline).
        var lineNo = 0
        var cur = String.UnicodeScalarView()

        func flush(_ scalars: String.UnicodeScalarView) {
            lineNo += 1
            if let cap = maxLines, lineNo > cap { return }
            var line = String(scalars)
            if line.hasSuffix("\r") { line.removeLast() }
            if let ann = annotation(in: line, line: lineNo) { out.append(ann) }
        }

        for u in text.unicodeScalars {
            if u == "\n" { flush(cur); cur = String.UnicodeScalarView() }
            else { cur.append(u) }
        }
        flush(cur)

        return out
    }

    // MARK: - per-line

    private static func annotation(in line: String, line lineNo: Int) -> SourceAnnotation? {
        let chars = Array(line)
        let n = chars.count
        guard n > 0 else { return nil }

        var i = 0
        while i < n {
            // Word boundary before the candidate.
            if i > 0, isWordChar(chars[i - 1]) { i += 1; continue }
            for kind in SourceAnnotation.Kind.allCases {
                let marker = Array(kind.rawValue)
                let end = i + marker.count
                guard end <= n, matches(chars, at: i, marker) else { continue }
                // Word boundary after the marker (':' / space / EOL are fine).
                if end < n, isWordChar(chars[end]) { continue }
                let message = extractMessage(chars, from: end)
                return SourceAnnotation(kind: kind, message: message, line: lineNo)
            }
            i += 1
        }
        return nil
    }

    private static func matches(_ chars: [Character], at i: Int, _ marker: [Character]) -> Bool {
        for (k, m) in marker.enumerated() where chars[i + k] != m { return false }
        return true
    }

    private static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    /// The message after the marker: skip surrounding spaces and a single
    /// leading `:` separator, then trim.
    private static func extractMessage(_ chars: [Character], from end: Int) -> String {
        var j = end
        while j < chars.count, chars[j] == " " || chars[j] == "\t" { j += 1 }
        if j < chars.count, chars[j] == ":" { j += 1 }
        let rest = String(chars[j...])
        return rest.trimmingCharacters(in: .whitespaces)
    }
}
