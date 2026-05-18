import Foundation

public struct FileNode: Equatable, Sendable, Identifiable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let isDirectory: Bool
    /// File size in bytes. Nil for directories (computing recursive
    /// directory size is expensive; we don't do it here).
    public let byteCount: Int?
    /// Last filesystem modification time. Used for the "Recent" sort.
    public let modifiedAt: Date?

    public init(url: URL, name: String, isDirectory: Bool,
                byteCount: Int? = nil, modifiedAt: Date? = nil) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

public enum FileTreeError: Error, Equatable {
    case notFound
    case notDirectory
    case notReadable
}

/// Reads a directory's contents and returns a sorted list of `FileNode`s.
/// Pure I/O, no UI imports. Directories first, then files, both in
/// localized-standard (Finder-like) sort order.
public struct FileTreeService: Sendable {
    public init() {}

    public func children(
        of url: URL,
        includeHidden: Bool = false
    ) throws -> [FileNode] {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        guard exists else { throw FileTreeError.notFound }
        guard isDir.boolValue else { throw FileTreeError.notDirectory }

        let options: FileManager.DirectoryEnumerationOptions =
            includeHidden ? [] : [.skipsHiddenFiles]

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey,
                                             .fileSizeKey,
                                             .contentModificationDateKey],
                options: options
            )
        } catch {
            throw FileTreeError.notReadable
        }

        // P9: use the .isDirectoryKey we already requested above instead of
        // doing an extra fileExists(_:isDirectory:) stat per child.
        //
        // URLs are normalized here (standardized + resolved symlinks) so
        // every node downstream can be compared/looked-up by URL without
        // each caller re-normalizing — gets rid of the bug class where
        // a `/var/...` URL from a callback misses a cache keyed on
        // `/private/var/...`.
        //
        // We additionally fetch size + modification time so the sidebar
        // can sort by them without a second pass. Both are batched into
        // the same `contentsOfDirectory` resource-keys call → no extra
        // syscalls beyond the existing isDirectory probe.
        let nodes: [FileNode] = contents.map { child in
            let vals = try? child.resourceValues(
                forKeys: [.isDirectoryKey, .fileSizeKey,
                          .contentModificationDateKey])
            let isDir = vals?.isDirectory ?? false
            return FileNode(
                url: child.standardizedFileURL.resolvingSymlinksInPath(),
                name: child.lastPathComponent,
                isDirectory: isDir,
                byteCount: isDir ? nil : vals?.fileSize,
                modifiedAt: vals?.contentModificationDate
            )
        }

        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
