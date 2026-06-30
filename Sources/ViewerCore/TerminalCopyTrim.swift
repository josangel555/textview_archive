import Foundation

/// TSK-769 — terminal copy hygiene. A terminal selection is pulled off the fixed-width cell grid,
/// so every row is padded with trailing spaces out to the column count; a raw copy therefore carries
/// ragged trailing whitespace and a block of empty rows below the real content. Matching Terminal.app
/// / iTerm behaviour, the copy path trims that padding.
public enum TerminalCopyTrim {
    /// Strip trailing whitespace (spaces / tabs) from each line, and drop trailing blank lines
    /// (the selection's bottom padding). Interior blank lines are PRESERVED (they're real content,
    /// e.g. spacing between command output). A pure transform — host-tested; the copy action applies
    /// it before writing to the pasteboard.
    public static func trim(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            var l = line
            while let last = l.last, last == " " || last == "\t" { l = l.dropLast() }
            return l
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
