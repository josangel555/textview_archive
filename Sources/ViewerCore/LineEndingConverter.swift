import Foundation

/// Normalizes a text's line endings to a single convention (TSK-675, robust
/// plain-text editing) — the write side of `LineEndingDetector`'s read side,
/// the way Notepad++/VS Code offer "Change End-Of-Line Sequence". Pure +
/// dependency-free.
///
/// Walks the **unicode-scalar** view (NOT the `Character` view: `"\r\n"` is a
/// SINGLE grapheme, so a grapheme walk can't split a CRLF pair — the same trap
/// `LineEndingDetector`/`IndentDetector` document). Every `\r\n`, lone `\r`, and
/// lone `\n` is replaced by the target terminator; all other scalars pass
/// through verbatim. A file with no trailing newline keeps none (no terminator
/// is appended), so conversion never changes content, only the break bytes.
public enum LineEndingConverter {

    /// The terminator string for a normalizable target (`.mixed`/`.none` are not
    /// valid targets and yield `nil`).
    static func terminator(for target: LineEnding) -> String? {
        switch target {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        case .cr: return "\r"
        case .mixed, .none: return nil
        }
    }

    /// Return `text` with every line break rewritten to `target`. Returns the
    /// input unchanged for a non-normalizable target (`.mixed`/`.none`).
    public static func convert(_ text: String, to target: LineEnding) -> String {
        guard let terminator = terminator(for: target) else { return text }
        let cr: Unicode.Scalar = "\r"
        let lf: Unicode.Scalar = "\n"
        let scalars = text.unicodeScalars
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)
        let term = terminator.unicodeScalars

        var idx = scalars.startIndex
        while idx < scalars.endIndex {
            let u = scalars[idx]
            if u == cr {
                let next = scalars.index(after: idx)
                if next < scalars.endIndex, scalars[next] == lf {
                    out.append(contentsOf: term)        // \r\n
                    idx = scalars.index(after: next)
                    continue
                }
                out.append(contentsOf: term)            // lone \r
            } else if u == lf {
                out.append(contentsOf: term)            // lone \n
            } else {
                out.append(u)
            }
            idx = scalars.index(after: idx)
        }
        return String(out)
    }
}
