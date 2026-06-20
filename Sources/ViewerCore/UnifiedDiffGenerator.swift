import Foundation

/// Produces standard **unified-diff TEXT** from two in-memory strings — the
/// capability the Local-History side of the unified version viewer needs that
/// git gives us for free (`git diff`) but a pair of buffer strings does not.
///
/// Why this exists (rethink, TSK-1103): the shared diff renderer (`DiffView`)
/// consumes unified-diff *text*, which it then parses via `RustDiffAdapter`
/// (rust-core). rust-core only *parses* diff text — it cannot diff two arbitrary
/// strings — and we add no new dependencies. So this is a small, dependency-free
/// Swift line-diff that emits the EXACT dialect `RustDiffAdapter.parse` already
/// handles (`diff --git a/… b/…`, `--- a/…`, `+++ b/…`, `@@ -a,b +c,d @@`, and
/// ` `/`+`/`-`/`\` line prefixes). A generate→parse round-trip is host-tested,
/// so both back-ends (LocalHistory + Git) feed the same renderer.
///
/// Algorithm: line-granularity longest-common-subsequence (Hunt–Szymanski-style
/// via a classic DP/backtrack). Line diffs are what the viewer shows; we don't
/// need character-level. Output is grouped into hunks with a configurable
/// context radius (default 3, matching git's default).
///
/// Pure + `Sendable`-friendly (an enum of static funcs, no state) → fully
/// host-testable.
public enum UnifiedDiffGenerator {

    /// Number of unchanged context lines to keep around each change run when
    /// grouping into hunks (git's default is 3).
    public static let defaultContext = 3

    /// Generate unified-diff text for `old` → `new`, labelled with `path`
    /// (used in the `--- a/<path>` / `+++ b/<path>` headers so the renderer
    /// shows a filename). Returns "" when the two strings are identical (no
    /// diff to show — the renderer then displays its empty state).
    ///
    /// `path` should be a display path (a leaf name like `notes.md` is fine);
    /// it is NOT interpreted, only echoed into the headers.
    public static func generate(
        old: String, new: String, path: String,
        context: Int = defaultContext
    ) -> String {
        if old == new { return "" }

        let oldLines = splitLines(old)
        let newLines = splitLines(new)

        let ops = diffOps(oldLines.lines, newLines.lines)
        let hunks = groupHunks(ops, context: max(0, context))
        if hunks.isEmpty { return "" }

        var out = "diff --git a/\(path) b/\(path)\n"
        out += "--- a/\(path)\n"
        out += "+++ b/\(path)\n"
        for hunk in hunks {
            out += render(
                hunk: hunk,
                oldLines: oldLines, newLines: newLines)
        }
        return out
    }

    // MARK: - Line splitting (newline-aware)

    /// A file's lines plus whether the file ended WITHOUT a trailing newline —
    /// needed to emit the `\ No newline at end of file` marker faithfully so the
    /// round-trip is exact.
    struct Lines {
        let lines: [String]
        /// True when the original text did NOT end in "\n" (and is non-empty),
        /// i.e. the last line has no terminating newline.
        let lastLineHasNoNewline: Bool
    }

    /// Split into logical lines WITHOUT the trailing "\n". A trailing newline
    /// does NOT create a phantom empty final line (git semantics): "a\n" → ["a"]
    /// with a trailing newline; "a" → ["a"] with `lastLineHasNoNewline`.
    static func splitLines(_ text: String) -> Lines {
        if text.isEmpty { return Lines(lines: [], lastLineHasNoNewline: false) }
        let endsWithNewline = text.hasSuffix("\n")
        // Split on "\n"; if the text ends in "\n" the split yields a trailing
        // "" we must drop (it's the terminator, not a line).
        var parts = text.components(separatedBy: "\n")
        if endsWithNewline {
            parts.removeLast()   // drop the empty terminator element
        }
        return Lines(lines: parts, lastLineHasNoNewline: !endsWithNewline)
    }

    // MARK: - LCS diff

    /// One diff operation over line indices.
    enum Op: Equatable {
        case equal(oldIndex: Int, newIndex: Int)
        case delete(oldIndex: Int)
        case insert(newIndex: Int)
    }

    /// Classic LCS DP + backtrack over lines. O(n·m) memory/time — fine for the
    /// file sizes Local History caps at (text-only, ≤ tens of thousands of
    /// lines); the viewer never diffs giant binaries.
    static func diffOps(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        if n == 0 { return (0..<m).map { .insert(newIndex: $0) } }
        if m == 0 { return (0..<n).map { .delete(oldIndex: $0) } }

        // dp[i][j] = LCS length of a[i...] and b[j...].
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var ops: [Op] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                ops.append(.equal(oldIndex: i, newIndex: j))
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                ops.append(.delete(oldIndex: i))
                i += 1
            } else {
                ops.append(.insert(newIndex: j))
                j += 1
            }
        }
        while i < n { ops.append(.delete(oldIndex: i)); i += 1 }
        while j < m { ops.append(.insert(newIndex: j)); j += 1 }
        return ops
    }

    // MARK: - Hunk grouping

    /// A contiguous run of ops that forms one `@@ … @@` hunk: a slice of the op
    /// list bounded by up-to-`context` equal lines on each side.
    struct Hunk {
        let ops: [Op]
        let oldStart: Int   // 1-based first old line in the hunk
        let oldCount: Int
        let newStart: Int   // 1-based first new line in the hunk
        let newCount: Int
    }

    /// Group the flat op list into hunks. Equal ops more than `context` away
    /// from any change are dropped; equal ops within `context` are kept as the
    /// surrounding context. Adjacent change runs whose context windows overlap
    /// are merged into one hunk (git behavior).
    static func groupHunks(_ ops: [Op], context: Int) -> [Hunk] {
        // Indices of changed ops (insert/delete).
        let changedIdx = ops.indices.filter {
            if case .equal = ops[$0] { return false }
            return true
        }
        if changedIdx.isEmpty { return [] }

        // Build merged [lo, hi] op-index windows around each change run.
        var windows: [(lo: Int, hi: Int)] = []
        for idx in changedIdx {
            let lo = max(0, idx - context)
            let hi = min(ops.count - 1, idx + context)
            if var last = windows.last, lo <= last.hi + 1 {
                last.hi = max(last.hi, hi)
                windows[windows.count - 1] = last
            } else {
                windows.append((lo, hi))
            }
        }

        var hunks: [Hunk] = []
        for w in windows {
            let slice = Array(ops[w.lo...w.hi])
            // Compute 1-based start lines + counts from the op coordinates.
            var oldStart: Int?, newStart: Int?
            var oldCount = 0, newCount = 0
            for op in slice {
                switch op {
                case .equal(let oi, let ni):
                    if oldStart == nil { oldStart = oi + 1 }
                    if newStart == nil { newStart = ni + 1 }
                    oldCount += 1; newCount += 1
                case .delete(let oi):
                    if oldStart == nil { oldStart = oi + 1 }
                    oldCount += 1
                case .insert(let ni):
                    if newStart == nil { newStart = ni + 1 }
                    newCount += 1
                }
            }
            // A hunk that is all-insert has no old line; git emits oldStart =
            // (line before insert) with count 0. Likewise all-delete on the new
            // side. Use the conventional fallbacks.
            hunks.append(Hunk(
                ops: slice,
                oldStart: oldStart ?? (oldCount == 0 ? newStartFallback(slice) : 1),
                oldCount: oldCount,
                newStart: newStart ?? (newCount == 0 ? oldStartFallback(slice) : 1),
                newCount: newCount))
        }
        return hunks
    }

    /// For an all-insert hunk, git anchors oldStart at the new-side line minus
    /// one (the position after which lines are inserted). We approximate with
    /// the first new index (0 → 0 start, otherwise the index).
    private static func newStartFallback(_ slice: [Op]) -> Int {
        for op in slice {
            if case .insert(let ni) = op { return ni }   // 0-based → git's "insert after"
        }
        return 0
    }

    private static func oldStartFallback(_ slice: [Op]) -> Int {
        for op in slice {
            if case .delete(let oi) = op { return oi }
        }
        return 0
    }

    // MARK: - Render

    private static func render(hunk: Hunk, oldLines: Lines, newLines: Lines) -> String {
        var out = "@@ -\(coords(hunk.oldStart, hunk.oldCount)) "
        out += "+\(coords(hunk.newStart, hunk.newCount)) @@\n"

        for op in hunk.ops {
            switch op {
            case .equal(let oi, _):
                out += " \(oldLines.lines[oi])\n"
                out += noNewlineMarkerIfNeeded(
                    forOldIndex: oi, oldLines: oldLines)
            case .delete(let oi):
                out += "-\(oldLines.lines[oi])\n"
                out += noNewlineMarkerIfNeeded(
                    forOldIndex: oi, oldLines: oldLines)
            case .insert(let ni):
                out += "+\(newLines.lines[ni])\n"
                out += noNewlineMarkerIfNeeded(
                    forNewIndex: ni, newLines: newLines)
            }
        }
        return out
    }

    /// Git's coordinate convention: "start,count", but a count of exactly 1 is
    /// written as just "start", and a count of 0 is written as "start,0".
    private static func coords(_ start: Int, _ count: Int) -> String {
        if count == 1 { return "\(start)" }
        return "\(start),\(count)"
    }

    /// Emit `\ No newline at end of file` after the LAST line of the OLD file
    /// when that file had no trailing newline.
    private static func noNewlineMarkerIfNeeded(forOldIndex i: Int, oldLines: Lines) -> String {
        guard oldLines.lastLineHasNoNewline, i == oldLines.lines.count - 1 else { return "" }
        return "\\ No newline at end of file\n"
    }

    private static func noNewlineMarkerIfNeeded(forNewIndex i: Int, newLines: Lines) -> String {
        guard newLines.lastLineHasNoNewline, i == newLines.lines.count - 1 else { return "" }
        return "\\ No newline at end of file\n"
    }
}
