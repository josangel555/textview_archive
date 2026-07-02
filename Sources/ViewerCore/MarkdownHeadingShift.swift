import Foundation

/// Shift every ATX heading's level by a delta — "Promote Headings" (shallower,
/// fewer `#`) / "Demote Headings" (deeper, more `#`) — for restructuring docs
/// (nesting one under a parent, merging, flattening). Pure + fence-aware +
/// terminator-preserving (LF/CRLF/CR); a CONSUMER-style transform, not the
/// Rust-ported markdown→HTML engine, so §2.5-safe. ATX only (setext underlines
/// are left alone); levels clamp to 1…6.
public enum MarkdownHeadingShift {

    /// `delta > 0` demotes (adds `#`), `delta < 0` promotes (removes `#`).
    public static func shift(_ text: String, by delta: Int) -> String {
        guard delta != 0 else { return text }
        var inFence = false
        var fenceChar: Character = "`"
        var fenceLen = 0
        var inComment = false
        var out = ""
        out.reserveCapacity(text.count)
        for (content, term) in splitLines(text) {
            let trimmed = content.drop { $0 == " " || $0 == "\t" }
            if let (marker, count) = fenceRun(trimmed) {
                if inFence { if marker == fenceChar, count >= fenceLen { inFence = false } }
                else { inFence = true; fenceChar = marker; fenceLen = count }
                out += content + term
                continue
            }
            if inFence { out += content + term; continue }
            // HTML comment blocks: never shift a `#` line that's commented out.
            if inComment {
                if trimmed.contains("-->") { inComment = false }
                out += content + term
                continue
            }
            if trimmed.hasPrefix("<!--"), !trimmed.contains("-->") {
                inComment = true
                out += content + term
                continue
            }
            out += shiftHeadingLine(content, by: delta) + term
        }
        return out
    }

    // MARK: - helpers

    private static func shiftHeadingLine(_ line: String, by delta: Int) -> String {
        let chars = Array(line)
        var i = 0
        var indentWidth = 0
        while i < chars.count, chars[i] == " " || chars[i] == "\t" {
            indentWidth += chars[i] == "\t" ? 4 : 1   // CommonMark tab = 4-col stop
            i += 1
        }
        // 4+ columns of indent → an indented code block, NOT an ATX heading;
        // shifting it would corrupt the user's code content.
        guard indentWidth <= 3 else { return line }
        var h = i
        while h < chars.count, chars[h] == "#" { h += 1 }
        let count = h - i
        guard count >= 1, count <= 6,
              h == chars.count || chars[h] == " " || chars[h] == "\t" else {
            return line   // not an ATX heading (#######, #nospace, …)
        }
        let newLevel = Swift.max(1, Swift.min(6, count + delta))
        return String(chars[0..<i]) + String(repeating: "#", count: newLevel) + String(chars[h...])
    }

    /// Split into (content, terminator) pairs, terminators (`\r\n`/`\r`/`\n`)
    /// preserved exactly (the CRLF grapheme is split correctly).
    private static func splitLines(_ text: String) -> [(content: String, term: String)] {
        let cr: Unicode.Scalar = "\r", lf: Unicode.Scalar = "\n"
        var out: [(String, String)] = []
        var content = String.UnicodeScalarView()
        let scalars = text.unicodeScalars
        var i = scalars.startIndex
        while i < scalars.endIndex {
            let u = scalars[i]
            if u == cr {
                let n = scalars.index(after: i)
                if n < scalars.endIndex, scalars[n] == lf {
                    out.append((String(content), "\r\n")); content = .init(); i = scalars.index(after: n); continue
                }
                out.append((String(content), "\r")); content = .init(); i = scalars.index(after: i); continue
            } else if u == lf {
                out.append((String(content), "\n")); content = .init(); i = scalars.index(after: i); continue
            }
            content.append(u); i = scalars.index(after: i)
        }
        out.append((String(content), ""))
        return out
    }

    private static func fenceRun(_ trimmed: Substring) -> (Character, Int)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        return (first, run.count)
    }
}
