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

    /// Scan `text` and classify its line endings. O(n) over the scalar view.
    public static func detect(in text: String) -> LineEnding {
        var sawLF = false      // a `\n` not part of a `\r\n`
        var sawCRLF = false    // a `\r\n` pair
        var sawCR = false      // a `\r` not followed by `\n`

        let cr: Unicode.Scalar = "\r"
        let lf: Unicode.Scalar = "\n"
        let scalars = Array(text.unicodeScalars)
        var i = 0
        let n = scalars.count

        while i < n {
            let u = scalars[i]
            if u == cr {
                if i + 1 < n, scalars[i + 1] == lf {
                    sawCRLF = true
                    i += 2
                    continue
                }
                sawCR = true
            } else if u == lf {
                sawLF = true
            }
            i += 1
        }

        let kinds = (sawLF ? 1 : 0) + (sawCRLF ? 1 : 0) + (sawCR ? 1 : 0)
        switch kinds {
        case 0: return .none
        case 1: return sawCRLF ? .crlf : (sawLF ? .lf : .cr)
        default: return .mixed
        }
    }

    /// Convenience: the status-bar label for `text` (e.g. "LF", "CRLF", "—").
    public static func displayString(in text: String) -> String {
        detect(in: text).displayString
    }
}
