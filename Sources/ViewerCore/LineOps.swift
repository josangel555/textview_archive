import Foundation

/// Whole-file line operations for the active document (Edit ▸ Lines) — the
/// in-place counterpart to the clipboard line tools. Pure + terminator-aware:
/// the file's dominant line ending (LF/CRLF/CR) and its trailing-newline
/// presence are preserved; content is only reordered/deduped. SwiftUI-free.
public enum LineOps {

    /// Sort lines lexicographically (Swift `String` order).
    public static func sort(_ text: String, ascending: Bool = true) -> String {
        transform(text) { lines in lines.sorted(by: ascending ? (<) : (>)) }
    }

    /// Reverse the order of the lines.
    public static func reverse(_ text: String) -> String {
        transform(text) { $0.reversed() }
    }

    /// Drop duplicate lines, keeping the FIRST occurrence and preserving order.
    public static func removeDuplicates(_ text: String) -> String {
        transform(text) { lines in
            var seen = Set<String>()
            return lines.filter { seen.insert($0).inserted }
        }
    }

    /// Remove blank lines — lines that are empty or whitespace-only.
    public static func removeEmptyLines(_ text: String) -> String {
        transform(text) { lines in
            lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    /// Collapse runs of 2+ consecutive blank lines down to a single blank line.
    public static func collapseBlankLines(_ text: String) -> String {
        transform(text) { lines in
            var out: [String] = []
            var prevBlank = false
            for line in lines {
                let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
                if blank && prevBlank { continue }
                out.append(line)
                prevBlank = blank
            }
            return out
        }
    }

    // MARK: - helpers

    private static func transform(_ text: String, _ op: ([String]) -> [String]) -> String {
        let (lines, ending, trailing) = split(text)
        guard !lines.isEmpty else { return text }
        let result = op(lines)
        return result.joined(separator: ending) + (trailing ? ending : "")
    }

    /// Split into logical lines (terminators stripped) + the dominant ending +
    /// whether the text ends with a terminator. Scalar walk so a `\r\n` pair is
    /// ONE break (the CRLF-grapheme trap), and a lone `\r` is handled.
    private static func split(_ text: String) -> (lines: [String], ending: String, trailing: Bool) {
        let ending: String
        switch LineEndingDetector.detect(in: text) {
        case .crlf: ending = "\r\n"
        case .cr: ending = "\r"
        default: ending = "\n"   // lf / mixed / none
        }
        guard !text.isEmpty else { return ([], ending, false) }
        let trailing = text.unicodeScalars.last == "\n" || text.unicodeScalars.last == "\r"

        let cr: Unicode.Scalar = "\r", lf: Unicode.Scalar = "\n"
        var lines: [String] = []
        var cur = String.UnicodeScalarView()
        let scalars = text.unicodeScalars
        var i = scalars.startIndex
        while i < scalars.endIndex {
            let u = scalars[i]
            if u == cr {
                lines.append(String(cur)); cur = .init()
                let n = scalars.index(after: i)
                i = (n < scalars.endIndex && scalars[n] == lf) ? scalars.index(after: n) : scalars.index(after: i)
            } else if u == lf {
                lines.append(String(cur)); cur = .init(); i = scalars.index(after: i)
            } else {
                cur.append(u); i = scalars.index(after: i)
            }
        }
        if !cur.isEmpty { lines.append(String(cur)) }
        return (lines, ending, trailing)
    }
}
