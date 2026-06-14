import Foundation

/// Converts a file's LEADING indentation between tabs and spaces (TSK-675,
/// robust plain-text editing) — the way VS Code "Convert Indentation to
/// Spaces/Tabs" and Notepad++ do. Only the leading-whitespace run of each line
/// is rewritten; tabs/spaces used for alignment AFTER the first non-whitespace
/// character are left untouched (converting those would corrupt aligned code).
/// Pure + scalar-walk so each line's terminator (LF/CRLF/CR) is preserved
/// byte-for-byte (the recurring CRLF-grapheme trap); SwiftUI-free.
public enum IndentConverter {

    private static let space: Unicode.Scalar = " "
    private static let tab: Unicode.Scalar = "\t"
    private static let cr: Unicode.Scalar = "\r"
    private static let lf: Unicode.Scalar = "\n"

    /// Expand each leading tab to `width` spaces (leading spaces unchanged).
    public static func tabsToSpaces(_ text: String, width: Int) -> String {
        let w = max(1, width)
        return rewriteLeading(text) { leading in
            var out = [Unicode.Scalar]()
            for u in leading {
                if u == tab { out.append(contentsOf: repeatElement(space, count: w)) }
                else { out.append(u) }
            }
            return out
        }
    }

    /// Collapse each leading run of `width` spaces into one tab (left-to-right);
    /// a trailing partial run (< `width`) stays as spaces, and existing leading
    /// tabs pass through (flushing any pending partial space-run first).
    public static func spacesToTabs(_ text: String, width: Int) -> String {
        let w = max(1, width)
        return rewriteLeading(text) { leading in
            var out = [Unicode.Scalar]()
            var pending = 0
            for u in leading {
                if u == space {
                    pending += 1
                    if pending == w { out.append(tab); pending = 0 }
                } else {   // a tab in the leading run
                    out.append(contentsOf: repeatElement(space, count: pending))
                    pending = 0
                    out.append(tab)
                }
            }
            out.append(contentsOf: repeatElement(space, count: pending))
            return out
        }
    }

    /// Apply `transform` to each line's leading-whitespace run, preserving the
    /// rest of the line + its terminator exactly.
    private static func rewriteLeading(
        _ text: String, _ transform: ([Unicode.Scalar]) -> [Unicode.Scalar]
    ) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        var line = [Unicode.Scalar]()

        func flushLine() {
            var i = 0
            while i < line.count, line[i] == space || line[i] == tab { i += 1 }
            out.append(contentsOf: transform(Array(line[0..<i])))
            out.append(contentsOf: line[i...])
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
                    idx = scalars.index(after: next); continue
                }
                out.append(cr)
            } else if u == lf {
                flushLine(); out.append(lf)
            } else {
                line.append(u); idx = scalars.index(after: idx); continue
            }
            idx = scalars.index(after: idx)
        }
        flushLine()
        return String(out)
    }
}
