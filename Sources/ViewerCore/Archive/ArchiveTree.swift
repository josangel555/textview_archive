import Foundation

/// TSK-1495 — build a directory TREE from an archive's flat entry list so an
/// archive can expand in the sidebar like a folder (read-only, no implicit
/// extraction to disk). Pure: `ArchiveCatalog.list` produces the flat
/// `[Entry]` (full-path names); this groups them into nested nodes, capped,
/// with a truncation marker. The sidebar wiring + the select→preview path
/// (existing ArchiveBrowser extraction) are the render tail.
public enum ArchiveTree {

    /// One node in the archive's virtual tree.
    public struct Node: Equatable, Sendable, Identifiable {
        /// Full path within the archive ("dir/sub/file.txt") — the stable id
        /// and the key the preview path extracts by.
        public let path: String
        /// Display name (last path component).
        public let name: String
        public let isDirectory: Bool
        public let sizeBytes: Int?
        /// Directory children (files + subdirs), sorted dirs-first then by
        /// name. Empty for a file.
        public let children: [Node]

        public var id: String { path }

        public init(path: String, name: String, isDirectory: Bool,
                    sizeBytes: Int?, children: [Node]) {
            self.path = path
            self.name = name
            self.isDirectory = isDirectory
            self.sizeBytes = sizeBytes
            self.children = children
        }
    }

    /// The build result: the root-level nodes plus whether the archive was
    /// truncated at `nodeCap` (the sidebar shows an "open in Archive Browser"
    /// affordance when `truncated`).
    public struct Result: Equatable, Sendable {
        public let roots: [Node]
        public let truncated: Bool
        public let totalEntries: Int
        public init(roots: [Node], truncated: Bool, totalEntries: Int) {
            self.roots = roots
            self.truncated = truncated
            self.totalEntries = totalEntries
        }
    }

    /// Default cap on how many entries are woven into the tree before we
    /// stop and flag `truncated` — a 100k-file archive shouldn't build a
    /// giant in-memory tree in the sidebar.
    public static let defaultNodeCap = 5_000

    /// Build the tree from a flat entry list. Directory entries (trailing
    /// `/` or `isDirectory`) establish nodes; intermediate directories
    /// implied by a file path are synthesized. Entries beyond `nodeCap` are
    /// dropped and `truncated` is set.
    public static func build(
        entries: [ArchiveCatalog.Entry], nodeCap: Int = defaultNodeCap
    ) -> Result {
        let total = entries.count
        let capped = Array(entries.prefix(max(0, nodeCap)))

        // Mutable builder tree keyed by full path.
        final class Builder {
            var isDir = false
            var size: Int?
            var children: [String: Builder] = [:]   // component → child
        }
        let root = Builder()
        root.isDir = true

        for entry in capped {
            let clean = entry.name.hasSuffix("/") ? String(entry.name.dropLast()) : entry.name
            let comps = clean.split(separator: "/").map(String.init)
            guard !comps.isEmpty else { continue }
            var node = root
            for (idx, comp) in comps.enumerated() {
                let child = node.children[comp] ?? {
                    let b = Builder()
                    node.children[comp] = b
                    return b
                }()
                let isLast = idx == comps.count - 1
                if isLast {
                    // The entry itself: a dir if flagged / trailing-slash,
                    // else a file carrying its size.
                    if entry.isDirectory || entry.name.hasSuffix("/") {
                        child.isDir = true
                    } else {
                        child.size = entry.sizeBytes
                    }
                } else {
                    child.isDir = true   // an intermediate path segment
                }
                node = child
            }
        }

        func materialize(_ builder: Builder, prefix: String, name: String) -> Node {
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let kids = builder.children
                .map { materialize($0.value, prefix: path, name: $0.key) }
                .sorted { a, b in
                    if a.isDirectory != b.isDirectory { return a.isDirectory }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            return Node(path: path, name: name,
                        isDirectory: builder.isDir || !kids.isEmpty,
                        sizeBytes: builder.size, children: kids)
        }

        let roots = root.children
            .map { materialize($0.value, prefix: "", name: $0.key) }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        return Result(roots: roots, truncated: total > capped.count, totalEntries: total)
    }
}
