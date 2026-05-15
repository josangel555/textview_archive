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

        public init(
            maxFileBytes: Int = 2 * 1024 * 1024,
            maxResults: Int = 500,
            caseSensitive: Bool = false,
            skipDirNames: Set<String> = [
                ".git", ".hg", ".svn", "node_modules", ".build", ".swiftpm",
                "DerivedData", "Pods", ".venv", "venv", "__pycache__",
                ".next", "dist", "build", ".tox", ".gradle", "target",
            ]
        ) {
            self.maxFileBytes = maxFileBytes
            self.maxResults = maxResults
            self.caseSensitive = caseSensitive
            self.skipDirNames = skipDirNames
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
        let needle = options.caseSensitive ? query : query.lowercased()

        var results: [FileMatches] = []
        var totalMatches = 0

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            // Bail early if we already have enough matches.
            if totalMatches >= options.maxResults { break }

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
            let hay = options.caseSensitive ? content : content.lowercased()
            guard hay.contains(needle) else { continue }

            // Compute per-line matches.
            var fileMatches: [Match] = []
            let lines = content.split(
                separator: "\n", omittingEmptySubsequences: false
            )
            for (i, lineSub) in lines.enumerated() {
                let line = String(lineSub)
                let haystack = options.caseSensitive ? line : line.lowercased()
                if let range = haystack.range(of: needle) {
                    let mappedRange = mapRange(range, in: line, comparedTo: haystack)
                    fileMatches.append(Match(
                        lineNumber: i + 1,
                        line: line,
                        matchRange: mappedRange
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

    /// `range(of:)` on a lowercased string operates on the lowercased
    /// indices, which work as ordinal positions but aren't directly
    /// usable on the original string when characters are multi-scalar
    /// (lowercasing can change byte width). Map by ordinal position
    /// using `distance(from:to:)`.
    private static func mapRange(
        _ range: Range<String.Index>,
        in original: String,
        comparedTo lowered: String
    ) -> Range<String.Index>? {
        // Fast path: original == lowered (common case).
        if original == lowered { return range }
        let startOffset = lowered.distance(from: lowered.startIndex, to: range.lowerBound)
        let endOffset   = lowered.distance(from: lowered.startIndex, to: range.upperBound)
        guard let start = original.index(
            original.startIndex, offsetBy: startOffset, limitedBy: original.endIndex
        ), let end = original.index(
            original.startIndex, offsetBy: endOffset, limitedBy: original.endIndex
        ) else { return nil }
        return start..<end
    }
}
