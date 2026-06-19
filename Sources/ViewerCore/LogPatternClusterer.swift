import Foundation

/// Auto-clusters recurring log-line patterns (TSK-694).
///
/// Given the raw text of a log file, this groups lines that share the same
/// *template* — the line with its variable parts (timestamps, numbers, hex/UUID
/// IDs, IP addresses, quoted strings, file paths) masked out by placeholders.
/// Lines that differ only in those variable fields collapse into one cluster, so
/// a million-line log of `Request 42 took 13ms` / `Request 9001 took 4ms`
/// becomes a single pattern `Request <NUM> took <NUM>ms` with a count.
///
/// This is the classic log-template-mining idea (Drain / LogMine family) reduced
/// to a dependency-free, single-pass, masking-then-bucketing core: the foundation
/// slice. It is pure + host-testable; the on-screen presentation (a "Patterns"
/// panel listing clusters by frequency with drill-down to lines) is the render
/// tail, wired separately.
///
/// Design notes:
/// - **Masking, not edit-distance.** A token-by-token regex mask is O(n) over the
///   input and deterministic, where the original Drain tree adds complexity we do
///   not need for a viewer. Two lines cluster iff their masked forms are byte-equal.
/// - **Order of masks matters.** More specific patterns (ISO timestamp, UUID,
///   IPv4, hex) are applied before the generic number mask so a UUID does not get
///   shredded into `<NUM>`-and-letters. Quoted strings and bracketed numbers are
///   collapsed too.
/// - **Stable, frequency-ranked output.** Clusters are returned sorted by count
///   descending, ties broken by first-seen line index, so the ranking is
///   deterministic for a given input (no hash-order flicker in the UI).
public enum LogPatternClusterer {

    /// Placeholder tokens substituted for variable fields. Public so a UI/legend
    /// can explain what each mask means.
    public enum Placeholder: String, CaseIterable, Sendable {
        case timestamp = "<TIMESTAMP>"
        case uuid = "<UUID>"
        case ip = "<IP>"
        case hex = "<HEX>"
        case number = "<NUM>"
        case quoted = "<STR>"
    }

    /// One discovered pattern.
    public struct Cluster: Equatable, Sendable, Identifiable {
        /// Stable identity = the template string (unique within a result set).
        public var id: String { template }
        /// The masked line shared by every member, e.g. `Request <NUM> took <NUM>ms`.
        public let template: String
        /// How many input lines matched this template.
        public let count: Int
        /// A representative *original* (unmasked) line — the first one seen.
        public let example: String
        /// Zero-based indices (into the non-empty input lines) of every member,
        /// in ascending order. Lets a UI jump to each occurrence.
        public let lineIndices: [Int]

        public init(template: String, count: Int, example: String, lineIndices: [Int]) {
            self.template = template
            self.count = count
            self.example = example
            self.lineIndices = lineIndices
        }
    }

    /// Result of clustering: the ranked clusters plus a couple of summary counts.
    public struct Result: Equatable, Sendable {
        /// Clusters sorted by `count` descending, ties broken by earliest member.
        public let clusters: [Cluster]
        /// Total non-empty lines considered.
        public let totalLines: Int
        /// Number of distinct templates (== `clusters.count`).
        public var distinctPatterns: Int { clusters.count }

        public init(clusters: [Cluster], totalLines: Int) {
            self.clusters = clusters
            self.totalLines = totalLines
        }
    }

    /// Tuning knobs. Defaults are sensible for ad-hoc log inspection.
    public struct Options: Sendable {
        /// Cap on input lines processed (defense against a multi-GB paste). Lines
        /// beyond this are ignored. `0` = no cap.
        public let maxLines: Int
        /// Lowercase tokens before comparison so `ERROR`/`error` cluster together.
        /// Off by default — case often carries meaning in logs (levels, hostnames).
        public let caseInsensitive: Bool

        public init(maxLines: Int = 200_000, caseInsensitive: Bool = false) {
            self.maxLines = maxLines
            self.caseInsensitive = caseInsensitive
        }

        public static let `default` = Options()
    }

    /// Cluster the lines of `text`.
    ///
    /// Empty / whitespace-only lines are dropped (they carry no pattern). The
    /// returned `lineIndices` are positions within the *non-empty* line stream.
    public static func cluster(_ text: String, options: Options = .default) -> Result {
        // Normalize line endings FIRST. A `\r\n` pair is a single Swift
        // `Character` (extended grapheme cluster), so a `split` on the `\n`
        // Character would NOT break a CRLF line — collapse to `\n` up front.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines = normalized.split(separator: "\n" as Character, omittingEmptySubsequences: false)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        if options.maxLines > 0 && lines.count > options.maxLines {
            lines = Array(lines.prefix(options.maxLines))
        }

        // Bucket by template, preserving first-seen example + member indices.
        // A dictionary keyed by template gives O(1) insert; we keep insertion
        // order via `firstIndex` for stable tie-breaking.
        struct Acc {
            var count = 0
            var example = ""
            var firstIndex = Int.max
            var indices: [Int] = []
        }
        var buckets: [String: Acc] = [:]
        buckets.reserveCapacity(min(lines.count, 4096))

        for (idx, line) in lines.enumerated() {
            let template = templatize(line, caseInsensitive: options.caseInsensitive)
            var acc = buckets[template] ?? Acc()
            if acc.count == 0 {
                acc.example = line
                acc.firstIndex = idx
            }
            acc.count += 1
            acc.indices.append(idx)
            buckets[template] = acc
        }

        let clusters = buckets
            .map { (template, acc) in
                Cluster(template: template, count: acc.count,
                        example: acc.example, lineIndices: acc.indices)
            }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                // Tie-break by earliest member for determinism.
                let la = a.lineIndices.first ?? Int.max
                let lb = b.lineIndices.first ?? Int.max
                if la != lb { return la < lb }
                return a.template < b.template
            }

        return Result(clusters: clusters, totalLines: lines.count)
    }

    /// Convert a single raw log line into its masked template. Exposed for
    /// testing the masking in isolation and for a UI that wants to preview the
    /// template of an arbitrary line.
    public static func templatize(_ line: String, caseInsensitive: Bool = false) -> String {
        var s = line

        // Order matters: most-specific first, generic number last.
        for rule in maskRules {
            s = rule.regex.stringByReplacingMatches(
                in: s,
                options: [],
                range: NSRange(s.startIndex..<s.endIndex, in: s),
                withTemplate: rule.placeholder.rawValue
            )
        }

        // Collapse runs of internal whitespace so alignment padding does not
        // split otherwise-identical templates, then trim.
        s = s.replacingOccurrences(
            of: "[ \t]+", with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        return caseInsensitive ? s.lowercased() : s
    }

    // MARK: - Mask rules

    private struct MaskRule {
        let regex: NSRegularExpression
        let placeholder: Placeholder
    }

    /// Compiled once. Patterns are anchored to whole tokens where it matters so a
    /// number embedded in a word (`x86_64`) is not over-masked.
    private static let maskRules: [MaskRule] = {
        func re(_ p: String) -> NSRegularExpression {
            // swiftlint:disable:next force_try — patterns are compile-time constants.
            try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
        }
        return [
            // ISO-8601 / common timestamps: 2026-06-18T12:34:56.789Z, 2026-06-18 12:34:56,
            // and bare clock times 12:34:56(.789).
            MaskRule(regex: re(
                #"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?"#
            ), placeholder: .timestamp),
            MaskRule(regex: re(#"\b\d{2}:\d{2}:\d{2}(?:[.,]\d+)?\b"#), placeholder: .timestamp),

            // UUID (8-4-4-4-12).
            MaskRule(regex: re(
                #"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#
            ), placeholder: .uuid),

            // IPv4 (optionally with :port).
            MaskRule(regex: re(#"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?::\d+)?\b"#),
                     placeholder: .ip),

            // Quoted strings (double or single). Non-greedy, no escaped-quote
            // handling needed for clustering purposes.
            MaskRule(regex: re(#""[^"]*"|'[^']*'"#), placeholder: .quoted),

            // Long hex blobs / 0x addresses (≥6 hex chars, or 0x-prefixed).
            MaskRule(regex: re(#"\b0x[0-9a-f]+\b|\b[0-9a-f]{6,}\b"#), placeholder: .hex),

            // Generic numbers, incl. decimals/signs (last so the above win).
            // The leading `(?<![\w.])` keeps digits *inside* an identifier
            // (`x86_64`, `sha1`) untouched — the digit there is preceded by a
            // word char. We deliberately do NOT require a trailing non-word
            // boundary, so a number with an attached unit (`13ms`, `30s`, `9k`)
            // still masks to `<NUM>ms` / `<NUM>s` / `<NUM>k` — the numeric part
            // is the variable field, the unit is the constant.
            MaskRule(regex: re(#"(?<![\w.])[-+]?\d+(?:\.\d+)?"#),
                     placeholder: .number),
        ]
    }()
}
