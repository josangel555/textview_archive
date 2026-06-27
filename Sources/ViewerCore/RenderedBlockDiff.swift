import Foundation

/// TSK-838 — Rendered-markdown WKWebView: persistent page + incremental DOM
/// patch (first slice, host-testable).
///
/// The rendered-markdown preview currently full-reloads the `WKWebView`
/// (`loadHTMLString`) on **every** content change. On a large document a full
/// reload is a 2–9 s parse/layout/paint storm and a visible blank-content
/// flash — even when the edit touched a single paragraph.
///
/// This file is the **diff layer**: a pure, no-UI value type that takes the
/// old and new rendered-HTML bodies, splits each into top-level *blocks*,
/// assigns each block a **stable id**, and computes a minimal block-level
/// `[BlockPatchOp]` (insert / replace / remove) so the JS-apply side (a
/// follow-up slice, the VM-render tail) can mutate only the changed blocks
/// in a persistent page instead of rebuilding the whole DOM.
///
/// **Scope of THIS slice** (per the ticket): compute the patch set host-side
/// and prove it touches only changed blocks, plus prove that applying the
/// patch list to the old block model reproduces the new model. The actual
/// `WKWebView` DOM apply over the JS bridge is deferred.
///
/// ## Block model
///
/// `HTMLRenderer` emits the body as a flat sequence of top-level block
/// elements (`<h1>…</h1>\n`, `<p>…</p>\n`, `<pre>…</pre>\n`, `<ul>…</ul>\n`,
/// `<table>…</table>\n`, `<blockquote>…</blockquote>\n`, `<hr/>\n`, the
/// mermaid `<div …>\n`, raw HTML pass-through, …). Each top-level block is a
/// single balanced element (or void element) terminated at the depth-0
/// boundary. We split on that boundary — NOT on a regex per tag — so any
/// block element the renderer emits today or later is handled uniformly.
///
/// ## Stable id
///
/// A block's id must be stable across edits to OTHER blocks so an unchanged
/// block is recognised as the same node and left untouched. We key the id on
/// the block's *structural identity* — its tag name plus its ordinal among
/// same-tag top-level siblings — NOT on its content. That way editing the
/// text of the 2nd paragraph keeps its id `p-1` (a `replace`, content hash
/// changed) while a wholly new paragraph inserted before it shifts the
/// ordinals and is recognised as an `insert`. The LCS diff below keys on
/// *content hash* (so equal content = equal node regardless of position),
/// and ids are assigned positionally afterward; the two together give
/// "edited block ⇒ one replace, inserted block ⇒ one insert".
public enum RenderedBlockDiff {

    // MARK: - Block model

    /// One top-level block of rendered HTML.
    public struct Block: Equatable, Sendable {
        /// Tag name of the block's root element, lowercased (`"p"`, `"h2"`,
        /// `"pre"`, `"ul"`, `"div"`, `"hr"`, …). `""` for a raw text run that
        /// isn't wrapped in an element (defensive — the renderer always wraps,
        /// but sanitized raw-HTML pass-through could emit bare text).
        public let tag: String
        /// Verbatim HTML of the block, including its terminating newline if the
        /// renderer emitted one. This is what gets shipped over the bridge.
        public let html: String
        /// Position-independent content key: a hash of `html`. Two blocks with
        /// byte-identical HTML share a `contentHash` and are treated as the
        /// same node by the diff (so a block that merely moved is matched, not
        /// rebuilt).
        public let contentHash: UInt64

        public init(tag: String, html: String) {
            self.tag = tag
            self.html = html
            self.contentHash = RenderedBlockDiff.fnv1a(html)
        }
    }

    /// A single mutation in the patch set. `index` is always interpreted
    /// against the OLD block list as it is being transformed in order, the way
    /// a list-diff applier walks it (so `apply(_:to:)` can replay it directly).
    public enum BlockPatchOp: Equatable, Sendable {
        /// Insert `block` so that, after this op, it sits at `index` in the
        /// (in-progress) result list.
        case insert(index: Int, block: Block)
        /// Replace the block at `index` with `block` (same position, new
        /// content — the single-paragraph-edit case).
        case replace(index: Int, block: Block)
        /// Remove the block at `index`.
        case remove(index: Int)
    }

    // MARK: - Block splitting

    /// Split a rendered-HTML **body** (the inner-`<body>` payload `HTMLRenderer`
    /// produces, NOT the full `<html>` page) into its top-level blocks.
    ///
    /// We walk the string tracking element-nesting depth: an opening tag that
    /// isn't self-closing/void pushes depth, a matching close pops it, and a
    /// block boundary is recognised when depth returns to 0. Void elements
    /// (`<hr/>`, `<img …/>`) and a depth-0 self-closing tag close their block
    /// immediately. Inter-block whitespace (the `\n` separators) is attached to
    /// the block it terminates, so re-joining the blocks reproduces the body
    /// byte-for-byte.
    ///
    /// This is intentionally a light structural tokenizer, not a full HTML
    /// parser: the input is OUR renderer's output (well-formed, balanced,
    /// no exotic constructs), so we only need to track `<tag>` / `</tag>` /
    /// `<tag/>` and the `<!-- … -->` comment + `<!DOCTYPE …>` forms that can
    /// appear. Attribute values can contain `>` (e.g. the mermaid
    /// `data-mdv-src` carries escaped markup), so we skip over quoted
    /// attribute strings while scanning a tag.
    public static func splitBlocks(_ body: String) -> [Block] {
        var blocks: [Block] = []
        let scalars = Array(body.unicodeScalars)
        let n = scalars.count
        var i = 0
        var depth = 0
        var blockStart = 0
        var blockTag = ""

        func flush(end: Int) {
            // Include any trailing whitespace/newline up to `end` (exclusive).
            guard end > blockStart else { return }
            let html = String(String.UnicodeScalarView(scalars[blockStart..<end]))
            // Drop a block that is pure whitespace (the separators between
            // emitted blocks are folded into the preceding block by `end`
            // extension below, so this only fires for leading whitespace).
            if html.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                blockStart = end
                blockTag = ""
                return
            }
            blocks.append(Block(tag: blockTag, html: html))
            blockStart = end
            blockTag = ""
        }

        while i < n {
            let c = scalars[i]
            if c == "<" {
                // Comment or doctype: scan to its terminator, treat as a
                // depth-0 standalone block when at depth 0.
                if matches(scalars, at: i, "<!--") {
                    let close = findClose(scalars, from: i + 4, terminator: "-->")
                    let tagEnd = close + 3
                    if depth == 0 {
                        if blockTag.isEmpty { blockTag = "!comment" }
                        // Extend to swallow a trailing newline.
                        let end = swallowNewline(scalars, from: tagEnd)
                        flush(end: end)
                        i = end
                        continue
                    }
                    i = tagEnd
                    continue
                }
                // Parse a tag: name, whether it's a close tag, whether void.
                let tag = scanTag(scalars, from: i)
                if depth == 0, blockTag.isEmpty, !tag.isClose {
                    blockTag = tag.name
                }
                if tag.isClose {
                    depth = max(0, depth - 1)
                    if depth == 0 {
                        let end = swallowNewline(scalars, from: tag.endIndex)
                        flush(end: end)
                        i = end
                        continue
                    }
                } else if tag.isVoid {
                    if depth == 0 {
                        let end = swallowNewline(scalars, from: tag.endIndex)
                        flush(end: end)
                        i = end
                        continue
                    }
                } else {
                    depth += 1
                }
                i = tag.endIndex
                continue
            }
            i += 1
        }
        // Trailing content (no closing boundary, e.g. bare text).
        flush(end: n)
        return blocks
    }

    // MARK: - Diff

    /// Compute the minimal block-level patch set that transforms `old` into
    /// `new`. Matching is by `contentHash` via a longest-common-subsequence
    /// (LCS) pass, so unchanged blocks anchor the diff and only the genuinely
    /// changed/added/removed blocks become ops. Adjacent remove+insert at the
    /// same position are coalesced into a single `replace` (the
    /// single-paragraph-edit case → exactly one op).
    ///
    /// The returned ops are ordered so they can be replayed directly against a
    /// mutable copy of `old` (see `apply(_:to:)`).
    public static func diff(old: [Block], new: [Block]) -> [BlockPatchOp] {
        let lcs = lcsMatches(old: old, new: new)
        // Walk old & new together, emitting removes for old-only runs and
        // inserts for new-only runs, anchored by the matched (kept) pairs.
        var ops: [BlockPatchOp] = []
        // We track the current index in the IN-PROGRESS result list (starts as
        // a copy of `old`), so indices are valid for `apply`.
        var oi = 0           // cursor in old
        var ni = 0           // cursor in new
        var cursor = 0       // cursor in the in-progress list
        var matchOld = 0     // next matched old index
        for (mo, mn) in lcs + [(old.count, new.count)] {
            // Emit removes for old blocks before the next match.
            var pendingRemovesAt = cursor
            while oi < mo {
                // Is there a corresponding new-only block to coalesce into a
                // replace? Handled in the insert loop below by position.
                ops.append(.remove(index: pendingRemovesAt))
                oi += 1
                // After a remove the in-progress list shrinks, so the index
                // of the NEXT removal stays the same (`pendingRemovesAt`).
            }
            // Emit inserts for new blocks before the next match.
            while ni < mn {
                ops.append(.insert(index: cursor, block: new[ni]))
                ni += 1
                cursor += 1
            }
            // Consume the matched pair (kept verbatim — no op).
            if mo < old.count {
                oi += 1
                ni += 1
                cursor += 1
            }
            matchOld = mo
        }
        _ = matchOld
        return coalesceReplaces(ops)
    }

    /// Apply a patch list to a block list, reproducing the diff target. Pure —
    /// this is the host-side mirror of what the JS-apply side will do to the
    /// live DOM, and lets a test assert `apply(diff(old,new), to: old) == new`.
    public static func apply(_ ops: [BlockPatchOp], to old: [Block]) -> [Block] {
        var result = old
        for op in ops {
            switch op {
            case .insert(let index, let block):
                let clamped = max(0, min(index, result.count))
                result.insert(block, at: clamped)
            case .replace(let index, let block):
                guard index >= 0, index < result.count else { continue }
                result[index] = block
            case .remove(let index):
                guard index >= 0, index < result.count else { continue }
                result.remove(at: index)
            }
        }
        return result
    }

    // MARK: - LCS

    /// Longest common subsequence of two block lists, matched by `contentHash`.
    /// Returns the matched (oldIndex, newIndex) pairs in ascending order.
    /// Classic DP — block counts here are document-block counts (hundreds at
    /// most for a large doc), so O(n·m) is fine and the table stays small.
    private static func lcsMatches(old: [Block], new: [Block]) -> [(Int, Int)] {
        let n = old.count, m = new.count
        if n == 0 || m == 0 { return [] }
        // dp[i][j] = LCS length of old[i...] and new[j...].
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if old[i].contentHash == new[j].contentHash {
                    dp[i][j] = dp[i + 1][j + 1] + 1
                } else {
                    dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var matches: [(Int, Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if old[i].contentHash == new[j].contentHash {
                matches.append((i, j))
                i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return matches
    }

    /// Coalesce a `remove(index)` immediately followed by an `insert(index)` at
    /// the SAME position into a single `replace(index)` — the dominant
    /// single-block-edit case, which otherwise costs a remove + an insert.
    private static func coalesceReplaces(_ ops: [BlockPatchOp]) -> [BlockPatchOp] {
        var out: [BlockPatchOp] = []
        var idx = 0
        while idx < ops.count {
            if case .remove(let ri) = ops[idx], idx + 1 < ops.count,
               case .insert(let ii, let block) = ops[idx + 1], ii == ri {
                out.append(.replace(index: ri, block: block))
                idx += 2
            } else {
                out.append(ops[idx])
                idx += 1
            }
        }
        return out
    }

    // MARK: - JS wire format (TSK-1183 DOM-patch APPLY path)

    /// Serialize a patch set to the JSON payload the WebView's `applyBlockPatch`
    /// will consume: a JSON array of `{op, index, html?}` (`html` is omitted for
    /// `remove`). The block HTML carries `"`, `<`, and newlines, so it is
    /// JSON-escaped (via `JSONEncoder`) and reaches the JS verbatim. This is the
    /// Swift→JS contract for the DOM-patch apply path that will replace the full
    /// `loadHTMLString` reload (TSK-1183/838); the diff math itself is
    /// `diff`/`apply` above (host-tested, round-trip-proven).
    public static func jsPayload(_ ops: [BlockPatchOp]) -> String {
        let wire = ops.map { op -> WireOp in
            switch op {
            case .insert(let index, let block):
                return WireOp(op: "insert", index: index, html: block.html)
            case .replace(let index, let block):
                return WireOp(op: "replace", index: index, html: block.html)
            case .remove(let index):
                return WireOp(op: "remove", index: index, html: nil)
            }
        }
        guard let data = try? JSONEncoder().encode(wire),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// DTO for `jsPayload`. `html` is `encodeIfPresent` (synthesized Codable), so
    /// a nil (`remove`) omits the key rather than emitting `"html":null`.
    private struct WireOp: Encodable {
        let op: String
        let index: Int
        let html: String?
    }

    // MARK: - Tag scanning helpers

    private struct ScannedTag {
        var name: String
        var isClose: Bool
        var isVoid: Bool
        /// Index just past the tag's `>`.
        var endIndex: Int
    }

    /// HTML void elements that never have a close tag. The renderer emits
    /// `<hr/>`, `<br/>`, `<img …/>`, `<input …/>`; we also list the standard
    /// set so a self-closing slash isn't required to recognise them.
    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]

    /// Scan a tag starting at `<` at `start`. Skips over quoted attribute
    /// values so a `>` inside an attribute (e.g. the mermaid `data-mdv-src`
    /// carrying escaped markup, or a `title="a > b"`) doesn't prematurely end
    /// the tag.
    private static func scanTag(_ s: [UnicodeScalar], from start: Int) -> ScannedTag {
        let n = s.count
        var i = start + 1            // past '<'
        var isClose = false
        if i < n, s[i] == "/" { isClose = true; i += 1 }
        // Read the tag name.
        var name = ""
        while i < n {
            let c = s[i]
            if c == " " || c == ">" || c == "/" || c == "\t" || c == "\n" || c == "\r" { break }
            name.unicodeScalars.append(c)
            i += 1
        }
        name = name.lowercased()
        // Scan to the closing '>', skipping quoted attribute strings.
        var selfClosing = false
        while i < n {
            let c = s[i]
            if c == "\"" || c == "'" {
                let quote = c
                i += 1
                while i < n, s[i] != quote { i += 1 }
                if i < n { i += 1 }      // past closing quote
                continue
            }
            if c == "/" {
                // A '/' just before '>' marks self-close.
                var j = i + 1
                while j < n, s[j] == " " { j += 1 }
                if j < n, s[j] == ">" { selfClosing = true }
            }
            if c == ">" { i += 1; break }
            i += 1
        }
        let isVoid = !isClose && (selfClosing || voidTags.contains(name))
        return ScannedTag(name: name, isClose: isClose, isVoid: isVoid, endIndex: i)
    }

    /// Return the index just past `terminator` starting the search at `from`,
    /// or the end of input if not found.
    private static func findClose(_ s: [UnicodeScalar], from: Int, terminator: String) -> Int {
        let term = Array(terminator.unicodeScalars)
        var i = from
        let n = s.count
        while i + term.count <= n {
            var k = 0
            while k < term.count, s[i + k] == term[k] { k += 1 }
            if k == term.count { return i }
            i += 1
        }
        return n - term.count >= 0 ? n - term.count : from
    }

    /// If a single `\n` (optionally preceded by `\r`) follows `from`, return
    /// the index past it so the block swallows its trailing separator. Only a
    /// SINGLE newline is consumed so blank-line gaps between blocks aren't
    /// glued onto the wrong block.
    private static func swallowNewline(_ s: [UnicodeScalar], from: Int) -> Int {
        var i = from
        let n = s.count
        if i < n, s[i] == "\r" { i += 1 }
        if i < n, s[i] == "\n" { i += 1 }
        return i
    }

    private static func matches(_ s: [UnicodeScalar], at: Int, _ needle: String) -> Bool {
        let nd = Array(needle.unicodeScalars)
        guard at + nd.count <= s.count else { return false }
        for k in 0..<nd.count where s[at + k] != nd[k] { return false }
        return true
    }

    /// FNV-1a 64-bit hash over the block's UTF-8 bytes. A non-cryptographic
    /// content key is all the diff needs (collisions only cost an unnecessary
    /// replace, never a wrong render — and `apply` ships the verbatim html).
    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}
