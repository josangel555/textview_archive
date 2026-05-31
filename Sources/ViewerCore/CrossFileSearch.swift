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
    ///
    /// `isCancelled` is polled every `cancelCheckStride` entries (and
    /// once per file before the relatively expensive read+decode) so a
    /// long walk over a large tree can be abandoned promptly when the
    /// caller's `Task` is cancelled or the user retypes the query.
    /// SCALE-5: the walk was previously a single uninterruptible blocking
    /// loop — a search kicked off against a huge root kept the worker
    /// pegged even after the UI moved on. Defaults to "never cancel" so
    /// existing call sites are unaffected.
    public static func search(
        root: URL,
        query: String,
        options: Options = Options(),
        isCancelled: () -> Bool = { false }
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
            // In-loop cancellation (SCALE-5). Cheap modulo check so the
            // common no-cancel path costs ~nothing; poll every K entries
            // rather than per-entry to keep the closure call out of the
            // hottest part of the directory walk.
            if entriesScanned % cancelCheckStride == 0, isCancelled() { break }

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

            // Per-file cancellation point, before the read+decode cost.
            if isCancelled() { break }

            // Read content. Decode via the shared chain (BOM → UTF-16 →
            // UTF-8 → CP1252 → Latin-1) so cross-file search matches the
            // same files `TextFileLoader` can open (I18N-02 / PARSE-08).
            // Previously this decoded strict UTF-8 only and `continue`'d
            // on anything else — a needle in a Latin-1 / CP1252 / BOM-less
            // UTF-16 file was silently invisible to project-wide search.
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let content = TextDecoder.decodeToString(data) else { continue }

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
            //
            // Hot loop. Two perf-relevant choices here:
            //   - Search the `Substring` directly. `Substring.range(of:)`
            //     shares its index space with the parent `content` and
            //     skips an allocation per non-matching line. In a typical
            //     scan most lines DON'T match, so this avoids ~N
            //     `String(lineSub)` allocations per file (N = line count).
            //   - Only materialize `String(lineSub)` on a hit. We re-run
            //     `range(of:)` once on that short String to get a
            //     `Range<String.Index>` valid in `line` (Match.matchRange
            //     is documented to index into `Match.line`). The double
            //     work is bounded by match count, which is typically tiny
            //     compared to total lines scanned.
            //
            // Why not `lowercased()` the haystack once? Because Unicode
            // case-folding can change character count (German ß → "ss",
            // Greek Σ → σ/ς, Turkish İ → "i\u{0307}") — back-mapping
            // indices from the folded buffer to the original breaks for
            // exactly the locales that need it (S2-D regression).
            // `.caseInsensitive` honors the original indices natively.
            var fileMatches: [Match] = []
            // Split into lines handling LF, CRLF, and CR-only endings
            // (I18N-04). Previously a bare `split(separator: "\n")` left
            // a trailing `\r` glued onto every line of a CRLF file (so a
            // line-anchored needle could miss, and `Match.line` carried a
            // stray carriage return) and collapsed a classic-Mac CR-only
            // file into one giant "line 1". `splitLines` normalizes
            // CRLF/CR to single line breaks the way FindEngine's
            // line/column accounting does.
            let lines = splitLines(content)
            for (i, lineSub) in lines.enumerated() {
                guard lineSub.range(of: needle, options: containsOpts) != nil else {
                    continue
                }
                let line = String(lineSub)
                let range = line.range(of: needle, options: containsOpts)
                fileMatches.append(Match(
                    lineNumber: i + 1,
                    line: line,
                    matchRange: range
                ))
                totalMatches += 1
                if totalMatches >= options.maxResults { break }
            }
            if !fileMatches.isEmpty {
                results.append(FileMatches(url: url, matches: fileMatches))
            }
        }
        return results
    }

    /// How often (in scanned entries) the walk polls `isCancelled`.
    /// Modulo against this keeps the cancellation check off the hottest
    /// per-entry path while still bounding worst-case post-cancel work
    /// to a few hundred directory entries.
    private static let cancelCheckStride = 256

    /// Split `content` into lines, treating `\n`, `\r\n`, and bare `\r`
    /// each as a single line break (I18N-04). No empty phantom line is
    /// introduced for a CRLF pair, and a CR-only file is split into its
    /// real lines rather than collapsing to one. A trailing terminator
    /// yields a final empty line, matching `split(separator:"\n",
    /// omittingEmptySubsequences:false)` semantics for LF files.
    static func splitLines(_ content: String) -> [Substring] {
        var lines: [Substring] = []
        var lineStart = content.startIndex
        var i = content.startIndex
        while i < content.endIndex {
            let ch = content[i]
            if ch == "\n" {
                lines.append(content[lineStart..<i])
                i = content.index(after: i)
                lineStart = i
            } else if ch == "\r" {
                lines.append(content[lineStart..<i])
                let next = content.index(after: i)
                // Swallow the LF of a CRLF pair so it's one break.
                if next < content.endIndex, content[next] == "\n" {
                    i = content.index(after: next)
                } else {
                    i = next
                }
                lineStart = i
            } else {
                i = content.index(after: i)
            }
        }
        lines.append(content[lineStart..<content.endIndex])
        return lines
    }

}
