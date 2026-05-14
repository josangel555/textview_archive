import Foundation

public struct FileNode: Equatable, Sendable, Identifiable {
    public var id: URL { url }
    public let url: URL
    public let name: String
    public let isDirectory: Bool

    public init(url: URL, name: String, isDirectory: Bool) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
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
                includingPropertiesForKeys: [.isDirectoryKey],
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
        let nodes: [FileNode] = contents.map { child in
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return FileNode(
                url: child.standardizedFileURL.resolvingSymlinksInPath(),
                name: child.lastPathComponent,
                isDirectory: isDir
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
