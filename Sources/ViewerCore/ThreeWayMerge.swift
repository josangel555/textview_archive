import Foundation

/// Pure, host-testable three-way (diff3) merge model — the FOUNDATION slice of
/// the 3-way merge feature (TSK-712). Given a common `base` plus two divergent
/// versions (`ours`, `theirs`), it computes the line-classified merge regions
/// and a clean auto-merge result wherever the two sides don't conflict.
///
/// This is the classic diff3 algorithm (Khanna/Ku熊-style, the same shape Git's
/// `merge-file` uses): independently diff `base↔ours` and `base↔theirs` against
/// the base, then walk both alignments in lockstep to carve the base into
/// *stable* spans (matched by BOTH sides) and *unstable* chunks (changed by at
/// least one side). Each unstable chunk is classified:
///
/// - `.oursOnly`   — only `ours` diverged from base (take ours).
/// - `.theirsOnly` — only `theirs` diverged (take theirs).
/// - `.bothSame`   — both sides made the *identical* edit (no conflict; take it).
/// - `.conflict`   — both sides diverged differently (carries base/ours/theirs).
///
/// `unchanged` regions reproduce the base verbatim. `autoMerged` succeeds (a
/// non-nil line array) iff there are NO `.conflict` regions; otherwise the
/// caller renders the conflict regions for resolution.
///
/// SwiftUI/AppKit-free on purpose: the 3-pane resolve UI is the VM tail
/// (TSK-712 follow-ups). This is the engine those panes drive.
///
/// Lines are compared by exact `String` equality. The model is line-oriented
/// (the merge unit is a line, matching `git merge-file` and every text editor's
/// conflict markers); callers split/join on `\n`.
public enum ThreeWayMerge {

    // MARK: - Region model

    /// One classified span of the merged document.
    public enum Region: Equatable, Sendable {
        /// Lines identical across base/ours/theirs in this span (verbatim base).
        case unchanged([String])
        /// Only `ours` diverged from base here; `lines` is the ours text to take.
        case oursOnly(lines: [String])
        /// Only `theirs` diverged from base here; `lines` is the theirs text.
        case theirsOnly(lines: [String])
        /// Both sides made the SAME edit (no conflict); `lines` is that edit.
        case bothSame(lines: [String])
        /// Both sides diverged differently — an unresolved conflict carrying the
        /// three slices so a resolve UI can show base/ours/theirs.
        case conflict(base: [String], ours: [String], theirs: [String])

        /// Whether this region is an unresolved conflict.
        public var isConflict: Bool {
            if case .conflict = self { return true }
            return false
        }
    }

    /// The full merge outcome.
    public struct Result: Equatable, Sendable {
        /// The classified regions, in document order.
        public let regions: [Region]

        public init(regions: [Region]) {
            self.regions = regions
        }

        /// `true` iff at least one region is an unresolved conflict.
        public var hasConflicts: Bool {
            regions.contains { $0.isConflict }
        }

        /// The number of conflict regions.
        public var conflictCount: Int {
            regions.reduce(0) { $0 + ($1.isConflict ? 1 : 0) }
        }

        /// The clean auto-merge as a flat line array, or `nil` if any region is
        /// a conflict. Each region contributes its chosen lines:
        /// unchanged → base; oursOnly → ours; theirsOnly → theirs;
        /// bothSame → the shared edit.
        public var autoMerged: [String]? {
            guard !hasConflicts else { return nil }
            var out: [String] = []
            for region in regions {
                switch region {
                case .unchanged(let l), .oursOnly(let l), .theirsOnly(let l), .bothSame(let l):
                    out.append(contentsOf: l)
                case .conflict:
                    return nil  // unreachable given the guard, but keeps the switch total
                }
            }
            return out
        }

        /// Render the auto-merge (or a conflict-marked document if conflicts
        /// remain) as a single string joined by `\n`. Conflict regions emit the
        /// standard `<<<<<<< / ======= / >>>>>>>` markers (with an optional `|||||||`
        /// base section, diff3 style) so the output is git-compatible.
        public func text(
            oursLabel: String = "ours",
            theirsLabel: String = "theirs",
            baseLabel: String = "base",
            includeBaseInConflict: Bool = false
        ) -> String {
            var out: [String] = []
            for region in regions {
                switch region {
                case .unchanged(let l), .oursOnly(let l), .theirsOnly(let l), .bothSame(let l):
                    out.append(contentsOf: l)
                case .conflict(let base, let ours, let theirs):
                    out.append("<<<<<<< \(oursLabel)")
                    out.append(contentsOf: ours)
                    if includeBaseInConflict {
                        out.append("||||||| \(baseLabel)")
                        out.append(contentsOf: base)
                    }
                    out.append("=======")
                    out.append(contentsOf: theirs)
                    out.append(">>>>>>> \(theirsLabel)")
                }
            }
            return out.joined(separator: "\n")
        }
    }

    // MARK: - Public entry points

    /// Compute the three-way merge of `base`, `ours`, `theirs` (each a line
    /// array). Returns the classified regions + auto-merge.
    public static func merge(base: [String], ours: [String], theirs: [String]) -> Result {
        let regions = computeRegions(base: base, ours: ours, theirs: theirs)
        return Result(regions: coalesce(regions))
    }

    /// Convenience: merge three `\n`-joined strings. Splits on `\n` (a trailing
    /// newline yields a trailing empty line, matching `String.split`-free
    /// `components(separatedBy:)`), merges, and returns the `Result`.
    public static func merge(base: String, ours: String, theirs: String) -> Result {
        merge(
            base: base.isEmpty ? [] : base.components(separatedBy: "\n"),
            ours: ours.isEmpty ? [] : ours.components(separatedBy: "\n"),
            theirs: theirs.isEmpty ? [] : theirs.components(separatedBy: "\n"))
    }

    // MARK: - diff3 core

    /// A maximal run aligning base lines `[baseStart, baseEnd)` against a side's
    /// lines `[sideStart, sideEnd)`. `matched` runs are common subsequence
    /// anchors (verbatim, equal-length on both); non-matched runs are the side's
    /// divergence over that base span.
    private struct Chunk {
        let baseRange: Range<Int>
        let sideRange: Range<Int>
        /// `true` when this chunk is a common (unchanged) anchor span.
        let matched: Bool
    }

    /// The diff3 walk. Mirrors the canonical algorithm: build the LCS-based
    /// alignment of base↔ours and base↔theirs, then sweep the base from start to
    /// end, emitting stable spans (where BOTH sides match base) and unstable
    /// chunks (where at least one side diverges) classified into `Region`s.
    private static func computeRegions(base: [String], ours: [String], theirs: [String]) -> [Region] {
        // The two alignments expressed as base→side index maps over matched
        // anchors. `matchOurs[i]` = the ours index a matched base line i maps to
        // (or nil if base line i is NOT part of the common subsequence with ours).
        let matchOurs = matchMap(base: base, side: ours)
        let matchTheirs = matchMap(base: base, side: theirs)

        var regions: [Region] = []
        var bi = 0   // base cursor
        var oi = 0   // ours cursor
        var ti = 0   // theirs cursor

        while bi < base.count || oi < ours.count || ti < theirs.count {
            // A base line is STABLE iff it is a common anchor with BOTH sides AND
            // both side cursors have caught up to its mapped position — i.e. all
            // three are perfectly aligned with no pending divergence.
            if bi < base.count,
               let mo = matchOurs[bi], let mt = matchTheirs[bi],
               mo == oi, mt == ti {
                // Accumulate a maximal stable run.
                var run: [String] = []
                while bi < base.count,
                      let mo2 = matchOurs[bi], let mt2 = matchTheirs[bi],
                      mo2 == oi, mt2 == ti {
                    run.append(base[bi])
                    bi += 1; oi += 1; ti += 1
                }
                regions.append(.unchanged(run))
                continue
            }

            // Otherwise we are at the head of an unstable chunk. Find the next
            // base index that is a stable anchor for BOTH sides — that's where
            // the chunk ends. Everything from the current cursors up to that
            // alignment point is the divergent slice.
            let (nextBase, nextOurs, nextTheirs) =
                nextStable(from: bi, oi: oi, ti: ti,
                           base: base, ours: ours, theirs: theirs,
                           matchOurs: matchOurs, matchTheirs: matchTheirs)

            let baseSlice = Array(base[bi..<nextBase])
            let oursSlice = Array(ours[oi..<nextOurs])
            let theirsSlice = Array(theirs[ti..<nextTheirs])

            regions.append(classify(base: baseSlice, ours: oursSlice, theirs: theirsSlice))

            bi = nextBase; oi = nextOurs; ti = nextTheirs
        }

        return regions
    }

    /// Classify one divergent chunk. The slices are the base/ours/theirs lines
    /// that fall between two stable anchors.
    private static func classify(base: [String], ours: [String], theirs: [String]) -> Region {
        let oursChanged = ours != base
        let theirsChanged = theirs != base

        switch (oursChanged, theirsChanged) {
        case (false, false):
            // Neither changed — pure context (can happen for a leading/trailing
            // empty unstable span); emit as unchanged.
            return .unchanged(base)
        case (true, false):
            return .oursOnly(lines: ours)
        case (false, true):
            return .theirsOnly(lines: theirs)
        case (true, true):
            // Both diverged. Identical divergence is a clean "both made the same
            // edit"; differing divergence is a real conflict.
            if ours == theirs {
                return .bothSame(lines: ours)
            }
            return .conflict(base: base, ours: ours, theirs: theirs)
        }
    }

    /// Find the next base index (>= `bi`) that is a stable anchor for BOTH sides,
    /// returning the aligned `(baseIdx, oursIdx, theirsIdx)` at that point. If no
    /// further common anchor exists, returns the ends of all three arrays (the
    /// whole tail is one unstable chunk).
    private static func nextStable(
        from bi: Int, oi: Int, ti: Int,
        base: [String], ours: [String], theirs: [String],
        matchOurs: [Int?], matchTheirs: [Int?]
    ) -> (Int, Int, Int) {
        var b = bi
        while b < base.count {
            if let mo = matchOurs[b], let mt = matchTheirs[b], mo >= oi, mt >= ti {
                // base[b] is a common anchor reachable from both side cursors.
                return (b, mo, mt)
            }
            b += 1
        }
        return (base.count, ours.count, theirs.count)
    }

    /// Build a base→side index map over the longest common subsequence of
    /// `base` and `side` (line-exact). `result[i]` is the side index that base
    /// line `i` matches in the LCS alignment, or `nil` if base line `i` is not
    /// in the common subsequence.
    private static func matchMap(base: [String], side: [String]) -> [Int?] {
        let n = base.count
        let m = side.count
        var map = [Int?](repeating: nil, count: n)
        guard n > 0, m > 0 else { return map }

        // Standard O(n·m) LCS DP. n,m are bounded by file line counts; the diff3
        // foundation targets source files where this is comfortable. (A
        // Myers/Hunt-Szymanski upgrade is a perf follow-up, tracked separately.)
        // dp[i][j] = LCS length of base[i...] and side[j...].
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if base[i] == side[j] {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        // Backtrack to recover the alignment.
        var i = 0, j = 0
        while i < n, j < m {
            if base[i] == side[j] {
                map[i] = j
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return map
    }

    /// Merge adjacent same-flavored regions (the stable-run accumulator already
    /// coalesces `.unchanged`, but classified chunks can abut another chunk of
    /// the same kind across a zero-length stable boundary). Keeps the region
    /// list minimal so callers iterate the fewest spans.
    private static func coalesce(_ regions: [Region]) -> [Region] {
        var out: [Region] = []
        for r in regions {
            // Drop empty regions (an unstable span can degenerate to all-empty
            // slices at the document edges).
            if isEmpty(r) { continue }
            if let last = out.last, let merged = mergeIfSameKind(last, r) {
                out[out.count - 1] = merged
            } else {
                out.append(r)
            }
        }
        return out
    }

    private static func isEmpty(_ r: Region) -> Bool {
        switch r {
        case .unchanged(let l), .oursOnly(let l), .theirsOnly(let l), .bothSame(let l):
            return l.isEmpty
        case .conflict(let b, let o, let t):
            return b.isEmpty && o.isEmpty && t.isEmpty
        }
    }

    private static func mergeIfSameKind(_ a: Region, _ b: Region) -> Region? {
        switch (a, b) {
        case (.unchanged(let x), .unchanged(let y)): return .unchanged(x + y)
        case (.oursOnly(let x), .oursOnly(let y)): return .oursOnly(lines: x + y)
        case (.theirsOnly(let x), .theirsOnly(let y)): return .theirsOnly(lines: x + y)
        case (.bothSame(let x), .bothSame(let y)): return .bothSame(lines: x + y)
        case (.conflict(let b1, let o1, let t1), .conflict(let b2, let o2, let t2)):
            return .conflict(base: b1 + b2, ours: o1 + o2, theirs: t1 + t2)
        default:
            return nil
        }
    }
}
