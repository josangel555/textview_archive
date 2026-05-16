import Foundation

/// Generates `[HighlightRun]`s for unified-diff text. We don't have a
/// `diff` TreeSitter grammar (and don't want to vendor one for what's
/// a line-prefix scan); a hand-rolled per-line walk is faster and the
/// output is deterministic.
///
/// Line classification:
///   `diff --git` / `index ` / `--- ` / `+++ `  → file headers (heading)
///   `@@ … @@`                                  → hunk header (comment)
///   `+…`  (any line starting `+`)              → added (string — green)
///   `-…`  (any line starting `-`)              → removed (number — red-ish)
///   anything else                              → no highlight (context)
///
/// `range` units are UTF-16 offsets (NSRange), matching what the
/// rest of the highlight pipeline expects.
public enum DiffHighlighter {

    public static func highlight(_ text: String) -> [HighlightRun] {
        let ns = text as NSString
        var runs: [HighlightRun] = []
        var lineStart = 0
        while lineStart < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            // Trim trailing newline for kind decisions, keep full
            // range in the run so the color spans the whole row.
            var lineContent = lineRange
            if lineContent.length > 0,
               ns.character(at: lineContent.location + lineContent.length - 1) == 0x0A {
                lineContent.length -= 1
                // Also drop \r if present (CRLF).
                if lineContent.length > 0,
                   ns.character(at: lineContent.location + lineContent.length - 1) == 0x0D {
                    lineContent.length -= 1
                }
            }
            guard lineContent.length > 0 else {
                lineStart = lineRange.location + lineRange.length
                continue
            }
            let first = ns.character(at: lineContent.location)
            // Classify.
            let kind: TokenKind?
            switch first {
            case 0x40 /* '@' */:
                // @@ -1,3 +1,3 @@ context
                kind = .comment
            case 0x2B /* '+' */:
                // `+++ file` is a file header, not an added line.
                if lineContent.length >= 3,
                   ns.character(at: lineContent.location + 1) == 0x2B,
                   ns.character(at: lineContent.location + 2) == 0x2B {
                    kind = .heading
                } else {
                    kind = .string
                }
            case 0x2D /* '-' */:
                // `--- file` is a file header.
                if lineContent.length >= 3,
                   ns.character(at: lineContent.location + 1) == 0x2D,
                   ns.character(at: lineContent.location + 2) == 0x2D {
                    kind = .heading
                } else {
                    kind = .number
                }
            case 0x64 /* 'd' */:
                // `diff --git …`
                let prefix = ns.substring(with: NSRange(
                    location: lineContent.location,
                    length: min(8, lineContent.length)
                ))
                kind = prefix.hasPrefix("diff ") ? .heading : nil
            case 0x69 /* 'i' */:
                let prefix = ns.substring(with: NSRange(
                    location: lineContent.location,
                    length: min(6, lineContent.length)
                ))
                kind = prefix.hasPrefix("index ") ? .heading : nil
            default:
                kind = nil
            }
            if let k = kind {
                runs.append(HighlightRun(range: lineContent, kind: k))
            }
            lineStart = lineRange.location + lineRange.length
        }
        return runs
    }
}
