import Foundation

/// Hand-written recursive-descent parser for tmux *layout strings*
/// (`%layout-change` / `display-message -p '#{window_visible_layout}'`),
/// producing the canonical typed `PaneNode` tree (see `TerminalPaneTree.swift`).
///
/// tmux's layout grammar carries per-node geometry in terminal CELLS
/// (`WIDTHxHEIGHT,X,Y`), but the renderer only needs the split TOPOLOGY plus
/// each child's *proportional share* of its container — so this parser
/// distills the cell geometry into `PaneNode` weights and discards the
/// absolute coordinates. A horizontal split (`{ … }`) lays its children
/// side-by-side, so each child's weight is its WIDTH; a vertical split
/// (`[ … ]`) stacks them, so each child's weight is its HEIGHT. When the
/// children divide their container evenly (within an epsilon), `weights` is
/// emitted as `nil` (equal split) to keep canonical trees stable for tests.
///
/// Grammar (`docs/TMUX_CC_DESIGN_2026-06-18.md` §1.4):
/// ```
/// layout  := checksum ',' node
/// checksum:= HEX HEX HEX HEX            // 4 hex digits, shape-checked only
/// node    := WxH ',' X ',' Y suffix
/// suffix  := ',' paneId                 // leaf
///          | '{' children '}'           // horizontal split (left-to-right)
///          | '[' children ']'           // vertical split (top-to-bottom)
/// children:= node (',' node)*           // one or more, comma-separated
/// WxH     := UINT 'x' UINT
/// X,Y,id,UINT := non-negative decimal integer
/// ```
///
/// Notes / design:
/// - No regex, no dependencies — a single forward pass over a `[Character]`
///   with an integer cursor.
/// - Strict: any deviation (unbalanced brackets, missing geometry, bad
///   checksum, trailing junk, empty group, integer overflow) yields `nil`
///   rather than a partial/throwing result. The public surface never throws
///   and never crashes on hostile input.
/// - The leading checksum is validated for *shape* (exactly 4 hex digits)
///   but its value is not verified — tmux's checksum is advisory and we trust
///   the transport.
public enum TmuxLayoutParser {

    /// Hard cap on split-nesting depth. The recursive-descent parser spends one
    /// stack frame per `{`/`[` level, so an UNBOUNDED depth on a hostile/garbled
    /// layout string overflows the thread stack — a hard crash (SIGILL/SIGSEGV),
    /// not a `nil`. The control stream is parsed on the PTY-pump thread (slice
    /// d), whose default stack is only ~512 KB, so the crash threshold there is
    /// ~1-2k levels, not the ~18k a fresh main thread tolerates. Real tmux
    /// layouts are shallow (a handful of splits); 256 is orders of magnitude
    /// beyond anything legitimate while keeping recursion bounded. Beyond it
    /// `parse` returns `nil` (the caller ignores the layout) rather than crash —
    /// preserving the documented "never crashes on hostile input" contract.
    private static let maxDepth = 256

    /// Parse a tmux layout string into the canonical typed `PaneNode` tree.
    /// Returns `nil` for any malformed input (the caller treats `nil` as
    /// "ignore this layout").
    public static func parse(_ layout: String) -> PaneNode? {
        var cursor = Cursor(Array(layout), maxDepth: maxDepth)

        // <checksum> ',' <node>
        guard cursor.consumeChecksum() else { return nil }
        guard cursor.expect(",") else { return nil }
        guard let parsed = cursor.parseNode() else { return nil }
        // Reject trailing junk — the layout must be fully consumed.
        guard cursor.isAtEnd else { return nil }
        return parsed.node
    }

    // MARK: - Geometry-carrying intermediate

    /// A node WITH its source cell geometry, threaded up through the recursion
    /// so a parent split can read its children's width/height to derive
    /// proportional `PaneNode.weights`. The geometry is dropped at the public
    /// boundary — only the topology + weights survive into `PaneNode`.
    private struct Sized {
        let node: PaneNode
        let w: Int
        let h: Int
    }

    // MARK: - Cursor

    /// A mutable forward cursor over the layout characters. All parsing helpers
    /// return `nil`/`false` on malformed input and leave the cursor in an
    /// unspecified position (the top-level `parse` bails on the first failure).
    private struct Cursor {
        private let chars: [Character]
        private var i: Int = 0
        /// Max nesting depth before the parser bails to `nil` (stack-overflow
        /// guard — see `TmuxLayoutParser.maxDepth`).
        private let maxDepth: Int
        /// Current nesting depth; incremented entering a group, decremented on
        /// exit. A `parseNode` at `depth > maxDepth` returns `nil`.
        private var depth: Int = 0

        init(_ chars: [Character], maxDepth: Int) {
            self.chars = chars
            self.maxDepth = maxDepth
        }

        var isAtEnd: Bool { i >= chars.count }

        private var current: Character? { i < chars.count ? chars[i] : nil }

        /// Consume `c` if it is the current character; report whether it was.
        mutating func expect(_ c: Character) -> Bool {
            guard current == c else { return false }
            i += 1
            return true
        }

        /// Consume exactly four hex digits (the advisory layout checksum).
        mutating func consumeChecksum() -> Bool {
            for _ in 0..<4 {
                guard let c = current, c.isHexDigit else { return false }
                i += 1
            }
            return true
        }

        /// Parse a non-negative decimal integer (one or more digits). Returns
        /// `nil` on no digits or on overflow.
        mutating func parseUInt() -> Int? {
            let start = i
            var value = 0
            while let c = current, c.isASCII, c.isNumber {
                guard let d = c.wholeNumberValue else { return nil }
                let (mul, ovf1) = value.multipliedReportingOverflow(by: 10)
                guard !ovf1 else { return nil }
                let (sum, ovf2) = mul.addingReportingOverflow(d)
                guard !ovf2 else { return nil }
                value = sum
                i += 1
            }
            return i > start ? value : nil
        }

        /// node := WxH ',' X ',' Y suffix → a `Sized` carrying the typed node
        /// plus its cell geometry (so the parent split can weight it).
        mutating func parseNode() -> Sized? {
            // Stack-overflow guard: bail on pathologically deep nesting before
            // the recursion exhausts the (possibly small, off-main) thread stack.
            guard depth <= maxDepth else { return nil }
            guard let w = parseUInt() else { return nil }
            guard expect("x") else { return nil }
            guard let h = parseUInt() else { return nil }
            guard expect(",") else { return nil }
            guard parseUInt() != nil else { return nil }   // X — discarded
            guard expect(",") else { return nil }
            guard parseUInt() != nil else { return nil }    // Y — discarded

            // suffix: ',' paneId (leaf) | '{' children '}' | '[' children ']'
            switch current {
            case ",":
                i += 1
                guard let id = parseUInt() else { return nil }
                return Sized(node: .leaf(paneID: TmuxPaneID(id)), w: w, h: h)
            case "{":
                guard let children = parseGroup(open: "{", close: "}") else { return nil }
                let node = TmuxLayoutParser.makeSplit(axis: .horizontal, children: children)
                return Sized(node: node, w: w, h: h)
            case "[":
                guard let children = parseGroup(open: "[", close: "]") else { return nil }
                let node = TmuxLayoutParser.makeSplit(axis: .vertical, children: children)
                return Sized(node: node, w: w, h: h)
            default:
                return nil
            }
        }

        /// children := '<open>' node (',' node)* '<close>' — at least one node.
        mutating func parseGroup(open: Character, close: Character) -> [Sized]? {
            guard expect(open) else { return nil }
            // Entering a nesting level — count it toward the depth cap so a
            // long run of `{`s can't recurse without bound. Restored on exit so
            // sibling groups don't accumulate phantom depth.
            depth += 1
            defer { depth -= 1 }
            var nodes: [Sized] = []
            // A group must hold at least one child (empty `{}`/`[]` is malformed).
            guard let first = parseNode() else { return nil }
            nodes.append(first)
            while expect(",") {
                guard let next = parseNode() else { return nil }
                nodes.append(next)
            }
            guard expect(close) else { return nil }
            return nodes
        }
    }

    // MARK: - Split construction (geometry → typed split + weights)

    /// Build a typed `.split` from sized children, deriving proportional
    /// weights from the children's extent ALONG the split axis (width for
    /// horizontal, height for vertical). Emits `nil` weights — i.e. an equal
    /// split — when the children are already even (so canonical trees stay
    /// stable), or when the geometry is degenerate (any non-positive extent).
    private static func makeSplit(axis: SplitAxis, children: [Sized]) -> PaneNode {
        let nodes = children.map(\.node)
        let extents: [Int] = children.map { axis == .horizontal ? $0.w : $0.h }
        let weights = proportionalWeights(extents)
        return .split(axis: axis, children: nodes, weights: weights)
    }

    /// Turn raw per-child cell extents into `PaneNode` weights, or `nil` when
    /// they are even / degenerate. Even is detected against the equal share so
    /// a tmux layout that happens to divide cleanly produces the same
    /// canonical tree as a hand-built equal split (test-stable). Any extent ≤ 0
    /// also collapses to `nil` (let `TerminalPaneTree` fall back to equal).
    private static func proportionalWeights(_ extents: [Int]) -> [Double]? {
        guard extents.count > 1 else { return nil }       // single child: no weighting
        guard extents.allSatisfy({ $0 > 0 }) else { return nil }
        let total = extents.reduce(0, +)
        guard total > 0 else { return nil }

        // tmux cell counts are integers; an "even" split rounds off into the
        // dividers, so the children differ from each other by AT MOST ONE CELL
        // (e.g. 88/89 on a 178-cell container). Detect "even" by the SPREAD
        // between the largest and smallest child cell-extent: ≤1 ⇒ even.
        //
        // The old `1/total`-of-the-SHARE epsilon scaled with the container, so
        // on a SMALL container it permitted a child to deviate by a full 1/total
        // of the WHOLE — e.g. 1 cell out of 10 = 10% — which flattened a genuine
        // 40/60 (`4x`/`6x`, spread 2) split to equal, discarding the user's real
        // proportions. The max-min-spread rule keeps a legitimately divider-
        // rounded split even (88/89 → spread 1) while preserving a real
        // small-container resize (4/6 → spread 2, 2/1 → spread 1... see below).
        //
        // A 2:1 split (`2x`/`1x`) has spread 1 and WOULD read as even by spread
        // alone, yet it is a deliberate resize — so ALSO require the spread to be
        // small RELATIVE to the ideal share (a 1-cell spread is rounding noise on
        // an 88-cell pane, but a real 2:1 on a 3-cell pane). Even ⇔ spread ≤ 1
        // AND spread ≤ idealCells/8 won't hold for tiny panes; instead: even ⇔
        // the spread is ≤1 AND no child is ≤ half the ideal. This keeps clean
        // halves (5/5, 88/89) even while flagging 2/1 (a child at 1/3 ideal) and
        // 4/6 (spread 2) as the real resizes they are.
        let minExtent = extents.min() ?? 0
        let maxExtent = extents.max() ?? 0
        let spread = maxExtent - minExtent
        let idealCells = Double(total) / Double(extents.count)
        let smallestIsBalanced = Double(minExtent) >= idealCells * 0.75
        let isEven = spread <= 1 && smallestIsBalanced
        let shares = extents.map { Double($0) / Double(total) }
        return isEven ? nil : shares
    }
}
