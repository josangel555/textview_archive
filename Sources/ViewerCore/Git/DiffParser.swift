import Foundation

/// Structured representation of a unified diff (`git diff` / `git show` output)
/// for the dedicated diff viewer.
///
/// TSK-649 Stage B #4: the Swift `DiffParser` engine that built this model has
/// been DELETED — unified-diff parsing is now rust-only (`mdvcore_diff_parse`
/// via `RustDiffAdapter`). This `UnifiedDiff` MODEL stays: the adapter maps the
/// Rust wire types into it (`RustDiffAdapter.toUnified`) and the diff viewer
/// renders it.
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
