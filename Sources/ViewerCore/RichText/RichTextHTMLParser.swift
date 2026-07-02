import Foundation

/// TSK-1327 — parse pasteboard HTML (a browser / rich-doc copy, the `public.html`
/// pasteboard representation) into the restricted `RichTextDocument` IR, so a paste
/// into a textable field can be re-emitted as clean canonical Markdown via
/// `RichTextSerializer` (bullet `<ul><li>` → `- `, `<h1>` → `# `, `<b>` → `**…**`,
/// `<a href>` → `[…](url)`, etc.) — the owner's "synthesize meaningful formatting
/// when pasting rich text" ask.
///
/// Scope: the common rich-paste tags. Block: `p`, `div`, `h1`–`h6` (h4–6 downgrade
/// to paragraph via the normalizer), `ul`/`ol`/`li`, `blockquote`. Inline: `b`/
/// `strong`, `i`/`em`, `s`/`strike`/`del`, `code`, `a href`, `br` (→ space). Unknown
/// tags are STRIPPED (their inner text is kept). HTML entities are decoded. Output is
/// normalized to the closed vocabulary, so it's always in-spec.
///
/// Pure + dependency-free + TOTAL: the pasteboard is untrusted, so `parse` must NEVER
/// panic on arbitrary/malformed input (covered by a no-panic proptest). It is a
/// lenient scanner, not a validating parser — malformed HTML degrades to text, never
/// crashes. The paste WIRING (read `public.html` from `NSPasteboard` on paste into a
/// textable field → `parse` → `serialized()` → insert) is the ViewerUI render tail.
public enum RichTextHTMLParser {

    /// Parse `html` → a normalized, in-vocabulary `RichTextDocument`.
    public static func parse(_ html: String) -> RichTextDocument {
        let toks = tokenize(html)
        var i = 0
        let blocks = parseBlocks(toks, &i, until: nil)
        return RichTextNormalizer.normalize(RichTextDocument(blocks))
    }

    /// Convenience: HTML → canonical restricted Markdown (parse + serialize).
    public static func markdown(fromHTML html: String) -> String {
        RichTextSerializer.serialize(parse(html))
    }

    // MARK: - Tokens

    enum Token: Equatable {
        case open(String, href: String?)   // lowercased tag name (+ href for <a>)
        case close(String)
        case text(String)                  // entity-decoded literal text
    }

    /// Inline tags handled as emphasis/link runs; everything else block-or-stripped.
    private static let inlineTags: Set<String> = ["b", "strong", "i", "em", "s", "strike", "del", "code", "a", "span", "u"]
    /// Void/self-closing tags that carry no children.
    private static let voidTags: Set<String> = ["br", "img", "hr", "wbr", "meta", "link", "col", "area", "input"]

    // MARK: - Tokenizer

    static func tokenize(_ html: String) -> [Token] {
        var toks: [Token] = []
        let chars = Array(html)
        let n = chars.count
        var i = 0
        var text = ""
        func flush() {
            if !text.isEmpty { toks.append(.text(decodeEntities(text))); text = "" }
        }
        while i < n {
            if chars[i] == "<" {
                // Locate the tag end; a stray '<' with no '>' is literal text.
                guard let gt = nextIndex(of: ">", in: chars, from: i + 1, end: n) else {
                    text.append("<"); i += 1; continue
                }
                // Skip HTML comments wholesale: <!-- … -->
                if matches(chars, at: i + 1, "!--") {
                    if let endC = nextSubsequence("-->", in: chars, from: i + 3, end: n) {
                        i = endC + 3; continue
                    } else { break }   // unterminated comment → drop the rest
                }
                flush()
                let body = String(chars[(i + 1)..<gt])
                emitTag(body, into: &toks)
                i = gt + 1
            } else {
                text.append(chars[i]); i += 1
            }
        }
        flush()
        return toks
    }

    private static func emitTag(_ rawBody: String, into toks: inout [Token]) {
        var body = rawBody.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return }
        if body.hasPrefix("!") || body.hasPrefix("?") { return }   // doctype / PI
        let isClose = body.hasPrefix("/")
        if isClose { body.removeFirst() }
        var selfClose = false
        if body.hasSuffix("/") { selfClose = true; body.removeLast() }
        body = body.trimmingCharacters(in: .whitespaces)
        let name = String(body.prefix { !$0.isWhitespace }).lowercased()
        guard !name.isEmpty else { return }
        if isClose { toks.append(.close(name)); return }
        if name == "br" { toks.append(.text(" ")); return }   // soft break → space
        let href = (name == "a") ? attribute("href", in: body) : nil
        toks.append(.open(name, href: href))
        if selfClose || voidTags.contains(name) { toks.append(.close(name)) }
    }

    // MARK: - Block parsing

    /// Parse a run of blocks until the close tag `until` (nil = end of input).
    private static func parseBlocks(_ toks: [Token], _ i: inout Int, until: String?) -> [RichBlock] {
        var blocks: [RichBlock] = []
        var loose: [RichInline] = []   // top-level text/inline → implicit paragraph
        func flushLoose() {
            let trimmed = trimEdges(loose)
            if !trimmed.isEmpty { blocks.append(.paragraph(trimmed)) }
            loose = []
        }
        while i < toks.count {
            switch toks[i] {
            case .close(let n):
                if let until, n == until { i += 1; flushLoose(); return blocks }
                i += 1   // stray close → ignore
            case .open(let name, _) where name == "p" || name == "div":
                flushLoose(); i += 1
                let inl = parseInlines(toks, &i, until: name)
                let t = trimEdges(inl); if !t.isEmpty { blocks.append(.paragraph(t)) }
            case .open(let name, _) where name.count == 2 && name.hasPrefix("h") && name.dropFirst().first.map({ $0.isNumber }) == true:
                flushLoose(); i += 1
                let level = Int(String(name.dropFirst())) ?? 1
                let inl = trimEdges(parseInlines(toks, &i, until: name))
                if !inl.isEmpty { blocks.append(.heading(level: level, inlines: inl)) }
            case .open(let name, _) where name == "ul" || name == "ol":
                flushLoose(); i += 1
                let items = parseListItems(toks, &i, until: name)
                if !items.isEmpty {
                    blocks.append(name == "ul" ? .bulletList(items) : .orderedList(start: 1, items: items))
                }
            case .open(let name, _) where name == "blockquote":
                flushLoose(); i += 1
                let inl = trimEdges(parseInlines(toks, &i, until: name))
                if !inl.isEmpty { blocks.append(.blockquote([inl])) }
            case .open(let name, _) where name == "pre":
                // TSK-1327: preformatted → a fenced code block. Collect the RAW
                // text (incl. any inner <code>), newlines PRESERVED, ignoring
                // markup — a code paste must not collapse to inline code.
                flushLoose(); i += 1
                let code = parsePreformatted(toks, &i)
                if !code.isEmpty { blocks.append(.codeBlock(code)) }
            case .open(let name, _) where name == "table":
                // TSK-1427: <table> → a GFM pipe table (first row = header),
                // instead of collapsing every cell into one text run.
                flushLoose(); i += 1
                if let t = parseTable(toks, &i) { blocks.append(t) }
            case .open(let name, let href) where inlineTags.contains(name):
                loose.append(contentsOf: parseInline(toks, &i, name: name, href: href))
            case .open:
                i += 1   // unknown block tag → strip (its text becomes loose/blocks via children)
            case .text(let t):
                loose.append(.text(t)); i += 1
            }
        }
        flushLoose()
        return blocks
    }

    /// Collect the raw text of an already-consumed `<pre>` until its `</pre>`,
    /// ignoring inner tags (their text is kept) and preserving newlines. Trailing
    /// blank lines are trimmed so the ```-fence is clean. TSK-1327.
    private static func parsePreformatted(_ toks: [Token], _ i: inout Int) -> String {
        var out = ""
        while i < toks.count {
            switch toks[i] {
            case .close("pre"): i += 1; return trimTrailingNewlines(out)
            case .text(let t): out += t; i += 1
            default: i += 1   // inner tag (e.g. <code>) — drop the tag, keep its text
            }
        }
        return trimTrailingNewlines(out)
    }

    private static func trimTrailingNewlines(_ s: String) -> String {
        var out = s
        while out.hasSuffix("\n") || out.hasSuffix("\r") { out.removeLast() }
        return out
    }

    /// `<table>` → a table block. `<tr>` rows of `<td>`/`<th>` cells; wrappers
    /// (thead/tbody/tfoot/caption/colgroup) are skipped. First row = header
    /// (Markdown tables require one). TSK-1427.
    private static func parseTable(_ toks: [Token], _ i: inout Int) -> RichBlock? {
        var rows: [[[RichInline]]] = []
        while i < toks.count {
            switch toks[i] {
            case .close(let n) where n == "table":
                i += 1
                return buildTable(rows)
            case .open(let name, _) where name == "tr":
                i += 1
                var cells: [[RichInline]] = []
                rowLoop: while i < toks.count {
                    switch toks[i] {
                    case .close(let n) where n == "tr": i += 1; break rowLoop
                    case .close(let n) where n == "table": break rowLoop   // unterminated <tr>
                    case .open(let c, _) where c == "td" || c == "th":
                        i += 1
                        cells.append(trimEdges(parseInlines(toks, &i, until: c)))
                    case .open: i += 1
                    case .close: i += 1
                    case .text: i += 1
                    }
                }
                if !cells.isEmpty { rows.append(cells) }
            case .open: i += 1   // thead/tbody/caption/… wrapper → skip
            case .close: i += 1
            case .text: i += 1
            }
        }
        return buildTable(rows)
    }

    private static func buildTable(_ rows: [[[RichInline]]]) -> RichBlock? {
        guard let header = rows.first, !header.isEmpty else { return nil }
        return .table(header: header, rows: Array(rows.dropFirst()))
    }

    /// `<li>`-delimited items until the list's close tag.
    private static func parseListItems(_ toks: [Token], _ i: inout Int, until listTag: String) -> [RichListItem] {
        var items: [RichListItem] = []
        while i < toks.count {
            switch toks[i] {
            case .close(let n) where n == listTag: i += 1; return items
            case .open(let name, _) where name == "li":
                i += 1
                let inl = trimEdges(parseInlines(toks, &i, until: "li"))
                items.append(RichListItem(inl.isEmpty ? [.text("")] : inl))
            case .close: i += 1            // stray close
            case .open: i += 1             // non-li open inside a list → skip its tag
            case .text: i += 1             // inter-item whitespace/text → drop
            }
        }
        return items
    }

    // MARK: - Inline parsing

    /// Collect inline runs until the close tag `until` (or end / a block-closer).
    private static func parseInlines(_ toks: [Token], _ i: inout Int, until: String) -> [RichInline] {
        var out: [RichInline] = []
        while i < toks.count {
            switch toks[i] {
            case .close(let n):
                if n == until { i += 1; return out }
                i += 1   // stray/mismatched close → ignore
            case .text(let t):
                out.append(.text(t)); i += 1
            case .open(let name, let href) where inlineTags.contains(name):
                out.append(contentsOf: parseInline(toks, &i, name: name, href: href))
            case .open:
                i += 1   // nested block/unknown tag inside inline context → strip its tag, keep children
            }
        }
        return out
    }

    /// Parse one already-seen inline open tag (`toks[i]`) and its children → 0+ runs.
    /// Returns a LIST so `span`/`u`/unknown-inline can unwrap to their children.
    private static func parseInline(_ toks: [Token], _ i: inout Int, name: String, href: String?) -> [RichInline] {
        i += 1   // consume the open
        if name == "code" {
            // code is opaque literal text — concatenate raw text children, no markup.
            var s = ""
            while i < toks.count {
                switch toks[i] {
                case .close(let n) where n == "code": i += 1; return [.code(s)]
                case .text(let t): s += t; i += 1
                case .open: i += 1                 // ignore tags inside code
                case .close: i += 1
                }
            }
            return [.code(s)]
        }
        let children = parseInlines(toks, &i, until: name)
        switch name {
        case "b", "strong": return [.bold(children)]
        case "i", "em":     return [.italic(children)]
        case "s", "strike", "del": return [.strike(children)]
        case "a":           return [.link(text: children, url: href ?? "")]
        default:            return children   // span / u / unknown-inline → unwrap
        }
    }

    // MARK: - Helpers

    private static func trimEdges(_ inlines: [RichInline]) -> [RichInline] {
        var arr = inlines
        if case .text(let t)? = arr.first { let s = String(t.drop { $0 == " " || $0 == "\n" || $0 == "\t" }); if s.isEmpty { arr.removeFirst() } else { arr[0] = .text(s) } }
        if case .text(let t)? = arr.last { let s = String(t.reversed().drop { $0 == " " || $0 == "\n" || $0 == "\t" }.reversed()); if s.isEmpty { arr.removeLast() } else { arr[arr.count - 1] = .text(s) } }
        // Drop runs that are now empty text.
        return arr.filter { if case .text("") = $0 { return false }; return true }
    }

    private static func attribute(_ name: String, in tagBody: String) -> String? {
        // find name = "..." | '...' | bare
        let lower = tagBody.lowercased()
        guard let r = lower.range(of: name + "=") else { return nil }
        let after = tagBody[r.upperBound...].drop { $0 == " " }
        guard let first = after.first else { return nil }
        if first == "\"" || first == "'" {
            let rest = after.dropFirst()
            if let end = rest.firstIndex(of: first) { return decodeEntities(String(rest[..<end])) }
            return decodeEntities(String(rest))
        }
        return decodeEntities(String(after.prefix { !$0.isWhitespace }))
    }

    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].firstIndex(of: ";"), s.distance(from: i, to: semi) <= 10 {
                let ent = String(s[s.index(after: i)..<semi])
                if let decoded = decodeOneEntity(ent) { out.append(decoded); i = s.index(after: semi); continue }
            }
            out.append(s[i]); i = s.index(after: i)
        }
        return out
    }

    private static func decodeOneEntity(_ ent: String) -> Character? {
        switch ent {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos", "#39": return "'"
        case "nbsp", "#160": return "\u{00A0}"
        default:
            if ent.hasPrefix("#x") || ent.hasPrefix("#X"), let code = UInt32(ent.dropFirst(2), radix: 16), let u = Unicode.Scalar(code) { return Character(u) }
            if ent.hasPrefix("#"), let code = UInt32(ent.dropFirst()), let u = Unicode.Scalar(code) { return Character(u) }
            return nil
        }
    }

    private static func nextIndex(of ch: Character, in chars: [Character], from: Int, end: Int) -> Int? {
        var i = from; while i < end { if chars[i] == ch { return i }; i += 1 }; return nil
    }
    private static func matches(_ chars: [Character], at: Int, _ s: String) -> Bool {
        let t = Array(s); guard at + t.count <= chars.count else { return false }
        for k in 0..<t.count where chars[at + k] != t[k] { return false }; return true
    }
    private static func nextSubsequence(_ s: String, in chars: [Character], from: Int, end: Int) -> Int? {
        let t = Array(s); guard !t.isEmpty else { return from }
        var i = from
        while i + t.count <= end { if matches(chars, at: i, s) { return i }; i += 1 }
        return nil
    }
}