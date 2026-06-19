import Foundation

/// Maps arbitrary Markdown into the closed ``RichTextDocument`` IR for the
/// restricted RichText editor (TSK-706). It is a *focused* block/inline parser
/// (like `MarkdownOutline` / `MarkdownLinks`), NOT the Rust-ported full
/// markdown→HTML engine — the whole point of RichText is a small, closed
/// vocabulary.
///
/// ## Guarantee
/// The output is ALWAYS in-vocabulary. Disallowed constructs are downgraded at
/// parse time to the nearest allowed form (and ``RichTextNormalizer`` is a
/// belt-and-braces stabilizer on top):
///   - **Tables** (`| a | b |` + a `---|---` delimiter row) → each row's cell
///     text joined into a plain paragraph.
///   - **Raw / inline HTML** (`<div>…`, `<br>`, `<b>x</b>`) → tags stripped,
///     text kept as a paragraph / inline text.
///   - **Fenced (``` / ~~~) and indented (4-space) code blocks** → the code
///     LINES become plain paragraphs (no `code` block exists in the model;
///     inline code spans DO).
///   - **Images** (`![alt](url)`) → the alt text as plain inline text (a link
///     would re-introduce navigation we don't want for an image; alt is the
///     accessible nearest form).
///   - **Headings H4–H6** → a paragraph (bold-emphasised would change inline
///     vocab; paragraph is the safe nearest block).
///   - **Horizontal rules / thematic breaks** (`---`, `***`, `___`) → dropped.
///   - **Blockquote inner block structure** (nested lists/headings/quotes) →
///     flattened to paragraphs of inline text.
public enum RichTextParser {

    public static func parse(_ text: String) -> RichTextDocument {
        let lines = splitLines(text)
        var blocks: [RichBlock] = []
        var i = 0
        // Skip a leading YAML front-matter block (--- … ---/...), same as the
        // outline extractor — it's metadata, not content.
        if let first = lines.first, first.trimmed == "---" {
            var k = 1
            while k < lines.count {
                let t = lines[k].trimmed
                if t == "---" || t == "..." { i = k + 1; break }
                k += 1
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmed

            // Blank line: paragraph/section separator.
            if trimmed.isEmpty { i += 1; continue }

            // Fenced code block: ``` / ~~~ (>=3). Downgrade the inner lines to
            // paragraphs; never emit a code block (not in the vocabulary).
            if let (marker, len) = fenceRun(trimmed) {
                i += 1
                while i < lines.count {
                    let t = lines[i].trimmed
                    if let (m2, l2) = fenceRun(t), m2 == marker, l2 >= len { i += 1; break }
                    let body = lines[i]
                    if !body.trimmed.isEmpty {
                        blocks.append(.paragraph([.text(body)]))
                    }
                    i += 1
                }
                continue
            }

            // Indented code block (>=4 leading spaces / a tab). Downgrade the
            // line's textual content to a paragraph.
            if isIndentedCode(line) {
                let body = stripCodeIndent(line)
                if !body.trimmed.isEmpty { blocks.append(.paragraph([.text(body)])) }
                i += 1
                continue
            }

            // Thematic break (---, ***, ___): drop entirely.
            if isThematicBreak(trimmed) { i += 1; continue }

            // ATX heading.
            if let (level, body) = atxHeading(trimmed) {
                if level <= RichBlock.maxHeadingLevel {
                    blocks.append(.heading(level: level, inlines: parseInline(body)))
                } else {
                    // H4–H6 downgrade to a paragraph.
                    blocks.append(.paragraph(parseInline(body)))
                }
                i += 1
                continue
            }

            // Table: a row of pipes followed by a delimiter row (---|---).
            if looksLikeTableHeader(line, next: i + 1 < lines.count ? lines[i + 1] : nil) {
                while i < lines.count, isTableRow(lines[i]) {
                    let row = lines[i]
                    if !isTableDelimiterRow(row) {
                        let cells = tableCells(row)
                        let joined = cells.joined(separator: " ").trimmed
                        if !joined.isEmpty { blocks.append(.paragraph(parseInline(joined))) }
                    }
                    i += 1
                }
                continue
            }

            // Blockquote: one or more consecutive `>`-prefixed lines.
            if trimmed.first == ">" {
                var paras: [[RichInline]] = []
                var current: [String] = []
                func flush() {
                    let joined = current.joined(separator: " ").trimmed
                    if !joined.isEmpty { paras.append(parseInline(joined)) }
                    current = []
                }
                while i < lines.count, lines[i].trimmed.first == ">" {
                    let inner = stripBlockquoteMarker(lines[i].trimmed)
                    if inner.trimmed.isEmpty { flush() } else { current.append(inner) }
                    i += 1
                }
                flush()
                if !paras.isEmpty { blocks.append(.blockquote(paras)) }
                continue
            }

            // Bullet list: -, *, + followed by a space.
            if isBulletMarker(trimmed) {
                var items: [RichListItem] = []
                while i < lines.count {
                    let t = lines[i].trimmed
                    if isBulletMarker(t) {
                        items.append(RichListItem(parseInline(bulletBody(t))))
                        i += 1
                    } else if isListContinuation(lines[i]) && !items.isEmpty {
                        // Lazy continuation line: fold into the last item.
                        appendContinuation(&items, lines[i].trimmed)
                        i += 1
                    } else { break }
                }
                blocks.append(.bulletList(items))
                continue
            }

            // Ordered list: `N.` or `N)` followed by a space.
            if let firstNum = orderedMarkerNumber(trimmed) {
                var items: [RichListItem] = []
                while i < lines.count {
                    let t = lines[i].trimmed
                    if orderedMarkerNumber(t) != nil {
                        items.append(RichListItem(parseInline(orderedBody(t))))
                        i += 1
                    } else if isListContinuation(lines[i]) && !items.isEmpty {
                        appendContinuation(&items, lines[i].trimmed)
                        i += 1
                    } else { break }
                }
                blocks.append(.orderedList(start: firstNum, items: items))
                continue
            }

            // Paragraph: gather consecutive non-blank lines that don't start a
            // new block construct.
            var paraLines: [String] = []
            while i < lines.count {
                let l = lines[i]
                let t = l.trimmed
                if t.isEmpty { break }
                if startsNewBlock(l, next: i + 1 < lines.count ? lines[i + 1] : nil) { break }
                paraLines.append(stripHTMLTags(t))
                i += 1
            }
            let joined = paraLines.joined(separator: " ").trimmed
            if !joined.isEmpty { blocks.append(.paragraph(parseInline(joined))) }
        }

        return RichTextDocument(blocks)
    }

    // MARK: - Inline parsing

    /// Parse a single line/run of inline Markdown into the closed inline
    /// vocabulary. Recognizes (in this restricted set): `` `code` ``, `**bold**`,
    /// `*italic*` / `_italic_`, `~~strike~~`, `[text](url)`, and `![alt](url)`
    /// (downgraded to alt text). Raw HTML tags are stripped. Everything else is
    /// literal text. The output never contains an image or HTML node — those
    /// aren't in the vocabulary.
    static func parseInline(_ raw: String) -> [RichInline] {
        let chars = Array(stripHTMLTags(raw))
        let runs = parseInlineChars(chars, 0, chars.count)
        return coalesce(runs)
    }

    /// Recursively parse `chars[lo..<hi]`. Restricted to the closed vocabulary.
    private static func parseInlineChars(_ chars: [Character], _ lo: Int, _ hi: Int) -> [RichInline] {
        var out: [RichInline] = []
        var textBuf = ""
        var i = lo

        func flushText() {
            if !textBuf.isEmpty { out.append(.text(textBuf)); textBuf = "" }
        }

        while i < hi {
            let c = chars[i]

            // Backslash escape: the next char is literal.
            if c == "\\", i + 1 < hi {
                textBuf.append(chars[i + 1]); i += 2; continue
            }

            // Inline code span — highest precedence, opaque content.
            if c == "`" {
                let tickRun = runLength(chars, i, hi, "`")
                if let close = findCloseTicks(chars, i + tickRun, hi, tickRun) {
                    flushText()
                    var content = String(chars[(i + tickRun)..<close])
                    // CommonMark: a single leading+trailing space is stripped if
                    // the content isn't all spaces.
                    if content.hasPrefix(" "), content.hasSuffix(" "),
                       content.contains(where: { $0 != " " }) {
                        content = String(content.dropFirst().dropLast())
                    }
                    out.append(.code(content))
                    i = close + tickRun
                    continue
                }
            }

            // Image: ![alt](url) → downgrade to alt text (NOT a link/image node).
            if c == "!", i + 1 < hi, chars[i + 1] == "[" {
                if let img = parseBracketLink(chars, i + 1, hi) {
                    flushText()
                    // Drop the URL; keep the alt label as plain text runs.
                    out.append(contentsOf: parseInlineChars(img.labelChars, 0, img.labelChars.count))
                    i = img.end
                    continue
                }
            }

            // Link: [text](url).
            if c == "[" {
                if let lnk = parseBracketLink(chars, i, hi) {
                    flushText()
                    let label = parseInlineChars(lnk.labelChars, 0, lnk.labelChars.count)
                    out.append(.link(text: label, url: lnk.url))
                    i = lnk.end
                    continue
                }
            }

            // Strikethrough: ~~…~~
            if c == "~", i + 1 < hi, chars[i + 1] == "~" {
                if let close = findClosingDelimiter(chars, i + 2, hi, "~", count: 2) {
                    flushText()
                    out.append(.strike(parseInlineChars(chars, i + 2, close)))
                    i = close + 2
                    continue
                }
            }

            // Bold: **…** or __…__
            if (c == "*" || c == "_"), i + 1 < hi, chars[i + 1] == c {
                if let close = findClosingDelimiter(chars, i + 2, hi, c, count: 2) {
                    flushText()
                    out.append(.bold(parseInlineChars(chars, i + 2, close)))
                    i = close + 2
                    continue
                }
            }

            // Italic: *…* or _…_
            if c == "*" || c == "_" {
                if let close = findClosingDelimiter(chars, i + 1, hi, c, count: 1) {
                    flushText()
                    out.append(.italic(parseInlineChars(chars, i + 1, close)))
                    i = close + 1
                    continue
                }
            }

            textBuf.append(c)
            i += 1
        }
        flushText()
        return out
    }

    /// Merge adjacent `.text` runs so output is canonical (parser hygiene that
    /// also keeps round-trips stable).
    private static func coalesce(_ runs: [RichInline]) -> [RichInline] {
        var out: [RichInline] = []
        for r in runs {
            if case let .text(t) = r, case let .text(prev)? = out.last {
                out[out.count - 1] = .text(prev + t)
            } else {
                out.append(r)
            }
        }
        // Drop empty text leaves.
        return out.filter {
            if case let .text(t) = $0 { return !t.isEmpty }
            return true
        }
    }

    // MARK: - Inline helpers

    private struct BracketLink {
        let labelChars: [Character]
        let url: String
        let end: Int   // index just past the closing ')'
    }

    /// Parse `[label](url)` starting at `chars[start] == '['`. Returns nil if it
    /// isn't a well-formed inline link (e.g. reference-style or unbalanced).
    private static func parseBracketLink(_ chars: [Character], _ start: Int, _ hi: Int) -> BracketLink? {
        guard start < hi, chars[start] == "[" else { return nil }
        var j = start + 1
        var depth = 1
        while j < hi {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "[" { depth += 1 }
            else if chars[j] == "]" { depth -= 1; if depth == 0 { break } }
            j += 1
        }
        guard j < hi, depth == 0, j + 1 < hi, chars[j + 1] == "(" else { return nil }
        let labelChars = Array(chars[(start + 1)..<j])
        var k = j + 2
        var pdepth = 1
        var url = ""
        while k < hi {
            let ch = chars[k]
            if ch == "\\", k + 1 < hi { url.append(chars[k + 1]); k += 2; continue }
            if ch == "(" { pdepth += 1; url.append(ch) }
            else if ch == ")" { pdepth -= 1; if pdepth == 0 { break }; url.append(ch) }
            else { url.append(ch) }
            k += 1
        }
        guard k < hi, pdepth == 0 else { return nil }
        let cleaned = dropLinkTitle(url.trimmed)
        return BracketLink(labelChars: labelChars, url: cleaned, end: k + 1)
    }

    /// `url "title"` → `url`.
    private static func dropLinkTitle(_ s: String) -> String {
        if let sp = s.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            return String(s[s.startIndex..<sp])
        }
        return s
    }

    /// Length of the run of `ch` starting at `i`.
    private static func runLength(_ chars: [Character], _ i: Int, _ hi: Int, _ ch: Character) -> Int {
        var n = 0
        while i + n < hi, chars[i + n] == ch { n += 1 }
        return n
    }

    /// Find a closing run of EXACTLY `count` backticks (a longer run doesn't
    /// match — CommonMark code-span rule). Returns the index of the first
    /// closing backtick, or nil.
    private static func findCloseTicks(_ chars: [Character], _ from: Int, _ hi: Int, _ count: Int) -> Int? {
        var i = from
        while i < hi {
            if chars[i] == "`" {
                let run = runLength(chars, i, hi, "`")
                if run == count { return i }
                i += run
            } else { i += 1 }
        }
        return nil
    }

    /// Find a closing emphasis delimiter: a run of `ch` of EXACTLY `count`
    /// (a different-strength run is a different delimiter — e.g. searching for a
    /// single italic `*`, a `**bold**` run is recursed PAST, not matched, so
    /// `*a **b** c*` nests correctly). Skips code spans and escapes so emphasis
    /// markers inside `` `code` `` don't close. Returns the index of the closing
    /// delimiter's first char, or nil.
    private static func findClosingDelimiter(_ chars: [Character], _ from: Int, _ hi: Int, _ ch: Character, count: Int) -> Int? {
        guard from < hi else { return nil }
        var i = from
        while i < hi {
            let c = chars[i]
            if c == "\\" { i += 2; continue }
            if c == "`" {                       // skip over a code span
                let tickRun = runLength(chars, i, hi, "`")
                if let close = findCloseTicks(chars, i + tickRun, hi, tickRun) {
                    i = close + tickRun; continue
                }
            }
            if c == ch {
                let run = runLength(chars, i, hi, ch)
                if run == count { return i }
                // A LONGER run of the same char is a stronger-emphasis span
                // (e.g. `**` while we want `*`): try to nest past it so an inner
                // strong/em doesn't prematurely close the outer one. If it
                // doesn't form a balanced inner span, fall through and consume
                // the run as literal scanning progress.
                if run > count {
                    if let innerClose = findClosingDelimiter(chars, i + run, hi, ch, count: run) {
                        i = innerClose + run; continue
                    }
                }
                i += run; continue
            }
            i += 1
        }
        return nil
    }

    // MARK: - Block helpers

    private static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var cur = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            if u == "\n" { lines.append(String(cur)); cur = String.UnicodeScalarView() }
            else if u == "\r" { /* drop a lone CR / CRLF's CR */ }
            else { cur.append(u) }
        }
        lines.append(String(cur))
        return lines
    }

    private static func fenceRun(_ trimmed: String) -> (Character, Int)? {
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        return (first, run.count)
    }

    private static func isIndentedCode(_ line: String) -> Bool {
        if line.hasPrefix("    ") { return true }
        if line.hasPrefix("\t") { return true }
        return false
    }

    private static func stripCodeIndent(_ line: String) -> String {
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        if line.hasPrefix("    ") { return String(line.dropFirst(4)) }
        return line
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        let chars = trimmed.filter { $0 != " " && $0 != "\t" }
        guard chars.count >= 3 else { return false }
        guard let first = chars.first, first == "-" || first == "*" || first == "_" else { return false }
        return chars.allSatisfy { $0 == first }
    }

    /// ATX heading: 1...6 `#`, then space or end.
    private static func atxHeading(_ trimmed: String) -> (Int, String)? {
        guard trimmed.first == "#" else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }
        let level = hashes.count
        guard level >= 1, level <= 6 else { return nil }
        let after = trimmed.dropFirst(level)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        return (level, stripATXTrailingHashes(String(after).trimmed))
    }

    private static func stripATXTrailingHashes(_ s: String) -> String {
        guard s.hasSuffix("#") else { return s }
        var i = s.endIndex
        while i > s.startIndex, s[s.index(before: i)] == "#" { i = s.index(before: i) }
        if i == s.startIndex { return "" }
        let before = s.index(before: i)
        if s[before] == " " || s[before] == "\t" {
            return String(s[..<i]).trimmed
        }
        return s
    }

    private static func isBulletMarker(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "-" || first == "*" || first == "+" else { return false }
        let rest = trimmed.dropFirst()
        return rest.first == " " || rest.first == "\t"
    }

    private static func bulletBody(_ trimmed: String) -> String {
        String(trimmed.dropFirst()).trimmed
    }

    /// `N.` or `N)` + space → N. Returns nil if not an ordered marker.
    private static func orderedMarkerNumber(_ trimmed: String) -> Int? {
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = trimmed.dropFirst(digits.count)
        guard let delim = after.first, delim == "." || delim == ")" else { return nil }
        let rest = after.dropFirst()
        guard rest.first == " " || rest.first == "\t" || rest.isEmpty else { return nil }
        return Int(digits)
    }

    private static func orderedBody(_ trimmed: String) -> String {
        let digits = trimmed.prefix { $0.isNumber }
        let after = trimmed.dropFirst(digits.count).dropFirst()  // drop digits + delimiter
        return String(after).trimmed
    }

    /// A non-blank line indented under a list item (lazy continuation).
    private static func isListContinuation(_ line: String) -> Bool {
        guard line.hasPrefix(" ") || line.hasPrefix("\t") else { return false }
        let t = line.trimmed
        guard !t.isEmpty else { return false }
        // Not itself a new list item or block construct.
        return !isBulletMarker(t) && orderedMarkerNumber(t) == nil && t.first != "#" && t.first != ">"
    }

    private static func appendContinuation(_ items: inout [RichListItem], _ text: String) {
        guard !items.isEmpty else { return }
        var last = items[items.count - 1]
        last.inlines.append(.text(" "))
        last.inlines.append(contentsOf: parseInline(text))
        items[items.count - 1] = RichListItem(coalesce(last.inlines))
    }

    private static func stripBlockquoteMarker(_ trimmed: String) -> String {
        var s = Substring(trimmed)
        if s.first == ">" { s = s.dropFirst() }
        if s.first == " " { s = s.dropFirst() }
        return String(s)
    }

    // MARK: - Table detection

    private static func isTableRow(_ line: String) -> Bool {
        line.trimmed.contains("|")
    }

    private static func looksLikeTableHeader(_ line: String, next: String?) -> Bool {
        guard line.trimmed.contains("|") else { return false }
        guard let next = next else { return false }
        return isTableDelimiterRow(next)
    }

    /// `|---|:--:|` style delimiter row.
    private static func isTableDelimiterRow(_ line: String) -> Bool {
        let t = line.trimmed
        guard t.contains("|") || t.contains("-") else { return false }
        let stripped = t.filter { $0 != "|" && $0 != " " && $0 != "\t" }
        guard !stripped.isEmpty else { return false }
        // Must contain at least one dash and only ['-', ':'].
        guard stripped.contains("-") else { return false }
        return stripped.allSatisfy { $0 == "-" || $0 == ":" }
    }

    private static func tableCells(_ line: String) -> [String] {
        var t = line.trimmed
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false)
            .map { stripHTMLTags(String($0).trimmed) }
            .filter { !$0.isEmpty }
    }

    // MARK: - HTML stripping

    /// Strip `<…>` tag spans (raw/inline HTML) but keep their text content.
    /// HTML comments `<!-- … -->` are removed whole.
    static func stripHTMLTags(_ s: String) -> String {
        guard s.contains("<") else { return s }
        var out = ""
        let chars = Array(s)
        var i = 0
        let n = chars.count
        while i < n {
            if chars[i] == "<" {
                // HTML comment.
                if i + 3 < n, chars[i + 1] == "!", chars[i + 2] == "-", chars[i + 3] == "-" {
                    if let close = findSubsequence(chars, from: i + 4, ["-", "-", ">"]) {
                        i = close + 3; continue
                    }
                }
                // Tag span: <... up to the next '>'.
                if let gt = nextIndex(chars, from: i + 1, of: ">") {
                    // Only treat as a tag if it looks like one (starts with a
                    // letter, '/', '!', or '?'); otherwise it's a literal '<'.
                    let inner = chars[(i + 1)..<gt]
                    if let f = inner.first, f.isLetter || f == "/" || f == "!" || f == "?" {
                        i = gt + 1; continue
                    }
                }
                out.append("<"); i += 1
            } else {
                out.append(chars[i]); i += 1
            }
        }
        return out
    }

    private static func nextIndex(_ chars: [Character], from: Int, of ch: Character) -> Int? {
        var i = from
        while i < chars.count { if chars[i] == ch { return i }; i += 1 }
        return nil
    }

    private static func findSubsequence(_ chars: [Character], from: Int, _ seq: [Character]) -> Int? {
        var i = from
        while i + seq.count <= chars.count {
            if Array(chars[i..<(i + seq.count)]) == seq { return i }
            i += 1
        }
        return nil
    }

    /// Whether `line` begins a new block construct (so a paragraph gather should
    /// stop before it).
    private static func startsNewBlock(_ line: String, next: String?) -> Bool {
        let t = line.trimmed
        if t.isEmpty { return true }
        if atxHeading(t) != nil { return true }
        if isBulletMarker(t) { return true }
        if orderedMarkerNumber(t) != nil { return true }
        if t.first == ">" { return true }
        if fenceRun(t) != nil { return true }
        if isThematicBreak(t) { return true }
        if looksLikeTableHeader(line, next: next) { return true }
        return false
    }
}

// MARK: - String trim convenience

private extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
