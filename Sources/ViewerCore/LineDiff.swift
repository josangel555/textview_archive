import Foundation

/// A dependency-free line-level diff engine (TSK-1103).
///
/// The repo's `RustDiffAdapter` / `UnifiedDiff` path only *parses* an
/// already-generated unified diff (`git diff` text) — it cannot *compute* a
/// diff between two arbitrary in-memory strings, which Local History needs for
/// two things: (1) storing a compact delta between consecutive versions, and
/// (2) showing the UI a structured diff between any two versions (or a version
/// and the live buffer). Rather than pull in a diff dependency, this is a small,
/// self-contained line differ built on the diffutils/git-standard pipeline.
///
/// ## Algorithm (the optimal, memory-safe core — TSK-1103)
///
/// The original implementation used a full `(n+1)×(m+1)` Int DP matrix for the
/// LCS — **O(n·m) MEMORY**. A storage test diffing two ~262k-line versions
/// ballooned `phys_footprint` to ~77 GB (a ~550 GB nominal matrix, OS-compressed)
/// and nearly OOM'd the machine. This is replaced by the standard diff pipeline:
///
///   1. **Trim common prefix + suffix first** (O(N)). A typical save edits a few
///      lines in a large file; trimming collapses the diff to the changed middle
///      region, so N shrinks dramatically before any heavy work runs.
///   2. **Intern lines → `Int` ids** (`Interner`). Each unique line is hashed
///      once into a dense `Int` id; the diff then compares `Int`s, not `String`s
///      — cutting both memory (no per-cell strings) and per-compare cost, and
///      sidestepping hash-collision worries (equal id ⟺ equal line, exactly).
///   3. **Core diff = Myers O(N·D) with the LINEAR-SPACE divide-and-conquer
///      refinement** — the middle-snake / Hirschberg-style recursion from
///      Eugene Myers, *"An O(ND) Difference Algorithm and Its Variations"* §4b.
///      Time is **O(N·D)** (N = total trimmed length, D = edit-script size —
///      output-sensitive: a tiny edit is near-linear); space is **O(N)** for the
///      two forward/backward `V` strips. NO O(n·m) matrix is ever allocated.
///
/// The storage engine adds a product-layer **size-guard** (route a large /
/// near-full change to a full SNAPSHOT *before* calling `Patch.between`), so the
/// diff only ever runs on small-to-moderate changes — and even then it is O(N)
/// memory. See `LocalHistoryStore`.
///
/// Two faces sit on the same core:
///   - `hunks(from:to:)` → grouped, context-bearing `[DiffHunk]` for the UI.
///   - `Patch.between(_:_:)` / `Patch.apply(to:)` → a compact, *serialisable*
///     line patch for on-disk delta storage with deterministic reconstruction.
///
/// Lines are split on `\n` keeping a final empty element when the text ends in a
/// newline, so the split is **lossless**: `lines(of:).joined("\n") == text`. The
/// patch round-trips exactly for any UTF-8 text (proven by the tests).
public enum LineDiff {

    // MARK: - Public hunk model (for the UI)

    /// One changed line within a hunk.
    public struct Line: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            case context   // unchanged, shown for orientation
            case added     // present only in the new text
            case removed   // present only in the old text
        }
        public let kind: Kind
        /// 1-based line number in the OLD text, or nil for an added line.
        public let oldLineNo: Int?
        /// 1-based line number in the NEW text, or nil for a removed line.
        public let newLineNo: Int?
        /// The line's text (without its trailing newline).
        public let content: String

        public init(kind: Kind, oldLineNo: Int?, newLineNo: Int?, content: String) {
            self.kind = kind
            self.oldLineNo = oldLineNo
            self.newLineNo = newLineNo
            self.content = content
        }
    }

    /// A contiguous run of changes plus its surrounding context lines, in the
    /// shape a unified-diff viewer wants. Mirrors `UnifiedDiff.Hunk` so the
    /// existing `DiffView` data-model intuition carries over, but this one is
    /// *computed* from two texts rather than parsed.
    public struct DiffHunk: Equatable, Sendable {
        public let oldStart: Int   // 1-based first old line in the hunk
        public let oldCount: Int
        public let newStart: Int   // 1-based first new line in the hunk
        public let newCount: Int
        public let lines: [Line]

        public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [Line]) {
            self.oldStart = oldStart
            self.oldCount = oldCount
            self.newStart = newStart
            self.newCount = newCount
            self.lines = lines
        }
    }

    // MARK: - Serialisable patch (for on-disk delta storage)

    /// A compact, deterministic line patch that transforms one text into
    /// another. Encoded as a tiny line-oriented text format (NOT JSON — keeps it
    /// small and append-friendly) so a stored delta is as compact as possible:
    ///
    /// ```
    /// @ <oldIndex> <deleteCount> <insertCount>
    /// +inserted line 1
    /// +inserted line 2
    /// @ <oldIndex> <deleteCount> <insertCount>
    /// ...
    /// ```
    ///
    /// `oldIndex` is 0-based into the OLD line array; ops are emitted in
    /// ascending order and applied in one forward pass. `+`-prefixed lines carry
    /// the inserted text (the `+` is a literal frame char, stripped on decode).
    /// Deletions need no payload (just the count). `apply` reconstructs the new
    /// text byte-for-byte.
    public struct Patch: Equatable, Sendable {
        /// One edit: at old-line `index`, drop `delete` old lines and splice in
        /// `insert`.
        public struct Op: Equatable, Sendable {
            public let index: Int       // 0-based into old lines
            public let delete: Int
            public let insert: [String]
            public init(index: Int, delete: Int, insert: [String]) {
                self.index = index
                self.delete = delete
                self.insert = insert
            }
        }
        public let ops: [Op]

        public init(ops: [Op]) { self.ops = ops }

        /// The patch that turns `old` into `new`.
        ///
        /// Pipeline: split → trim common prefix/suffix → intern → Myers
        /// linear-space edit script over the middle → coalesce each run of
        /// deletions+insertions between two kept anchors into one `Op`.
        public static func between(_ old: String, _ new: String) -> Patch {
            let o = lines(of: old)
            let n = lines(of: new)
            // `matched(...)` returns the kept (oldIdx, newIdx) anchor pairs in
            // ascending order — the LCS of the two line arrays.
            let matches = matched(o, n)
            var ops: [Op] = []
            var oi = 0, ni = 0
            // Walk both, anchored by matched (kept) pairs; a run of old-only +
            // new-only between two anchors becomes ONE op (delete k, insert m).
            for (mo, mn) in matches + [(o.count, n.count)] {
                let del = mo - oi
                var ins: [String] = []
                ins.reserveCapacity(mn - ni)
                while ni < mn { ins.append(n[ni]); ni += 1 }
                if del > 0 || !ins.isEmpty {
                    ops.append(Op(index: oi, delete: del, insert: ins))
                }
                oi = mo
                // Consume the matched pair (skip the kept line on both sides).
                if mo < o.count { oi += 1; ni += 1 }
            }
            return Patch(ops: ops)
        }

        /// Apply this patch to `old`, returning the reconstructed text. Returns
        /// nil if the patch doesn't fit `old` (out-of-range op) — the caller
        /// then treats the stored delta as corrupt and degrades gracefully.
        public func apply(to old: String) -> String? {
            let o = lines(of: old)
            var out: [String] = []
            var cursor = 0
            for op in ops {
                guard op.index >= cursor, op.index <= o.count else { return nil }
                // Copy untouched old lines up to the op.
                out.append(contentsOf: o[cursor..<op.index])
                cursor = op.index
                guard cursor + op.delete <= o.count else { return nil }
                cursor += op.delete            // skip deleted old lines
                out.append(contentsOf: op.insert)
            }
            guard cursor <= o.count else { return nil }
            out.append(contentsOf: o[cursor...])
            return out.joined(separator: "\n")
        }

        // MARK: Serialisation

        /// Encode to the compact line format described on `Patch`.
        public func serialized() -> String {
            var s = ""
            for op in ops {
                s += "@ \(op.index) \(op.delete) \(op.insert.count)\n"
                for line in op.insert {
                    // Frame each inserted line with a leading '+'. A line never
                    // contains '\n' (it came from `lines(of:)` which split on
                    // '\n'), so one inserted line == one encoded row — no
                    // ambiguity.
                    s += "+" + line + "\n"
                }
            }
            return s
        }

        /// Decode the compact line format. Returns nil on a malformed blob.
        public static func deserialize(_ text: String) -> Patch? {
            var ops: [Op] = []
            let rows = lines(of: text)
            var i = 0
            while i < rows.count {
                let row = rows[i]
                if row.isEmpty { i += 1; continue }
                guard row.hasPrefix("@ ") else { return nil }
                let parts = row.dropFirst(2).split(separator: " ", maxSplits: 2,
                                                    omittingEmptySubsequences: false)
                guard parts.count == 3,
                      let index = Int(parts[0]),
                      let delete = Int(parts[1]),
                      let insCount = Int(parts[2]),
                      index >= 0, delete >= 0, insCount >= 0 else { return nil }
                i += 1
                var ins: [String] = []
                ins.reserveCapacity(insCount)
                var k = 0
                while k < insCount {
                    guard i < rows.count, rows[i].hasPrefix("+") else { return nil }
                    ins.append(String(rows[i].dropFirst()))
                    i += 1; k += 1
                }
                ops.append(Op(index: index, delete: delete, insert: ins))
            }
            return Patch(ops: ops)
        }
    }

    // MARK: - UI-facing hunks

    /// Compute grouped, context-bearing hunks transforming `old` into `new`.
    /// `context` is the number of unchanged lines to keep around each change run
    /// (3 is the unified-diff convention). Identical inputs ⇒ no hunks.
    public static func hunks(from old: String, to new: String, context: Int = 3) -> [DiffHunk] {
        let o = lines(of: old)
        let n = lines(of: new)
        let matchByOld = Dictionary(uniqueKeysWithValues: matched(o, n).map { ($0.0, $0.1) })
        // Build a flat per-line edit script first (context/added/removed), then
        // group contiguous changes (+ surrounding context) into hunks.
        var script: [Line] = []
        var oi = 0, ni = 0
        while oi < o.count || ni < n.count {
            if oi < o.count, ni < n.count, matchByOld[oi] == ni {
                script.append(Line(kind: .context, oldLineNo: oi + 1, newLineNo: ni + 1, content: o[oi]))
                oi += 1; ni += 1
            } else if oi < o.count, matchByOld[oi] == nil {
                script.append(Line(kind: .removed, oldLineNo: oi + 1, newLineNo: nil, content: o[oi]))
                oi += 1
            } else if ni < n.count {
                script.append(Line(kind: .added, oldLineNo: nil, newLineNo: ni + 1, content: n[ni]))
                ni += 1
            } else {
                // oi is matched to a later ni; emit it as removed to make
                // progress (defensive — shouldn't happen with a valid LCS).
                script.append(Line(kind: .removed, oldLineNo: oi + 1, newLineNo: nil, content: o[oi]))
                oi += 1
            }
        }
        return group(script, context: context)
    }

    // MARK: - Lossless line splitting

    /// Split `text` into lines on `\n`, lossless: a trailing newline yields a
    /// final empty element, so `lines(of:).joined("\n") == text` for any input.
    static func lines(of text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    // MARK: - Diff core: prefix/suffix trim + interning + Myers linear-space

    /// Longest common subsequence of two line arrays as matched
    /// `(oldIndex, newIndex)` pairs in ascending order — the kept anchors both
    /// the `Patch` and the hunk builder walk against.
    ///
    /// Strategy (diffutils/git pipeline):
    ///   1. Trim the common prefix and suffix (each kept pair is trivially an
    ///      anchor) — O(N), and usually shrinks the heavy region to a handful of
    ///      lines for a typical edit.
    ///   2. Intern the changed middle to `Int` ids (equal id ⟺ equal line).
    ///   3. Run the **linear-space Myers** middle-snake recursion over the ids to
    ///      produce the matched pairs of the middle, offset back into the full
    ///      arrays.
    /// Time O(N·D), space O(N) — no O(n·m) matrix.
    static func matched(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        if n == 0 || m == 0 { return [] }

        // 1) Common prefix.
        var lo = 0
        let maxPrefix = min(n, m)
        while lo < maxPrefix && a[lo] == b[lo] { lo += 1 }

        // 2) Common suffix (not overlapping the prefix).
        var aHi = n, bHi = m
        while aHi > lo && bHi > lo && a[aHi - 1] == b[bHi - 1] { aHi -= 1; bHi -= 1 }

        var matches: [(Int, Int)] = []
        matches.reserveCapacity(lo + (n - aHi))

        // Prefix pairs are anchors as-is.
        for k in 0..<lo { matches.append((k, k)) }

        // 3) Middle region [lo, aHi) × [lo, bHi). If either side is empty the
        // middle is a pure insert/delete — no anchors there.
        let midA = Array(a[lo..<aHi])
        let midB = Array(b[lo..<bHi])
        if !midA.isEmpty && !midB.isEmpty {
            // Intern the middle (both sides share one id space).
            var interner = Interner()
            let ia = midA.map { interner.id(for: $0) }
            let ib = midB.map { interner.id(for: $0) }
            var midMatches: [(Int, Int)] = []
            midMatches.reserveCapacity(min(ia.count, ib.count))
            ia.withUnsafeBufferPointer { ap in
                ib.withUnsafeBufferPointer { bp in
                    myersMiddleSnake(ap, 0, ap.count, bp, 0, bp.count, into: &midMatches)
                }
            }
            // Offset middle anchors back into the full arrays.
            for (i, j) in midMatches { matches.append((i + lo, j + lo)) }
        }

        // Suffix pairs are anchors as-is.
        for k in 0..<(n - aHi) { matches.append((aHi + k, bHi + k)) }

        return matches
    }

    /// Dense line→`Int` interner: each distinct line string gets a unique,
    /// stable-within-this-diff `Int` id, so the core diff compares `Int`s. Equal
    /// id ⟺ equal line (no hash collisions to confirm), and the dictionary holds
    /// each unique line once instead of per-cell.
    struct Interner {
        private var map: [String: Int] = [:]
        private var next = 0
        mutating func id(for line: String) -> Int {
            if let existing = map[line] { return existing }
            let id = next
            map[line] = id
            next += 1
            return id
        }
    }

    /// The middle snake of an edit-graph region, in coordinates RELATIVE to the
    /// region origin. The optimal path through the region passes through the
    /// diagonal run `(x, y) … (u, v)` (the snake); `[x,u)` × `[y,v)` is its kept
    /// portion. `d` is the region's total edit distance (0 ⇒ identical region).
    private struct Snake {
        var x: Int, y: Int, u: Int, v: Int, d: Int
    }

    /// Linear-space Myers diff (the divide-and-conquer §4b refinement). Finds the
    /// middle snake of `a[aLo..<aHi]` × `b[bLo..<bHi]`, recurses on the top-left
    /// sub-rectangle, emits the snake's kept diagonal, then recurses on the
    /// bottom-right — in order, so `out` (matched `(i, j)` pairs, in FULL-array
    /// coordinates) stays ascending.
    ///
    /// Space: two `V` strips reused per recursion frame, O(N). Time: O(N·D).
    /// NO O(n·m) matrix is ever allocated.
    private static func myersMiddleSnake(
        _ a: UnsafeBufferPointer<Int>, _ aLo: Int, _ aHi: Int,
        _ b: UnsafeBufferPointer<Int>, _ bLo: Int, _ bHi: Int,
        into out: inout [(Int, Int)]
    ) {
        let nA = aHi - aLo
        let nB = bHi - bLo

        // Base cases.
        if nA == 0 || nB == 0 { return }           // pure insert/delete, no anchors
        if nA == 1 && nB == 1 {
            if a[aLo] == b[bLo] { out.append((aLo, bLo)) }
            return
        }

        let s = middleSnake(a, aLo, aHi, b, bLo, bHi)

        if s.d > 1 {
            // Snake coords are region-relative; lift to FULL-array coords.
            myersMiddleSnake(a, aLo, aLo + s.x, b, bLo, bLo + s.y, into: &out)
            var i = aLo + s.x, j = bLo + s.y
            let iEnd = aLo + s.u, jEnd = bLo + s.v
            while i < iEnd && j < jEnd { out.append((i, j)); i += 1; j += 1 }
            myersMiddleSnake(a, aLo + s.u, aHi, b, bLo + s.v, bHi, into: &out)
        } else {
            // d ≤ 1: the region is identical (d=0) or a single insert/delete
            // (d=1). Either way the kept pairs are the common prefix then the
            // common suffix; emit them directly (cheaper, and bottoms out the
            // recursion cleanly).
            emitLowDistance(a, aLo, aHi, b, bLo, bHi, into: &out)
        }
    }

    /// Greedy bidirectional Myers search for the middle snake of
    /// `a[aLo..<aHi]` × `b[bLo..<bHi]` (Myers §4b). Forward paths from the
    /// top-left and backward paths from the bottom-right each advance one `d` at
    /// a time; the first time their furthest-reaching paths overlap on a diagonal
    /// is the optimal-path midpoint — that overlapping snake is returned, in
    /// region-relative coordinates. O(N) space, O(N·D) time.
    ///
    /// Both `vf` (forward) and `vb` (backward) are diagonal-indexed furthest-x
    /// strips. Forward diagonal `k = x - y` ∈ [-d, d]. Backward search runs in
    /// the REVERSED graph on diagonal `k' = (x - y) - delta` ∈ [-d, d]; the same
    /// absolute diagonal is `k = k' + delta`, so a forward result on `k` is
    /// compared to the backward strip read at the same absolute diagonal. Both
    /// strips share offset `voff` over the full diagonal span, so no negative or
    /// out-of-range index occurs.
    private static func middleSnake(
        _ a: UnsafeBufferPointer<Int>, _ aLo: Int, _ aHi: Int,
        _ b: UnsafeBufferPointer<Int>, _ bLo: Int, _ bHi: Int
    ) -> Snake {
        let n = aHi - aLo
        let m = bHi - bLo
        let delta = n - m
        let odd = (delta & 1) != 0
        // Both strips are indexed by the FORWARD diagonal k = x - y. The forward
        // search explores k ∈ [-d, d]. The backward search is run as a FORWARD
        // search on the REVERSED region (element i of a ↔ a[aHi-1-i]); a backward
        // reversed-coordinate diagonal kr ∈ [-d, d] corresponds to forward
        // diagonal k = delta - kr (because a forward point (x,y) is reversed
        // point (n-x, m-y), whose diagonal is (n-x)-(m-y) = delta - k). Both k
        // and (delta - kr) lie in [-(n+m), n+m]; reads touch k±1, so offset by
        // (n+m+1) into a strip of size 2(n+m)+3. The strip is O(N) — the space
        // bound holds (no O(n·m) matrix).
        let voff = n + m + 1
        let size = 2 * (n + m) + 3
        var vf = [Int](repeating: 0, count: size)   // forward furthest-x by diagonal k
        var vr = [Int](repeating: 0, count: size)   // reversed-forward furthest-X by kr
        vf[voff + 1] = 0
        vr[voff + 1] = 0

        let dmax = (n + m + 1) / 2
        var d = 0
        while d <= dmax {
            // ---- Forward pass: diagonals k ∈ [-d, d] step 2. ----
            var k = -d
            while k <= d {
                let i = voff + k
                var x: Int
                if k == -d || (k != d && vf[i - 1] < vf[i + 1]) {
                    x = vf[i + 1]                       // step down (insertion)
                } else {
                    x = vf[i - 1] + 1                   // step right (deletion)
                }
                var y = x - k
                let sx = x, sy = y                      // snake head (pre-extend)
                while x < n && y < m && a[aLo + x] == b[bLo + y] { x += 1; y += 1 }
                vf[i] = x
                // Odd delta: the middle snake is found on a FORWARD pass. The
                // reversed frontier on the same absolute diagonal is reachable as
                // kr = delta - k; reversed reach X means forward x' = n - X. They
                // overlap when forward x ≥ n - vr[delta - k].
                if odd {
                    let kr = delta - k
                    if kr >= -(d - 1) && kr <= (d - 1) {
                        if vf[i] + vr[voff + kr] >= n {
                            return Snake(x: sx, y: sy, u: x, v: y, d: 2 * d - 1)
                        }
                    }
                }
                k += 2
            }

            // ---- Backward pass = forward search on the REVERSED region:
            //      diagonals kr ∈ [-d, d] step 2. ----
            var kr = -d
            while kr <= d {
                let i = voff + kr
                var X: Int
                if kr == -d || (kr != d && vr[i - 1] < vr[i + 1]) {
                    X = vr[i + 1]                       // step down in reversed space
                } else {
                    X = vr[i - 1] + 1                   // step right in reversed space
                }
                var Y = X - kr
                let X0 = X, Y0 = Y                      // reversed snake start (pre-extend)
                // Extend along equal lines from the FAR end (reversed compare).
                while X < n && Y < m && a[aHi - 1 - X] == b[bHi - 1 - Y] { X += 1; Y += 1 }
                vr[i] = X
                // Even delta: the middle snake is found on a BACKWARD pass. The
                // reversed snake covers reversed-coords [X0, X); forward coords
                // map by x = n - X (and y = m - Y). The forward frontier on the
                // same absolute diagonal k = delta - kr sits at vf[voff + k];
                // they overlap when X + vf ≥ n.
                if !odd {
                    let k = delta - kr
                    if k >= -d && k <= d {
                        if X + vf[voff + k] >= n {
                            // Forward span of the snake: head (n - X, m - Y) up to
                            // tail (n - X0, m - Y0).
                            return Snake(
                                x: n - X, y: m - Y,
                                u: n - X0, v: m - Y0, d: 2 * d
                            )
                        }
                    }
                }
                kr += 2
            }
            d += 1
        }

        // Unreachable for finite inputs (the frontiers always meet by d=dmax).
        return Snake(x: 0, y: 0, u: n, v: m, d: n + m)
    }

    /// Emit kept pairs for a region of edit distance ≤ 1: common prefix, then
    /// common suffix. For d=0 the prefix covers everything; for d=1 (one insert
    /// or delete) the prefix + suffix cover all kept lines, split by the single
    /// edit. Linear, allocation-free into `out`.
    private static func emitLowDistance(
        _ a: UnsafeBufferPointer<Int>, _ aLo: Int, _ aHi: Int,
        _ b: UnsafeBufferPointer<Int>, _ bLo: Int, _ bHi: Int,
        into out: inout [(Int, Int)]
    ) {
        let n = aHi - aLo
        let m = bHi - bLo
        // Common prefix.
        var p = 0
        let pMax = Swift.min(n, m)
        while p < pMax && a[aLo + p] == b[bLo + p] { out.append((aLo + p, bLo + p)); p += 1 }
        // Common suffix (not overlapping the prefix).
        var sa = n, sb = m
        while sa > p && sb > p && a[aLo + sa - 1] == b[bLo + sb - 1] {
            sa -= 1; sb -= 1
            out.append((aLo + sa, bLo + sb))
        }
        // The suffix pairs were appended in descending order; the caller relies
        // on ascending order, so sort the tail we just added. For d≤1 this tail
        // is contiguous and small; sort the whole `out` slice we touched.
        // (Cheap correctness guard — prefix is already ascending; only suffix
        // needs reversing into place.)
        // Reverse only the suffix region we appended.
        let suffixCount = (n - sa)
        if suffixCount > 1 {
            let startIdx = out.count - suffixCount
            var lo = startIdx, hi = out.count - 1
            while lo < hi { out.swapAt(lo, hi); lo += 1; hi -= 1 }
        }
    }

    // MARK: - Private — hunk grouping

    /// Group a flat edit script into hunks: each hunk spans a run of changes
    /// plus up to `context` unchanged lines on either side. A context gap wider
    /// than `2*context+1` splits the hunk.
    private static func group(_ script: [Line], context: Int) -> [DiffHunk] {
        let changedIdx = script.indices.filter { script[$0].kind != .context }
        if changedIdx.isEmpty { return [] }

        var hunks: [DiffHunk] = []
        var i = 0
        while i < changedIdx.count {
            // Extend this hunk while the next change is within 2*context+1 of the
            // last one (so we don't split on a small context gap).
            var j = i
            while j + 1 < changedIdx.count,
                  changedIdx[j + 1] - changedIdx[j] <= (2 * context + 1) {
                j += 1
            }
            let firstChange = changedIdx[i]
            let lastChange = changedIdx[j]
            let start = max(0, firstChange - context)
            let end = min(script.count - 1, lastChange + context)
            hunks.append(makeHunk(Array(script[start...end])))
            i = j + 1
        }
        return hunks
    }

    private static func makeHunk(_ lines: [Line]) -> DiffHunk {
        let oldNos = lines.compactMap { $0.oldLineNo }
        let newNos = lines.compactMap { $0.newLineNo }
        return DiffHunk(
            oldStart: oldNos.first ?? 0,
            oldCount: oldNos.count,
            newStart: newNos.first ?? 0,
            newCount: newNos.count,
            lines: lines
        )
    }

    /// FNV-1a 64-bit over a line's UTF-8. Retained for the store's content
    /// dedup/hash header (NOT used by the diff core, which interns to dense Ints).
    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}
