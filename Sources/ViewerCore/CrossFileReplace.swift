import Foundation

/// Project-wide find-and-replace across a set of files (TSK-726). The write
/// counterpart to `CrossFileSearch`: given the files a search returned plus a
/// replacement string, rewrite every match on disk — atomically, preserving
/// each file's detected text encoding and its mode/owner/xattrs, and refusing
/// to de-symlink (all inherited from `EditorWriter.save`).
///
/// Split into a PURE core (`replacedText`, fully host-testable, no I/O) and a
/// side-effecting `apply` (re-reads + writes, tested against temp files). The
/// matcher semantics mirror `CrossFileSearch` so replace tracks exactly what
/// search highlighted: a literal substring, or a regex with `$1` template
/// groups and `.anchorsMatchLines` so `^`/`$` bind to line boundaries the same
/// way the per-line search does.
public enum CrossFileReplace {

    /// Per-file result of an `apply` run.
    public struct FileOutcome: Equatable, Sendable {
        public let url: URL
        /// Occurrences replaced (0 when the file was skipped or failed).
        public let replacements: Int
        /// `nil` on success; a human-readable reason on failure (unreadable,
        /// too large, binary, symlink-refused, encoding loss, write error).
        public let error: String?

        public init(url: URL, replacements: Int, error: String?) {
            self.url = url
            self.replacements = replacements
            self.error = error
        }

        public var succeeded: Bool { error == nil }
    }

    /// Aggregate summary of an `apply` run, for a one-line UI status.
    public struct Summary: Equatable, Sendable {
        public let filesChanged: Int
        public let totalReplacements: Int
        public let failures: [FileOutcome]

        public init(outcomes: [FileOutcome]) {
            self.filesChanged = outcomes.filter { $0.succeeded && $0.replacements > 0 }.count
            self.totalReplacements = outcomes.filter { $0.succeeded }.reduce(0) { $0 + $1.replacements }
            self.failures = outcomes.filter { !$0.succeeded }
        }
    }

    // MARK: - Pure core (host-testable, no I/O)

    /// Compute the replaced text for one file's `content` plus the number of
    /// occurrences changed. Returns `nil` only for an empty query or an
    /// invalid/ReDoS-rejected regex (no replacement is possible); a valid query
    /// with no matches returns `(content, 0)` so callers can skip the write.
    ///
    /// Occurrence semantics match `String.replacingOccurrences` / the regex
    /// engine: non-overlapping, left-to-right. The count is computed against the
    /// same matcher used for the rewrite so it can never disagree with the edit.
    public static func replacedText(
        in content: String,
        query: String,
        replacement: String,
        caseSensitive: Bool,
        useRegex: Bool
    ) -> (text: String, count: Int)? {
        guard !query.isEmpty else { return nil }

        if useRegex {
            // Reuse the search-side ReDoS/validity gate so replace rejects the
            // same patterns search would have refused.
            guard CrossFileSearch.validateRegex(query, caseSensitive: caseSensitive) == nil else {
                return nil
            }
            var ropts: NSRegularExpression.Options = [.anchorsMatchLines]
            if !caseSensitive { ropts.insert(.caseInsensitive) }
            guard let re = try? NSRegularExpression(pattern: query, options: ropts) else {
                return nil
            }
            let full = NSRange(content.startIndex..<content.endIndex, in: content)
            let count = re.numberOfMatches(in: content, range: full)
            guard count > 0 else { return (content, 0) }
            let out = re.stringByReplacingMatches(
                in: content, options: [], range: full, withTemplate: replacement)
            return (out, count)
        }

        let count = countOccurrences(of: query, in: content, caseSensitive: caseSensitive)
        guard count > 0 else { return (content, 0) }
        let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        let out = content.replacingOccurrences(of: query, with: replacement, options: opts)
        return (out, count)
    }

    /// Count non-overlapping, left-to-right occurrences of `needle` in
    /// `haystack` — exactly what `replacingOccurrences` will replace, so the
    /// reported count matches the edit.
    static func countOccurrences(of needle: String, in haystack: String,
                                 caseSensitive: Bool) -> Int {
        guard !needle.isEmpty else { return 0 }
        let opts: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var count = 0
        var from = haystack.startIndex
        while from < haystack.endIndex,
              let r = haystack.range(of: needle, options: opts, range: from..<haystack.endIndex) {
            count += 1
            // Advance past the match; guard against a zero-width range (can't
            // happen for a non-empty literal, but keeps the loop total).
            from = r.isEmpty ? haystack.index(after: r.lowerBound) : r.upperBound
        }
        return count
    }

    // MARK: - Side-effecting apply (re-read + atomic write)

    /// Apply a project-wide replace to `files` — the URLs a `CrossFileSearch`
    /// returned. For each file: re-read at replace time (never trust stale
    /// search content), decode preserving its encoding, compute the
    /// replacement, and write it back via `EditorWriter.save` (atomic rename,
    /// symlink refusal, mode/owner/xattr preserved). A file with zero matches is
    /// SKIPPED entirely (no needless rewrite, no mtime churn). Binary /
    /// undecodable / oversized / unreadable files are reported as failures, not
    /// silently dropped.
    ///
    /// Synchronous + bounded; the caller runs it off the main thread for a large
    /// set. Returns a per-file outcome in input order.
    @discardableResult
    public static func apply(
        toFiles files: [URL],
        query: String,
        replacement: String,
        caseSensitive: Bool,
        useRegex: Bool,
        maxFileBytes: Int = 2 * 1024 * 1024,
        allowSymlink: Bool = false
    ) -> [FileOutcome] {
        var outcomes: [FileOutcome] = []
        outcomes.reserveCapacity(files.count)
        for url in files {
            guard let data = try? Data(contentsOf: url) else {
                outcomes.append(FileOutcome(url: url, replacements: 0,
                                            error: "could not read file"))
                continue
            }
            guard data.count <= maxFileBytes else {
                outcomes.append(FileOutcome(url: url, replacements: 0,
                                            error: "file exceeds \(maxFileBytes) bytes"))
                continue
            }
            guard case .text(let content, let encoding) = TextDecoder.decode(data) else {
                outcomes.append(FileOutcome(url: url, replacements: 0,
                                            error: "binary or undecodable"))
                continue
            }
            guard let (newText, count) = replacedText(
                in: content, query: query, replacement: replacement,
                caseSensitive: caseSensitive, useRegex: useRegex) else {
                // nil = invalid query/regex; same for every file — report once
                // per file so the caller can surface it.
                outcomes.append(FileOutcome(url: url, replacements: 0,
                                            error: "invalid search pattern"))
                continue
            }
            guard count > 0 else { continue }  // no match in this file — skip
            do {
                _ = try EditorWriter.save(newText, to: url, encoding: encoding,
                                          allowSymlink: allowSymlink)
                outcomes.append(FileOutcome(url: url, replacements: count, error: nil))
            } catch let e as EditorWriteError {
                outcomes.append(FileOutcome(url: url, replacements: 0,
                                            error: describe(e)))
            } catch {
                outcomes.append(FileOutcome(url: url, replacements: 0,
                                            error: "\(error)"))
            }
        }
        return outcomes
    }

    private static func describe(_ e: EditorWriteError) -> String {
        switch e {
        case .encodingFailed(let enc):
            return "replacement not representable in the file's encoding (\(enc))"
        case .writeFailed(let msg):
            return "write failed: \(msg)"
        case .targetIsSymlink(let target):
            return "refused to overwrite symlink → \(target)"
        }
    }
}
