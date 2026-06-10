import Foundation

/// Plain-text reconstruction of parsed diff pieces for the clipboard
/// (TSK-594: the diff view's Copy Hunk / Copy File Diff actions). The
/// output round-trips the unified-diff line shape — prefix character
/// per line, hunk `@@` banner — so pasting into a terminal, a code
/// review, or `git apply --recount` reads as a normal diff fragment.
extension UnifiedDiff.Line.Kind {
    /// The unified-diff prefix character for this line kind.
    public var diffPrefix: String {
        switch self {
        case .context:   return " "
        case .added:     return "+"
        case .removed:   return "-"
        case .noNewline: return "\\"
        }
    }
}

extension UnifiedDiff.Hunk {
    /// The hunk as unified-diff text: `@@` banner (with the trailing
    /// context header when present) followed by prefixed lines.
    public var clipboardText: String {
        var out = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        if !header.isEmpty { out += " \(header)" }
        out += "\n"
        for line in lines {
            out += line.kind.diffPrefix + line.content + "\n"
        }
        return out
    }
}

extension UnifiedDiff.File {
    /// The whole file block as unified-diff text: `---`/`+++` header
    /// followed by every hunk. Binary files reproduce git's one-liner.
    public var clipboardText: String {
        let old = oldPath.isEmpty ? newPath : oldPath
        let new = newPath.isEmpty ? oldPath : newPath
        if isBinary {
            return "Binary files a/\(old) and b/\(new) differ\n"
        }
        var out = "--- \(isNew ? "/dev/null" : "a/\(old)")\n"
        out += "+++ \(isDeleted ? "/dev/null" : "b/\(new)")\n"
        for hunk in hunks {
            out += hunk.clipboardText
        }
        return out
    }
}
