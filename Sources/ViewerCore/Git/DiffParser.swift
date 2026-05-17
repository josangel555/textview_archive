import Foundation

/// Structured representation of a unified diff (`git diff` /
/// `git show` output). Differs from `DiffHunkParser` — that one
/// flattens to a per-line gutter mark map for the source view. This
/// parser keeps the full structure for the dedicated diff viewer.
public enum UnifiedDiff {

    public struct File: Sendable, Equatable {
        public let oldPath: String      // without "a/" prefix
        public let newPath: String      // without "b/" prefix
        public let isNew: Bool          // "new file mode …" seen
        public let isDeleted: Bool      // "deleted file mode …" seen
        public let isBinary: Bool       // "Binary files … differ"
        public let isRename: Bool       // oldPath != newPath and not pure add/delete
        public let hunks: [Hunk]

        public init(
            oldPath: String, newPath: String,
            isNew: Bool = false, isDeleted: Bool = false,
            isBinary: Bool = false, isRename: Bool = false,
            hunks: [Hunk] = []
        ) {
            self.oldPath = oldPath; self.newPath = newPath
            self.isNew = isNew; self.isDeleted = isDeleted
            self.isBinary = isBinary; self.isRename = isRename
            self.hunks = hunks
        }
    }

    public struct Hunk: Sendable, Equatable {
        public let oldStart: Int
        public let oldCount: Int
        public let newStart: Int
        public let newCount: Int
        public let header: String       // the tail context after "@@ … @@ "
        public let lines: [Line]

        public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int,
                    header: String, lines: [Line]) {
            self.oldStart = oldStart; self.oldCount = oldCount
            self.newStart = newStart; self.newCount = newCount
            self.header = header; self.lines = lines
        }
    }

    public struct Line: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case context, added, removed, noNewline
        }
        public let kind: Kind
        public let oldLineNo: Int?      // nil for added
        public let newLineNo: Int?      // nil for removed
        public let content: String      // without the +/-/space prefix

        public init(kind: Kind, oldLineNo: Int?, newLineNo: Int?, content: String) {
            self.kind = kind; self.oldLineNo = oldLineNo
            self.newLineNo = newLineNo; self.content = content
        }
    }
}

public enum DiffParser {

    /// Parse a full unified diff (possibly multi-file). Tolerant of
    /// `git show` prefix (commit metadata before the first `diff --git`).
    public static func parse(_ text: String) -> [UnifiedDiff.File] {
        var files: [UnifiedDiff.File] = []
        var current: PartialFile?
        var currentHunk: PartialHunk?

        // Iterate lines preserving empties. Using a manual index so we
        // can peek at the next line for binary / similarity tails.
        let allLines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        for raw in allLines {
            // -- file boundary --
            if raw.hasPrefix("diff --git ") {
                Self.flushHunk(into: &current, hunk: &currentHunk)
                Self.flush(files: &files, partial: &current)
                let (a, b) = Self.parseDiffGitPaths(raw)
                current = PartialFile(oldPath: a, newPath: b)
                continue
            }
            guard current != nil else {
                // No "diff --git" yet — could be a `git show` header
                // (commit, author, message). Skip silently.
                continue
            }
            // -- file metadata lines --
            if raw.hasPrefix("new file mode ") {
                current?.isNew = true; continue
            }
            if raw.hasPrefix("deleted file mode ") {
                current?.isDeleted = true; continue
            }
            if raw.hasPrefix("rename from ") {
                current?.isRename = true
                current?.oldPath = String(raw.dropFirst("rename from ".count))
                continue
            }
            if raw.hasPrefix("rename to ") {
                current?.isRename = true
                current?.newPath = String(raw.dropFirst("rename to ".count))
                continue
            }
            if raw.hasPrefix("copy from ") || raw.hasPrefix("copy to ")
                || raw.hasPrefix("similarity index ")
                || raw.hasPrefix("dissimilarity index ")
                || raw.hasPrefix("index ")
                || raw.hasPrefix("old mode ") || raw.hasPrefix("new mode ") {
                continue
            }
            if raw.hasPrefix("Binary files ") {
                current?.isBinary = true; continue
            }
            if raw.hasPrefix("--- ") {
                let p = Self.stripPathPrefix(String(raw.dropFirst(4)))
                if p != "/dev/null", current?.isRename != true {
                    current?.oldPath = p
                }
                continue
            }
            if raw.hasPrefix("+++ ") {
                let p = Self.stripPathPrefix(String(raw.dropFirst(4)))
                if p != "/dev/null", current?.isRename != true {
                    current?.newPath = p
                }
                continue
            }
            // -- hunk header --
            if raw.hasPrefix("@@") {
                Self.flushHunk(into: &current, hunk: &currentHunk)
                if let h = Self.parseHunkHeader(raw) {
                    currentHunk = h
                }
                continue
            }
            // -- hunk body --
            guard var hunk = currentHunk else { continue }
            if raw.isEmpty {
                // Empty line counts as a context line in the hunk.
                hunk.append(.context, content: "")
                currentHunk = hunk
                continue
            }
            switch raw.first! {
            case " ":
                hunk.append(.context, content: String(raw.dropFirst()))
            case "+":
                hunk.append(.added,   content: String(raw.dropFirst()))
            case "-":
                hunk.append(.removed, content: String(raw.dropFirst()))
            case "\\":
                hunk.append(.noNewline, content: String(raw.dropFirst()))
            default:
                // Tolerate unknown prefixes (e.g. combined diff).
                hunk.append(.context, content: raw)
            }
            currentHunk = hunk
        }

        Self.flushHunk(into: &current, hunk: &currentHunk)
        Self.flush(files: &files, partial: &current)
        return files
    }

    // MARK: - Private helpers

    private static func flushHunk(into file: inout PartialFile?, hunk: inout PartialHunk?) {
        guard let h = hunk, var f = file else { return }
        f.hunks.append(h.materialize())
        file = f
        hunk = nil
    }

    private static func flush(files: inout [UnifiedDiff.File], partial: inout PartialFile?) {
        guard let p = partial else { return }
        files.append(p.materialize())
        partial = nil
    }

    /// `diff --git a/old b/new` → ("old", "new"). Falls back to the
    /// raw token after `a/` / `b/` if the names have spaces (rare).
    private static func parseDiffGitPaths(_ line: String) -> (String, String) {
        // Strip "diff --git " prefix.
        let rest = line.dropFirst("diff --git ".count)
        // Quoted paths: a/"name with spaces". Not bullet-proof but the
        // common shapes are handled.
        let tokens = rest.split(separator: " ", maxSplits: 1).map(String.init)
        if tokens.count == 2 {
            return (stripPathPrefix(tokens[0]), stripPathPrefix(tokens[1]))
        }
        // Last resort: split at " b/".
        if let bRange = rest.range(of: " b/") {
            let a = rest[..<bRange.lowerBound]
            let b = rest[bRange.upperBound...]
            return (stripPathPrefix(String(a)), String(b))
        }
        return (String(rest), String(rest))
    }

    /// Strip leading `a/`, `b/`, surrounding quotes, trailing newline.
    private static func stripPathPrefix(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("\"") && t.hasSuffix("\"") {
            t = String(t.dropFirst().dropLast())
        }
        if t.hasPrefix("a/") || t.hasPrefix("b/") {
            t = String(t.dropFirst(2))
        }
        return t
    }

    /// Parse `@@ -10,5 +12,7 @@ optional context tail`.
    private static func parseHunkHeader(_ raw: String) -> PartialHunk? {
        // Find the two "@@" markers.
        guard let first = raw.range(of: "@@"),
              let second = raw.range(of: "@@", range: first.upperBound..<raw.endIndex)
        else { return nil }
        let coords = raw[first.upperBound..<second.lowerBound]
            .trimmingCharacters(in: .whitespaces)
        // coords = "-10,5 +12,7" or "-10 +12" (count omitted = 1)
        let parts = coords.split(separator: " ")
        guard parts.count == 2,
              parts[0].first == "-", parts[1].first == "+"
        else { return nil }
        let (oldStart, oldCount) = parseCoord(String(parts[0].dropFirst()))
        let (newStart, newCount) = parseCoord(String(parts[1].dropFirst()))
        let tail = raw[second.upperBound...]
            .trimmingCharacters(in: .whitespaces)
        return PartialHunk(
            oldStart: oldStart, oldCount: oldCount,
            newStart: newStart, newCount: newCount,
            header: tail
        )
    }

    private static func parseCoord(_ s: String) -> (Int, Int) {
        let parts = s.split(separator: ",").map(String.init)
        let start = Int(parts.first ?? "0") ?? 0
        let count = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
        return (start, count)
    }

    // MARK: - Builder structs (private)

    private struct PartialFile {
        var oldPath: String
        var newPath: String
        var isNew: Bool = false
        var isDeleted: Bool = false
        var isBinary: Bool = false
        var isRename: Bool = false
        var hunks: [UnifiedDiff.Hunk] = []
        func materialize() -> UnifiedDiff.File {
            UnifiedDiff.File(
                oldPath: oldPath, newPath: newPath,
                isNew: isNew, isDeleted: isDeleted,
                isBinary: isBinary, isRename: isRename,
                hunks: hunks
            )
        }
    }

    private struct PartialHunk {
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        let header: String
        var lines: [UnifiedDiff.Line] = []
        var oldCursor: Int
        var newCursor: Int

        init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, header: String) {
            self.oldStart = oldStart; self.oldCount = oldCount
            self.newStart = newStart; self.newCount = newCount
            self.header = header
            self.oldCursor = oldStart
            self.newCursor = newStart
        }

        mutating func append(_ kind: UnifiedDiff.Line.Kind, content: String) {
            switch kind {
            case .context:
                lines.append(.init(kind: .context, oldLineNo: oldCursor, newLineNo: newCursor, content: content))
                oldCursor += 1; newCursor += 1
            case .added:
                lines.append(.init(kind: .added, oldLineNo: nil, newLineNo: newCursor, content: content))
                newCursor += 1
            case .removed:
                lines.append(.init(kind: .removed, oldLineNo: oldCursor, newLineNo: nil, content: content))
                oldCursor += 1
            case .noNewline:
                // "\ No newline at end of file" — informational, no line numbers.
                lines.append(.init(kind: .noNewline, oldLineNo: nil, newLineNo: nil, content: content))
            }
        }

        func materialize() -> UnifiedDiff.Hunk {
            UnifiedDiff.Hunk(
                oldStart: oldStart, oldCount: oldCount,
                newStart: newStart, newCount: newCount,
                header: header, lines: lines
            )
        }
    }
}
