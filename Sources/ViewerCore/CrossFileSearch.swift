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

        public init(lineNumber: Int, line: String, matchRange: Range<String.Index>?) {
            self.lineNumber = lineNumber
            self.line = line
            self.matchRange = matchRange
        }
    }

    public struct FileMatches: Equatable, Sendable, Identifiable {
        public var id: String { url.path }
        public let url: URL
        public let matches: [Match]

        public init(url: URL, matches: [Match]) {
            self.url = url
            self.matches = matches
        }
    }

    public struct Options: Sendable {
        public var maxFileBytes: Int
        public var maxResults: Int
        public var caseSensitive: Bool
        /// TSK-758 — interpret `query` as a regular expression instead of a
        /// literal substring. ReDoS-guarded (`validateRegex`); an
        /// invalid/rejected pattern yields no results.
        public var useRegex: Bool
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
            useRegex: Bool = false,
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
            self.useRegex = useRegex
            self.skipDirNames = skipDirNames
            self.maxEntriesScanned = maxEntriesScanned
        }
    }

    /// A compiled matcher — literal substring or regex, with the case flag
    /// baked in — built once per search and reused for every line/filename.
    /// `make` returns `nil` when a regex query is rejected (ReDoS shape) or
    /// uncompilable, so the search yields no results; the caller surfaces the
    /// reason separately via `validateRegex`. (TSK-758)
    /// `@unchecked Sendable` (TSK-829): the two closures only READ immutable
    /// state — an `NSRegularExpression` (thread-safe for matching) or pure
    /// `String.range(of:)` — so sharing one `Matcher` across the parallel
    /// per-file match (`concurrentPerform`) is safe.
    struct Matcher: @unchecked Sendable {
        let contains: (String) -> Bool
        let firstRange: (String) -> Range<String.Index>?

        static func make(query: String, caseSensitive: Bool, useRegex: Bool) -> Matcher? {
            if useRegex {
                guard validateRegex(query, caseSensitive: caseSensitive) == nil else { return nil }
                var ropts: NSRegularExpression.Options = []
                if !caseSensitive { ropts.insert(.caseInsensitive) }
                guard let re = try? NSRegularExpression(pattern: query, options: ropts) else {
                    return nil
                }
                return Matcher(
                    contains: { s in
                        re.firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)) != nil
                    },
                    firstRange: { s in
                        guard let m = re.firstMatch(
                            in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)),
                            let r = Range(m.range, in: s) else { return nil }
                        return r
                    })
            }
            let copts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            return Matcher(
                contains: { $0.range(of: query, options: copts) != nil },
                firstRange: { $0.range(of: query, options: copts) })
        }
    }

    /// Pre-validate a regex query for cross-file search (TSK-758). Returns a
    /// human-readable reason when the pattern should be rejected — a known
    /// ReDoS shape (`RegexComplexityGuard.reject`) or an uncompilable pattern
    /// — else `nil`. Lets the UI show "invalid pattern" without running a walk.
    public static func validateRegex(_ pattern: String, caseSensitive: Bool = false) -> String? {
        guard !pattern.isEmpty else { return nil }
        if let reason = RegexComplexityGuard.reject(pattern) { return reason }
        var ropts: NSRegularExpression.Options = []
        if !caseSensitive { ropts.insert(.caseInsensitive) }
        do {
            _ = try NSRegularExpression(pattern: pattern, options: ropts)
            return nil
        } catch {
            return "invalid regular expression"
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
        isCancelled: () -> Bool = { false },
        onProgress: ((_ entriesScanned: Int, _ matches: Int) -> Void)? = nil
    ) -> [FileMatches] {
        guard !query.isEmpty else { return [] }
        // Needle is passed as-is; case-insensitive matching is done
        // via `.caseInsensitive` compare options at the search call
        // sites (preserves original indices for multi-scalar-change
        // lowercasers like ß / Σ / İ — S2-D).
        let needle = query
        // Compiled once. `nil` ⇒ a rejected/invalid regex (TSK-758) ⇒ no results.
        guard let matcher = Matcher.make(
            query: needle, caseSensitive: options.caseSensitive, useRegex: options.useRegex
        ) else { return [] }

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

        // TSK-829: read+decode+match is the CPU/IO-heavy per-file work and is
        // independent across files. Collect candidate URLs into batches, match
        // each batch in PARALLEL, then fold the results SERIALLY in walk order
        // under the global `maxResults` gate — byte-identical to the old serial
        // loop (the fold reproduces its mid-file cap break), with over-read
        // bounded to one batch (vs reading the whole tree).
        let batchSize = 24
        var batch: [URL] = []
        batch.reserveCapacity(batchSize)

        // Match the pending batch in parallel; fold into `results` under the
        // cap. Returns true once `maxResults` is reached (caller stops).
        func flushBatch() -> Bool {
            if !batch.isEmpty {
                let urls = batch
                var slots = [[Match]?](repeating: nil, count: urls.count)
                slots.withUnsafeMutableBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    // Each iteration writes its OWN, disjoint index → race-free
                    // with no shared mutable state; nonisolated(unsafe) lets the
                    // base pointer cross into the @Sendable concurrentPerform body.
                    nonisolated(unsafe) let p = base
                    DispatchQueue.concurrentPerform(iterations: urls.count) { i in
                        (p + i).pointee = Self.matchFile(
                            urls[i], matcher: matcher, needle: needle, options: options)
                    }
                }
                // Serial fold in walk order — reproduces the old loop's global
                // maxResults gate exactly (stops mid-file at the cap).
                for i in 0..<urls.count {
                    if totalMatches >= options.maxResults { break }
                    guard let fileMatches = slots[i] else { continue }
                    var kept: [Match] = []
                    for m in fileMatches {
                        if totalMatches >= options.maxResults { break }
                        kept.append(m)
                        totalMatches += 1
                    }
                    if !kept.isEmpty {
                        results.append(FileMatches(url: urls[i], matches: kept))
                    }
                }
                batch.removeAll(keepingCapacity: true)
            }
            return totalMatches >= options.maxResults
        }

        for case let url as URL in enumerator {
            // Bail early if we already have enough matches OR we've
            // exceeded the hard entry cap.
            if totalMatches >= options.maxResults { break }
            entriesScanned += 1
            if entriesScanned > options.maxEntriesScanned { break }
            // In-loop cancellation (SCALE-5). Cheap modulo check so the
            // common no-cancel path costs ~nothing; poll every K entries
            // rather than per-entry to keep the closure call out of the
            // hottest part of the directory walk. TSK-1465: progress rides
            // the same stride (matches lag by at most one pending batch).
            if entriesScanned % cancelCheckStride == 0 {
                if isCancelled() { break }
                onProgress?(entriesScanned, totalMatches)
            }

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

            // TSK-829: defer the heavy read+decode+match to a parallel batch —
            // collect the candidate, flush when the batch fills. Stop the walk
            // the moment a flush reaches the cap (over-read bounded to one batch).
            batch.append(url)
            if batch.count >= batchSize, flushBatch() { break }
        }
        // Match + fold the trailing partial batch.
        _ = flushBatch()
        // Final progress tick so the caller's last-seen counts are exact.
        onProgress?(entriesScanned, totalMatches)
        return results
    }

    /// Read + decode + per-line match a single file, returning ALL matches in
    /// line order (TSK-829). The global `maxResults` gate is applied by the
    /// caller's serial fold, NOT here — this is the parallelizable per-file
    /// unit, sharing the exact decode chain + matching rules the serial loop
    /// used. `nil` = unreadable / undecodable / prefilter miss / no match.
    ///
    /// Matching honours the original-string indices (`.caseInsensitive`, never
    /// `lowercased()`, which changes character count for ß/Σ/İ and breaks index
    /// back-mapping — S2-D); lines are split LF/CRLF/CR-aware via `splitLines`.
    static func matchFile(
        _ url: URL, matcher: Matcher, needle: String, options: Options
    ) -> [Match]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let content = TextDecoder.decodeToString(data) else { return nil }
        guard matcher.contains(content) else { return nil }

        let containsOpts: String.CompareOptions = options.caseSensitive
            ? [] : [.caseInsensitive]
        var fileMatches: [Match] = []
        let lines = splitLines(content)
        for (i, lineSub) in lines.enumerated() {
            let line: String
            let range: Range<String.Index>?
            if options.useRegex {
                let s = String(lineSub)
                guard let r = matcher.firstRange(s) else { continue }
                line = s
                range = r
            } else {
                guard lineSub.range(of: needle, options: containsOpts) != nil else {
                    continue
                }
                line = String(lineSub)
                range = line.range(of: needle, options: containsOpts)
            }
            fileMatches.append(Match(lineNumber: i + 1, line: line, matchRange: range))
        }
        return fileMatches.isEmpty ? nil : fileMatches
    }

    /// Filename search across a folder tree (TSK-758). Returns one
    /// `FileMatches` per regular file whose NAME matches `query` — the file
    /// itself is the hit, so `matches` is empty (no line content is read).
    /// Same walk, skip-dirs, symlink-loop guard, and caps as `search`, but it
    /// never opens file bodies, so it's cheap over large trees.
    public static func searchFilenames(
        root: URL,
        query: String,
        options: Options = Options(),
        isCancelled: () -> Bool = { false },
        onProgress: ((_ entriesScanned: Int, _ matches: Int) -> Void)? = nil
    ) -> [FileMatches] {
        guard !query.isEmpty else { return [] }
        guard let matcher = Matcher.make(
            query: query, caseSensitive: options.caseSensitive, useRegex: options.useRegex
        ) else { return [] }

        var results: [FileMatches] = []
        var entriesScanned = 0
        var visitedDirs: Set<String> = []

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let url as URL in enumerator {
            if results.count >= options.maxResults { break }
            entriesScanned += 1
            if entriesScanned > options.maxEntriesScanned { break }
            if entriesScanned % cancelCheckStride == 0 {
                if isCancelled() { break }
                onProgress?(entriesScanned, results.count)
            }

            let lastComponent = url.lastPathComponent
            if options.skipDirNames.contains(lastComponent) {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                    .isDirectory ?? false
                if isDir { enumerator.skipDescendants() }
                continue
            }

            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory ?? false
            if isDirectory {
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL.path
                if visitedDirs.contains(canonical) {
                    enumerator.skipDescendants()
                    continue
                }
                visitedDirs.insert(canonical)
                continue  // directories themselves are not filename results
            }

            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true else { continue }
            if matcher.contains(lastComponent) {
                results.append(FileMatches(url: url, matches: []))
            }
        }
        onProgress?(entriesScanned, results.count)
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
    ///
    /// Scans the **unicode-scalar** view, not `Character`s: Swift's
    /// grapheme segmentation fuses `\r\n` into ONE extended grapheme
    /// cluster, so a `Character`-level scan would never see a lone `\n`
    /// or `\r` in CRLF input and would collapse the whole file into a
    /// single line. (Same reason `CSVParser` iterates scalars.) The
    /// returned `Substring`s are rebuilt from scalar ranges; callers run
    /// `range(of:)` against them directly.
    static func splitLines(_ content: String) -> [Substring] {
        var lines: [Substring] = []
        let scalars = content.unicodeScalars
        var lineStart = scalars.startIndex
        var i = scalars.startIndex
        let lf: Unicode.Scalar = "\n"
        let cr: Unicode.Scalar = "\r"
        while i < scalars.endIndex {
            let s = scalars[i]
            if s == lf {
                lines.append(Substring(scalars[lineStart..<i]))
                i = scalars.index(after: i)
                lineStart = i
            } else if s == cr {
                lines.append(Substring(scalars[lineStart..<i]))
                let next = scalars.index(after: i)
                // Swallow the LF of a CRLF pair so it counts as one break.
                if next < scalars.endIndex, scalars[next] == lf {
                    i = scalars.index(after: next)
                } else {
                    i = next
                }
                lineStart = i
            } else {
                i = scalars.index(after: i)
            }
        }
        lines.append(Substring(scalars[lineStart..<scalars.endIndex]))
        return lines
    }

}
