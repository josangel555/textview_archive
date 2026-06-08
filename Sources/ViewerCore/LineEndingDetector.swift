import Foundation

/// Detects the dominant line-ending convention of a text file so the status
/// bar can show it next to the indent chip (TSK-509), the way VS Code shows
/// "LF" / "CRLF". Pure + dependency-free, mirroring `IndentDetector`.
///
/// Classifies by scanning the unicode-scalar view (NOT the `Character` view:
/// `"\r\n"` is a SINGLE grapheme cluster, so a grapheme walk can't see the
/// LF inside a CRLF pair — the same trap `IndentDetector` documents):
///   - `.lf`    — only `\n`
///   - `.crlf`  — only `\r\n`
///   - `.cr`    — only lone `\r` (classic Mac OS)
///   - `.mixed` — more than one of the above present
///   - `.none`  — no line breaks at all (single line / empty)
public enum LineEnding: String, Sendable, Equatable {
    case lf = "LF"
    case crlf = "CRLF"
    case cr = "CR"
    case mixed = "Mixed"
    case none = "—"

    /// Status-bar label. `.none` shows the em-dash placeholder, matching the
    /// IndentDetector "—" convention for "nothing to report".
    public var displayString: String { rawValue }
}

public enum LineEndingDetector {

    /// Scan `text` and classify its line endings. Iterates the scalar view by
    /// index (no full-array materialization). Pass `sampleScalars` to bound the
    /// scan to a prefix — the status bar uses this so a multi-MB file doesn't
    /// pay an O(N) scan on the body hot path (the classification of a prefix is
    /// representative; a CRLF pair straddling the bound is counted as the pair).
    public static func detect(in text: String, sampleScalars: Int? = nil) -> LineEnding {
        var sawLF = false      // a `\n` not part of a `\r\n`
        var sawCRLF = false    // a `\r\n` pair
        var sawCR = false      // a `\r` not followed by `\n`

        let cr: Unicode.Scalar = "\r"
        let lf: Unicode.Scalar = "\n"
        let scalars = text.unicodeScalars
        var idx = scalars.startIndex
        var checked = 0

        while idx < scalars.endIndex {
            if let cap = sampleScalars, checked >= cap { break }
            let u = scalars[idx]
            if u == cr {
                let next = scalars.index(after: idx)
                if next < scalars.endIndex, scalars[next] == lf {
                    sawCRLF = true
                    idx = scalars.index(after: next)
                    checked += 2
                    continue
                }
                sawCR = true
            } else if u == lf {
                sawLF = true
            }
            idx = scalars.index(after: idx)
            checked += 1
        }

        let kinds = (sawLF ? 1 : 0) + (sawCRLF ? 1 : 0) + (sawCR ? 1 : 0)
        switch kinds {
        case 0: return .none
        case 1: return sawCRLF ? .crlf : (sawLF ? .lf : .cr)
        default: return .mixed
        }
    }

    /// Convenience: the status-bar label for `text` (e.g. "LF", "CRLF", "—").
    /// `sampleScalars` bounds the scan as in `detect(in:sampleScalars:)`.
    public static func displayString(in text: String, sampleScalars: Int? = nil) -> String {
        detect(in: text, sampleScalars: sampleScalars).displayString
    }
}
