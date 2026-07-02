import Foundation

/// One heading in a Markdown document's outline (TOC).
public struct MarkdownHeading: Equatable, Sendable {
    /// 1...6 (ATX `#`-count, or 1 for setext `===` / 2 for setext `---`).
    public let level: Int
    /// The heading text, trimmed (ATX trailing `#`s removed).
    public let title: String
    /// 1-based line number of the heading (for ATX, the `#` line; for setext,
    /// the *text* line, not the underline).
    public let line: Int

    public init(level: Int, title: String, line: Int) {
        self.level = level
        self.title = title
        self.line = line
    }
}

/// Extracts a Markdown document's heading outline so a viewer can offer a
/// navigable table of contents / jump-to-heading (TSK-511). Pure +
/// dependency-free, mirroring `IndentDetector` / `DotGraphParser`.
///
/// Supported common subset (documented so callers don't over-trust):
///   - **ATX**: `#`…`######` (1–6) that are empty or followed by a space; a
///     trailing run of `#` is stripped from the title. `#######` (7+) and
///     `#no-space` are NOT headings (CommonMark).
///   - **Setext**: a non-blank paragraph line immediately followed by an
///     underline of only `=` (→ level 1) or `-` (→ level 2). The heading's
///     line is the text line.
///   - **Fenced code** (```` ``` ```` / `~~~`, ≥3) is skipped — `#` inside a
///     fence is not a heading.
///   - YAML front-matter `---` is NOT misread as a setext underline (setext
///     requires a preceding non-blank paragraph line; the opening `---` has
///     none).
///
/// NOT modeled: indented (4-space) code blocks, `#` inside HTML blocks,
/// reference-style constructs. Good enough for a TOC; not a CommonMark parser.
public enum MarkdownOutline {

    /// Map the heading outline to LSP document symbols so the sidebar's
    /// existing OUTLINE panel renders markdown without an LSP server
    /// (TSK-637). Heading LEVELS become the symbol tree: each heading nests
    /// under the nearest shallower predecessor (an H3 after an H1 nests
    /// directly — gaps are fine). Lines convert 1-based → LSP 0-based.
    public static func documentSymbols(in text: String, uri: String? = nil) -> [LSPDocumentSymbol] {
        struct Node {
            let heading: MarkdownHeading
            var children: [Node] = []
        }
        var roots: [Node] = []
        var stack: [(level: Int, path: [Int])] = []

        func append(_ node: Node, at path: [Int]) -> [Int] {
            if path.isEmpty {
                roots.append(node)
                return [roots.count - 1]
            }
            var indices = path
            func insert(into nodes: inout [Node], depth: Int) {
                if depth == indices.count {
                    nodes.append(node)
                    indices.append(nodes.count - 1)
                } else {
                    insert(into: &nodes[indices[depth]].children, depth: depth + 1)
                }
            }
            insert(into: &roots, depth: 0)
            return indices
        }

        for h in headings(in: text) {
            while let top = stack.last, top.level >= h.level {
                stack.removeLast()
            }
            let parentPath = stack.last?.path ?? []
            let path = append(Node(heading: h), at: parentPath)
            stack.append((h.level, path))
        }

        func symbol(_ n: Node) -> LSPDocumentSymbol {
            let line = max(0, n.heading.line - 1)
            let range = LSPRange(
                start: LSPPosition(line: line, character: 0),
                end: LSPPosition(line: line, character: n.heading.title.utf16.count))
            return LSPDocumentSymbol(
                name: n.heading.title,
                detail: "H\(n.heading.level)",
                kind: .string,
                range: range,
                selectionRange: range,
                children: n.children.map(symbol),
                uri: uri)
        }
        return roots.map(symbol)
    }


    public static func headings(in text: String) -> [MarkdownHeading] {
        var out: [MarkdownHeading] = []

        // Split on the LF *scalar* (NOT Character.split: `"\r\n"` is a single
        // grapheme, so a Character-based split on "\n" never sees the LF inside a
        // CRLF pair and collapses the whole file to one line — the exact
        // `IndentDetector` trap). A CRLF line then ends with a lone `\r` scalar,
        // stripped per-line below.
        var rawLines: [String] = []
        var cur = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            if u == "\n" { rawLines.append(String(cur)); cur = String.UnicodeScalarView() }
            else { cur.append(u) }
        }
        rawLines.append(String(cur))

        var inFence = false
        var fenceMarker: Character = "`"
        var fenceLen = 0
        // HTML comment block: a `#` line inside `<!-- … -->` is commented-out, not
        // a heading. (A single-line `<!-- # x -->` has its `#` mid-line, so it's
        // never a heading anyway — only multi-line blocks need tracking.)
        var inComment = false

        // For setext: the immediately-preceding line's trimmed text + its
        // 1-based number, if it was a non-blank paragraph line eligible to be a
        // setext heading text. Reset whenever the previous line can't be one.
        var prevParagraph: (title: String, line: Int)?

        // Skip a leading YAML front-matter block (`---` … `---`/`...`), the
        // Jekyll/Hugo/Obsidian convention — otherwise its closing `---` reads as
        // a phantom setext heading of the last metadata line.
        var startIdx = 0
        if let first = rawLines.first,
           String(first).trimmingCharacters(in: .whitespaces) == "---" {
            for k in 1..<rawLines.count {
                let t = String(rawLines[k]).trimmingCharacters(in: .whitespaces)
                if t == "---" || t == "..." { startIdx = k + 1; break }
            }
        }

        for idx in startIdx..<rawLines.count {
            let raw = rawLines[idx]
            let lineNo = idx + 1
            var line = String(raw)
            if line.hasSuffix("\r") { line.removeLast() }
            let trimmedLeading = line.drop { $0 == " " || $0 == "\t" }
            let trimmed = trimmedLeading.trimmingCharacters(in: .whitespaces)
            // CommonMark indentation width of the leading whitespace (tab = 4-col
            // stop). ≥4 means an indented code block, not an ATX heading.
            let leadingIndent = line.prefix { $0 == " " || $0 == "\t" }
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }

            // Fenced code blocks: toggle on a ``` / ~~~ run of >= 3.
            if let (marker, count) = fenceRun(trimmed) {
                if inFence {
                    // Close only on the same marker char with >= opening length.
                    if marker == fenceMarker, count >= fenceLen {
                        inFence = false
                    }
                } else {
                    inFence = true
                    fenceMarker = marker
                    fenceLen = count
                }
                prevParagraph = nil
                continue
            }
            if inFence { prevParagraph = nil; continue }

            // HTML comment block: skip heading detection inside <!-- … -->.
            if inComment {
                if trimmed.contains("-->") { inComment = false }
                prevParagraph = nil
                continue
            }
            if trimmed.hasPrefix("<!--"), !trimmed.contains("-->") {
                inComment = true
                prevParagraph = nil
                continue
            }

            // ATX heading: 0-3 spaces indent, then a run of 1...6 '#', then space
            // or end. 4+ spaces of indent → an indented code block, not a heading.
            if trimmed.first == "#", leadingIndent <= 3 {
                let hashes = trimmed.prefix { $0 == "#" }
                let level = hashes.count
                let after = trimmed.dropFirst(level)
                if level >= 1, level <= 6, (after.isEmpty || after.first == " " || after.first == "\t") {
                    let title = stripATXTitle(String(after))
                    out.append(MarkdownHeading(level: level, title: title, line: lineNo))
                    prevParagraph = nil
                    continue
                }
                // `#######`/`#nospace` → falls through as a paragraph line.
            }

            // Setext underline: only `=`+ (h1) or `-`+ (h2), applied to the
            // immediately-preceding paragraph line.
            if let prev = prevParagraph, !trimmed.isEmpty,
               let setextLevel = setextUnderlineLevel(trimmed) {
                out.append(MarkdownHeading(level: setextLevel, title: prev.title, line: prev.line))
                prevParagraph = nil
                continue
            }

            // Track this line as a potential setext text line.
            if trimmed.isEmpty {
                prevParagraph = nil
            } else {
                prevParagraph = (trimmed, lineNo)
            }
        }

        return out
    }

    // MARK: - helpers

    /// If `trimmed` is a fence line (≥3 of '`' or '~', nothing but the run +
    /// optional info string for backticks), return (marker, run-length).
    private static func fenceRun(_ trimmed: String) -> (Character, Int)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        // A backtick info string must not itself contain a backtick (CommonMark);
        // we don't enforce that strictly — the run length is what matters here.
        return (first, run.count)
    }

    /// `=`+ → 1, `-`+ → 2, else nil. Trailing spaces already trimmed by caller.
    private static func setextUnderlineLevel(_ trimmed: String) -> Int? {
        if !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "=" }) { return 1 }
        if !trimmed.isEmpty, trimmed.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    /// Strip the optional ATX closing `#` sequence. Per CommonMark it must be
    /// preceded by a space (so `# C#` keeps "C#" — the `#` is part of the word),
    /// and a body that is ENTIRELY `#`s is an empty heading.
    private static func stripATXTitle(_ body: String) -> String {
        let s = body.trimmingCharacters(in: .whitespaces)
        guard s.hasSuffix("#") else { return s }
        // Find the start of the trailing run of '#'.
        var i = s.endIndex
        while i > s.startIndex, s[s.index(before: i)] == "#" { i = s.index(before: i) }
        if i == s.startIndex { return "" }          // body is all '#'s → empty
        let before = s.index(before: i)
        if s[before] == " " || s[before] == "\t" {  // valid closing sequence
            return String(s[..<i]).trimmingCharacters(in: .whitespaces)
        }
        return s                                     // trailing '#' is part of a word
    }
}
