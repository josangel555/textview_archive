import Foundation

/// Whitespace-cleanup transforms for the robust plain-text editor (TSK-675),
/// applied to a whole FILE — so unlike `TextTools.trimTrailingWhitespace` (a
/// clipboard tool that rejoins with `\n`), these PRESERVE each line's existing
/// terminator (LF/CRLF/CR) and never normalize line endings as a side effect
/// (that's `LineEndingConverter`'s job). Pure + scalar-walk (the `\r\n` grapheme
/// must split correctly — the recurring CRLF trap). SwiftUI-free.
public enum TextCleanup {

    /// Strip trailing spaces/tabs from every line, leaving each line's terminator
    /// (and all non-trailing content) byte-for-byte intact.
    public static func trimTrailingWhitespace(_ text: String) -> String {
        let cr: Unicode.Scalar = "\r"
        let lf: Unicode.Scalar = "\n"
        let sp: Unicode.Scalar = " "
        let tab: Unicode.Scalar = "\t"

        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        var line = [Unicode.Scalar]()

        func flushLine() {
            var end = line.count
            while end > 0, line[end - 1] == sp || line[end - 1] == tab { end -= 1 }
            out.append(contentsOf: line[0..<end])
            line.removeAll(keepingCapacity: true)
        }

        let scalars = text.unicodeScalars
        var idx = scalars.startIndex
        while idx < scalars.endIndex {
            let u = scalars[idx]
            if u == cr {
                flushLine()
                let next = scalars.index(after: idx)
                if next < scalars.endIndex, scalars[next] == lf {
                    out.append(cr); out.append(lf)
                    idx = scalars.index(after: next)
                    continue
                }
                out.append(cr)
            } else if u == lf {
                flushLine()
                out.append(lf)
            } else {
                line.append(u)
                idx = scalars.index(after: idx)
                continue
            }
            idx = scalars.index(after: idx)
        }
        flushLine()   // the final line (no trailing terminator)
        return String(out)
    }

    /// Ensure the text ends with exactly one line terminator (of `ending`),
    /// appending one only when the last scalar isn't already `\n`/`\r`. An empty
    /// file is left empty (no terminator added to nothing).
    public static func ensureFinalNewline(_ text: String, using ending: LineEnding = .lf) -> String {
        guard !text.isEmpty else { return text }
        if let last = text.unicodeScalars.last, last == "\n" || last == "\r" { return text }
        let terminator = LineEndingConverter.terminator(for: ending) ?? "\n"
        return text + terminator
    }
}
