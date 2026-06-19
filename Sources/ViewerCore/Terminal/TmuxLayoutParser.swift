import Foundation

/// A node in a tmux window's pane tree, decoded from a tmux *layout string*
/// (`%layout-change` / `display-message -p '#{window_visible_layout}'`).
///
/// Each node carries the geometry of its bounding box (`w`×`h` at origin
/// `x`,`y`, in terminal cells). A `leaf` additionally carries the tmux pane
/// id. A split holds its children in document order:
///
/// - `hsplit` — children laid out **left-to-right** (a horizontal split:
///   panes side by side, a vertical divider between them). Source: `{ … }`.
/// - `vsplit` — children laid out **top-to-bottom** (a vertical split).
///   Source: `[ … ]`.
///
/// See `docs/TMUX_CC_DESIGN_2026-06-18.md` §1.4 for the grammar.
public indirect enum PaneNode: Equatable, Sendable {
    /// A pane (leaf): bounding box `w`×`h` at `x`,`y`, tmux pane id `id`.
    case leaf(id: Int, w: Int, h: Int, x: Int, y: Int)
    /// Left-to-right children (from `{ … }`).
    case hsplit([PaneNode])
    /// Top-to-bottom children (from `[ … ]`).
    case vsplit([PaneNode])
}

/// Hand-written recursive-descent parser for tmux layout strings.
///
/// Grammar (`docs/TMUX_CC_DESIGN_2026-06-18.md` §1.4):
/// ```
/// layout  := checksum ',' node
/// checksum:= HEX HEX HEX HEX            // 4 hex digits, ignored after shape check
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

    /// Parse a tmux layout string into its pane tree. Returns `nil` for any
    /// malformed input (the caller treats `nil` as "ignore this layout").
    public static func parse(_ layout: String) -> PaneNode? {
        var cursor = Cursor(Array(layout))

        // <checksum> ',' <node>
        guard cursor.consumeChecksum() else { return nil }
        guard cursor.expect(",") else { return nil }
        guard let node = cursor.parseNode() else { return nil }
        // Reject trailing junk — the layout must be fully consumed.
        guard cursor.isAtEnd else { return nil }
        return node
    }

    // MARK: - Cursor

    /// A mutable forward cursor over the layout characters. All parsing helpers
    /// return `nil`/`false` on malformed input and leave the cursor in an
    /// unspecified position (the top-level `parse` bails on the first failure).
    private struct Cursor {
        private let chars: [Character]
        private var i: Int = 0

        init(_ chars: [Character]) { self.chars = chars }

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

        /// node := WxH ',' X ',' Y suffix
        mutating func parseNode() -> PaneNode? {
            guard let w = parseUInt() else { return nil }
            guard expect("x") else { return nil }
            guard let h = parseUInt() else { return nil }
            guard expect(",") else { return nil }
            guard let x = parseUInt() else { return nil }
            guard expect(",") else { return nil }
            guard let y = parseUInt() else { return nil }

            // suffix: ',' paneId (leaf) | '{' children '}' | '[' children ']'
            switch current {
            case ",":
                i += 1
                guard let id = parseUInt() else { return nil }
                return .leaf(id: id, w: w, h: h, x: x, y: y)
            case "{":
                guard let children = parseGroup(open: "{", close: "}") else { return nil }
                return .hsplit(children)
            case "[":
                guard let children = parseGroup(open: "[", close: "]") else { return nil }
                return .vsplit(children)
            default:
                return nil
            }
        }

        /// children := '<open>' node (',' node)* '<close>' — at least one node.
        mutating func parseGroup(open: Character, close: Character) -> [PaneNode]? {
            guard expect(open) else { return nil }
            var nodes: [PaneNode] = []
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
}
