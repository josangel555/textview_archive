import Foundation

/// Plain-text grep across a folder tree. Returns matches grouped by
/// file. Synchronous + bounded — caller is responsible for invoking
/// on a background queue and presenting incrementally if desired.
///
/// Design choices:
///   - Skips binary files (NUL byte heuristic).
///   - Skips files larger than `maxFileBytes` (default 2 MiB).
///   - Total result cap via `maxResults`; halts the walk once reached.
///   - Hidden files / VCS metadata (`.git`, `node_modules`, `.build`)
///     skipped by default — these blow up the search time and rarely
///     contain content the user is looking for.
public enum CrossFileSearch {

    public struct Match: Equatable, Sendable {
        public let lineNumber: Int       // 1-based
        public let line: String          // full line content (no trailing newline)
        public let matchRange: Range<String.Index>?
    }

    public struct FileMatches: Equatable, Sendable, Identifiable {
        public var id: String { url.path }
        public let url: URL
        public let matches: [Match]
    }

    public struct Options: Sendable {
        public var maxFileBytes: Int
        public var maxResults: Int
        public var caseSensitive: Bool
        public var skipDirNames: Set<String>
        /// Hard cap on total filesystem entries visited (incl. dirs).
        /// Backstop against a maliciously deep symlink loop where each
        /// loop iteration has no matches and so doesn't accumulate
        /// toward `maxResults`. Default 50k — well past the size of any
        /// reasonable project root.
        public var maxEntriesScanned: Int

        public init(
            maxFileBytes: Int = 2 * 1024 * 1024,
            maxResults: Int = 500,
            caseSensitive: Bool = false,
            skipDirNames: Set<String> = [
                ".git", ".hg", ".svn", "node_modules", ".build", ".swiftpm",
                "DerivedData", "Pods", ".venv", "venv", "__pycache__",
                ".next", "dist", "build", ".tox", ".gradle", "target",
            ],
            maxEntriesScanned: Int = 50_000
        ) {
            self.maxFileBytes = maxFileBytes
            self.maxResults = maxResults
            self.caseSensitive = caseSensitive
            self.skipDirNames = skipDirNames
            self.maxEntriesScanned = maxEntriesScanned
        }
    }

    /// Synchronous search. Returns up to `options.maxResults` total
    /// matches grouped by file.
    public static func search(
        root: URL,
        query: String,
        options: Options = Options()
    ) -> [FileMatches] {
        guard !query.isEmpty else { return [] }
        // Needle is passed as-is; case-insensitive matching is done
        // via `.caseInsensitive` compare options at the search call
        // sites (preserves original indices for multi-scalar-change
        // lowercasers like ß / Σ / İ — S2-D).
        let needle = query

        var results: [FileMatches] = []
        var totalMatches = 0
        var entriesScanned = 0
        /// Canonicalized directory paths we've already entered. Guards
        /// against symlink loops (e.g. `evil/loop -> ..`) where the
        /// enumerator would otherwise re-descend the same subtree
        /// forever, never accumulating a match.
        var visitedDirs: Set<String> = []

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            // Bail early if we already have enough matches OR we've
            // exceeded the hard entry cap.
            if totalMatches >= options.maxResults { break }
            entriesScanned += 1
            if entriesScanned > options.maxEntriesScanned { break }

            let lastComponent = url.lastPathComponent
            // Skip well-known build / VCS dirs.
            if options.skipDirNames.contains(lastComponent) {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory ?? false
                if isDir {
                    enumerator.skipDescendants()
                }
                continue
            }

            // Symlink-loop guard. If the entry is a directory, check
            // whether we've seen this canonical path before. If we
            // have, skip the descent — otherwise an `evil/loop -> ..`
            // makes us walk forever.
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            if isDirectory {
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
                if visitedDirs.contains(canonical) {
                    enumerator.skipDescendants()
                    continue
                }
                visitedDirs.insert(canonical)
            }

            let rv = try? url.resourceValues(forKeys: [
                .isRegularFileKey, .fileSizeKey
            ])
            guard rv?.isRegularFile == true else { continue }
            guard (rv?.fileSize ?? 0) <= options.maxFileBytes else { continue }

            // Read content. Skip binaries.
            guard let data = try? Data(contentsOf: url) else { continue }
            if containsNUL(data) { continue }
            guard let content = String(data: data, encoding: .utf8) else { continue }

            // Search.
            // For case-insensitive, use `range(of:options:)` directly
            // on the original string — `String.lowercased()` can
            // change character count (German ß → "ss", Greek Σ →
            // σ/ς, Turkish İ → "i\u{0307}"), which previously broke
            // ordinal-distance back-mapping and dropped the visual
            // highlight for exactly the locales most likely to need
            // it (S2-D). `.caseInsensitive` honours the original
            // indices natively.
            let containsOpts: String.CompareOptions = options.caseSensitive
                ? [] : [.caseInsensitive]
            guard content.range(of: needle, options: containsOpts) != nil else {
                continue
            }

            // Compute per-line matches.
            var fileMatches: [Match] = []
            let lines = content.split(
                separator: "\n", omittingEmptySubsequences: false
            )
            for (i, lineSub) in lines.enumerated() {
                let line = String(lineSub)
                if let range = line.range(of: needle, options: containsOpts) {
                    fileMatches.append(Match(
                        lineNumber: i + 1,
                        line: line,
                        matchRange: range
                    ))
                    totalMatches += 1
                    if totalMatches >= options.maxResults { break }
                }
            }
            if !fileMatches.isEmpty {
                results.append(FileMatches(url: url, matches: fileMatches))
            }
        }
        return results
    }

    /// Quick NUL-byte heuristic for binary detection. Same one used by
    /// TextFileLoader. We only scan the first 4 KiB — text files
    /// occasionally have stray binary bytes deep into them, but if the
    /// first chunk is clean it's almost always real text.
    private static func containsNUL(_ data: Data) -> Bool {
        let n = min(data.count, 4096)
        for i in 0..<n {
            if data[i] == 0x00 { return true }
        }
        return false
    }

}
