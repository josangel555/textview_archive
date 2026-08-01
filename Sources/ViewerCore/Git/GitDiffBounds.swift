import Foundation

/// I-02 (owner intake 2026-08-01): commit diffs were UNBOUNDED — a docs-corpora
/// commit produces tens of MB of `git show` output, which froze the git panel
/// (the subprocess ran on the main thread) and then choked the diff renderer
/// ("no diff shown, file tree frozen"). The subprocess now runs off-main
/// (`GitLogDiffActions`); this helper bounds what reaches the `.diff` file:
/// cut at a line boundary under the byte/line caps, with an EXPLICIT truncation
/// notice prepended to the preamble — never a silent cut.
///
/// Pure + host-tested (`GitDiffBoundsTests`).
public enum GitDiffBounds {

    /// Default caps — generous for real review, far below the renderer's choke
    /// zone (the web diff already skips syntax highlighting above 8k rows; 4 MiB
    /// of unified diff is ~50k lines).
    public static let defaultMaxBytes = 4 * 1024 * 1024
    public static let defaultMaxLines = 40_000

    public struct Result: Equatable, Sendable {
        public let text: String
        public let truncated: Bool
        /// Original size in bytes (== `text.utf8.count` when not truncated).
        public let originalBytes: Int
    }

    /// Bound `body` to the caps. When truncation happens, the returned text is
    /// the largest whole-line prefix under BOTH caps, prefaced by a notice line
    /// (rendered in the diff summary's preamble block). `commandHint` names the
    /// escape hatch, e.g. `git show <sha>`.
    public static func bound(
        _ body: String,
        maxBytes: Int = defaultMaxBytes,
        maxLines: Int = defaultMaxLines,
        commandHint: String? = nil
    ) -> Result {
        let u = body.utf8
        let total = u.count

        // Fast path: under the byte cap AND (early-exit counted) the line cap.
        if total <= maxBytes {
            var newlines = 0
            var under = true
            for b in u where b == 0x0A {
                newlines += 1
                if newlines >= maxLines { under = false; break }
            }
            if under { return Result(text: body, truncated: false, originalBytes: total) }
        }

        // Walk to the last newline that keeps us under both caps.
        var lines = 0
        var bytesSeen = 0
        var lastLineEnd: String.UTF8View.Index? = nil
        var i = u.startIndex
        while i != u.endIndex {
            bytesSeen += 1
            if u[i] == 0x0A {
                lines += 1
                lastLineEnd = u.index(after: i)
                if lines >= maxLines || bytesSeen >= maxBytes { break }
            } else if bytesSeen >= maxBytes {
                break   // one giant line: cut here (lossy decode is acceptable)
            }
            i = u.index(after: i)
        }
        let cut = lastLineEnd
            ?? (i == u.endIndex ? u.endIndex : u.index(after: i))
        let prefix = String(decoding: Array(u[u.startIndex..<cut]), as: UTF8.self)

        let shownMB = String(format: "%.1f", Double(prefix.utf8.count) / 1_048_576)
        let totalMB = String(format: "%.1f", Double(total) / 1_048_576)
        var notice = "⚠ DIFF TRUNCATED — showing the first \(lines.formatted()) lines "
            + "(\(shownMB) of \(totalMB) MB)."
        if let hint = commandHint {
            notice += " Full output: \(hint)"
        }
        return Result(
            text: notice + "\n\n" + prefix,
            truncated: true,
            originalBytes: total)
    }
}
