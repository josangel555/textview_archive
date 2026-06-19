import Foundation

/// One top-level child of a scanned folder, with its on-disk byte size.
/// For a subdirectory `byteSize` is the recursive sum of every regular
/// file beneath it; for a regular file it is that file's size. Backs the
/// folder-stats "bundle-analyzer" treemap (TSK-506): each entry becomes a
/// size-proportional treemap tile via `TreemapLayout.squarify`.
public struct FolderSizeEntry: Equatable, Sendable, Identifiable {
    /// Stable identity = the entry's last path component. The scan dedups
    /// on URL, so the top-level child name is unique within one folder.
    public var id: String { name }
    /// Display name (the child's `lastPathComponent`).
    public let name: String
    /// Recursive byte total for a directory; the file size for a file.
    public let byteSize: Int64
    /// `true` for a directory child, `false` for a regular file.
    public let isDirectory: Bool
    /// Number of regular files rolled into `byteSize` (1 for a file).
    public let fileCount: Int

    public init(name: String, byteSize: Int64, isDirectory: Bool, fileCount: Int) {
        self.name = name
        self.byteSize = byteSize
        self.isDirectory = isDirectory
        self.fileCount = fileCount
    }
}

/// Aggregate result of scanning one folder's immediate children: the
/// per-child size breakdown plus rolled-up totals. The `entries` are
/// sorted by `byteSize` descending so the largest consumers lead — and so
/// the treemap lays the biggest tiles first (squarify expects descending
/// weights for the cleanest aspect ratios).
public struct FolderSizeStats: Equatable, Sendable {
    /// The scanned folder.
    public let root: URL
    /// Top-level children, largest first. Zero-byte children are kept
    /// (they still appear in a listing) but contribute no treemap area.
    public let entries: [FolderSizeEntry]
    /// Sum of every entry's `byteSize`.
    public let totalBytes: Int64
    /// Sum of every entry's `fileCount` (total regular files under root).
    public let totalFiles: Int
    /// `true` if the walk hit `maxEntries` and stopped early (the totals
    /// are then a lower bound). The UI can surface a "partial" badge.
    public let truncated: Bool

    public init(
        root: URL,
        entries: [FolderSizeEntry],
        totalBytes: Int64,
        totalFiles: Int,
        truncated: Bool
    ) {
        self.root = root
        self.entries = entries
        self.totalBytes = totalBytes
        self.totalFiles = totalFiles
        self.truncated = truncated
    }
}

public extension FolderSizeStats {

    /// Bounds + filters for a folder-size scan. Mirrors the conventions
    /// used by `CrossFileSearch` (hidden-file skipping, well-known
    /// build/VCS dir skipping, a hard entry cap, symlink-loop guarding)
    /// so the treemap reflects the same "interesting" subset the rest of
    /// the app treats as the workspace.
    struct Options: Sendable {
        /// Skip dot-prefixed entries (matches the file tree's default).
        public var skipsHiddenFiles: Bool
        /// Directory basenames whose subtrees are summed but NOT descended
        /// for the symlink-loop bookkeeping cost — kept here so a caller
        /// can include or exclude generated dirs. Empty = descend all.
        public var skipDirNames: Set<String>
        /// Hard cap on filesystem entries visited before the walk stops
        /// early (sets `truncated`). Guards a pathological tree from
        /// pinning the scan thread.
        public var maxEntries: Int

        public init(
            skipsHiddenFiles: Bool = true,
            skipDirNames: Set<String> = [".git"],
            maxEntries: Int = 200_000
        ) {
            self.skipsHiddenFiles = skipsHiddenFiles
            self.skipDirNames = skipDirNames
            self.maxEntries = maxEntries
        }

        public static let `default` = Options()
    }

    /// Synchronously walk `folder`'s subtree and aggregate the on-disk
    /// byte size of each immediate child. Pure filesystem I/O + arithmetic
    /// — no AppKit, no main-thread assumptions — so it is host-testable
    /// over a temp dir and safe to call off the main actor.
    ///
    /// Returns an empty-entry result (not nil) for an unreadable or empty
    /// folder; the caller renders an "empty" state. Symlinked directories
    /// are summed for size but a canonical-path visited set prevents a
    /// symlink loop (`a/loop -> ..`) from spinning forever, exactly as in
    /// `CrossFileSearch`.
    static func scan(
        folder: URL,
        options: Options = .default,
        isCancelled: () -> Bool = { false }
    ) -> FolderSizeStats {
        let fm = FileManager.default

        // Read the immediate children first; each one is a treemap entry.
        let childOpts: FileManager.DirectoryEnumerationOptions =
            options.skipsHiddenFiles ? [.skipsHiddenFiles] : []
        guard let children = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isRegularFileKey],
            options: childOpts
        ) else {
            return FolderSizeStats(
                root: folder, entries: [], totalBytes: 0, totalFiles: 0, truncated: false)
        }

        var entries: [FolderSizeEntry] = []
        var grandTotalBytes: Int64 = 0
        var grandTotalFiles = 0
        var entriesVisited = 0
        var truncated = false

        // Shared budget across all children so one giant subtree can't
        // make the whole scan run unbounded.
        func budgetExceeded() -> Bool {
            entriesVisited >= options.maxEntries
        }

        for child in children.sorted(by: { $0.path < $1.path }) {
            if budgetExceeded() { truncated = true; break }
            if isCancelled() { truncated = true; break }

            let name = child.lastPathComponent
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false

            if isDir {
                if options.skipDirNames.contains(name) { continue }
                let (bytes, fileCount, hitCap) = subtreeSize(
                    of: child, fm: fm, options: options,
                    visited: &entriesVisited, isCancelled: isCancelled)
                if hitCap { truncated = true }
                entries.append(FolderSizeEntry(
                    name: name, byteSize: bytes, isDirectory: true, fileCount: fileCount))
                grandTotalBytes += bytes
                grandTotalFiles += fileCount
            } else {
                let rv = try? child.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey])
                guard rv?.isRegularFile == true else { continue }
                let size = Int64(rv?.fileSize ?? 0)
                entriesVisited += 1
                entries.append(FolderSizeEntry(
                    name: name, byteSize: size, isDirectory: false, fileCount: 1))
                grandTotalBytes += size
                grandTotalFiles += 1
            }
        }

        // Largest first — both for the UI listing and so squarify gets the
        // descending-weight order it lays out cleanest.
        entries.sort {
            $0.byteSize != $1.byteSize ? $0.byteSize > $1.byteSize : $0.name < $1.name
        }

        return FolderSizeStats(
            root: folder,
            entries: entries,
            totalBytes: grandTotalBytes,
            totalFiles: grandTotalFiles,
            truncated: truncated
        )
    }

    /// Recursive byte + file-count total for one directory subtree.
    /// Uses the enumerator (not a hand-rolled recursion) for depth safety,
    /// guards symlink loops by canonical path, honors the shared entry
    /// budget, and returns `hitCap = true` if the budget tripped mid-walk.
    private static func subtreeSize(
        of dir: URL,
        fm: FileManager,
        options: Options,
        visited: inout Int,
        isCancelled: () -> Bool
    ) -> (bytes: Int64, fileCount: Int, hitCap: Bool) {
        let enumOpts: FileManager.DirectoryEnumerationOptions =
            options.skipsHiddenFiles ? [.skipsHiddenFiles] : []
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey],
            options: enumOpts
        ) else { return (0, 0, false) }

        var bytes: Int64 = 0
        var fileCount = 0
        var visitedDirs: Set<String> = []

        for case let url as URL in enumerator {
            if visited >= options.maxEntries { return (bytes, fileCount, true) }
            if isCancelled() { return (bytes, fileCount, true) }
            visited += 1

            let last = url.lastPathComponent
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false

            if isDirectory {
                // Skip well-known build/VCS dirs by name (their subtree is
                // not descended), mirroring the search walk.
                if options.skipDirNames.contains(last) {
                    enumerator.skipDescendants()
                    continue
                }
                // Symlink-loop guard: never re-descend a canonical path.
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
                if visitedDirs.contains(canonical) {
                    enumerator.skipDescendants()
                    continue
                }
                visitedDirs.insert(canonical)
                continue
            }

            let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard rv?.isRegularFile == true else { continue }
            bytes += Int64(rv?.fileSize ?? 0)
            fileCount += 1
        }
        return (bytes, fileCount, false)
    }
}
