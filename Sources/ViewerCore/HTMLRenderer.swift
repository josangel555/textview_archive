import Foundation
import Markdown
import ViewerKit

/// Walks a `swift-markdown` AST and emits HTML. Pure logic — no UI imports.
/// The output is meant to be loaded into `WKWebView` with a bundled stylesheet.
///
/// In Phase 5b, code-fence rendering grows a hook for `Highlighter` so it can
/// emit `<span class="hl-X">` runs (see DESIGN.md §11). For now fences render
/// as plain `<pre><code class="language-foo">`.
public struct HTMLRenderer: Sendable {
    public init() {}

    /// Pre-parse leading block-nesting ceilings (PARSE-03, input side).
    ///
    /// `HTMLVisitor.maxDepth` bounds *our* visitor recursion, but it sits
    /// downstream of `Document(parsing:)`. cmark-gfm itself parses
    /// adversarial input into its tree via a native-C recursive descent
    /// with no effective bound for our reachable input sizes: ~6000 leading
    /// `>` (or equivalent list indentation — ~8–12 KB, three orders of
    /// magnitude below `markdownRenderMaxBytes`) overflows the C stack
    /// inside `Document(parsing:)` and SIGSEGVs the process *before* the
    /// visitor (and its guard) ever runs. That crash is in native C and is
    /// uncatchable from Swift, so the only reliable defense is to refuse
    /// the input before handing it to cmark.
    ///
    /// Two distinct crash arms, two distinct per-line ceilings:
    ///  - `>` blockquote opens. Empirically OK at 5000 `>`, SIGSEGV at
    ///    6000+ (the host G5 corpus exercises the 5000 case live), so we
    ///    cap the per-line `>` run at `maxLeadingBlockquoteRun` (5500) —
    ///    above the proven-safe 5000, comfortably below the 6000 floor.
    ///  - leading whitespace (space / tab) drives nested list/continuation
    ///    depth, which cmark traps on at *lower* indentation than `>`.
    ///    Legitimate prose never has a multi-hundred-character leading
    ///    indent, so we cap the per-line whitespace run far tighter at
    ///    `maxLeadingIndentRun` (1024 = 2× the visitor's `maxDepth`).
    ///
    /// Both keep wide margin below cmark's crash floor, covering the
    /// smaller stack of the off-main render hop (G1). Note the runs are
    /// counted independently — a `> > > …` document spends most of its
    /// leading bytes as `>`, governed by the blockquote ceiling.
    static let maxLeadingBlockquoteRun = 5500
    static let maxLeadingIndentRun = 1024

    public func render(_ markdown: String) -> String {
        PerfSignpost.withInterval(.render, "HTMLRenderer.render") {
            // Routed through the `.markdown` gate (TSK-648): the Rust core's
            // structural render + host chunk splice when on, the incumbent
            // Swift visitor path otherwise.
            RustMarkdownAdapter.render(markdown)
        }
    }

    /// The incumbent Swift visitor path — the rust adapter's fallback arm
    /// (and the only path until the `.markdown` gate defaults on).
    static func renderSwiftPath(_ markdown: String) -> String {
        // PARSE-03 input-side guard: reject pathologically deep block
        // nesting BEFORE cmark's native recursive descent can blow the
        // C stack. Emit the same truncation marker the visitor uses so
        // callers (and tests) get a graceful, non-empty result instead
        // of a crash. The UI layer's `markdownRenderMaxBytes` cap
        // (LargeMarkdownPlaceholderView) is the coarse byte gate; this
        // is the fine nesting gate cmark needs that bytes alone miss.
        // The guard is SWIFT-PATH-ONLY by design: pulldown (the rust
        // path) is iterative and has no C stack to blow.
        if Self.exceedsLeadingBlockNesting(markdown) {
            return HTMLVisitor.truncationMarker
        }
        let document = Document(parsing: markdown)
        var visitor = HTMLVisitor()
        return visitor.visit(document)
    }

    /// Single-pass O(n) scan: returns `true` once any line's leading `>`
    /// count exceeds `maxLeadingBlockquoteRun`, or its longest *contiguous*
    /// leading whitespace run exceeds `maxLeadingIndentRun`.
    ///
    /// "Leading" = the prefix of the line cmark consumes to open nested
    /// containers, before any other content. The two arms are measured
    /// differently on purpose:
    ///  - `>` accumulates across the whole leading prefix (`> > > …` opens
    ///    one blockquote level per `>`, regardless of the single padding
    ///    space cmark allows after each marker).
    ///  - whitespace is measured as the longest *contiguous* run, reset by
    ///    `>` — so the lone space after each `>` in `> > > …` never climbs
    ///    past 1, while a genuine multi-thousand-space list indent trips
    ///    it. This keeps the two crash arms independent and avoids the
    ///    false-reject where blockquote padding spaces masquerade as deep
    ///    indentation.
    ///
    /// A multi-thousand-character leading run is the adversarial shape;
    /// legitimate prose nests in single digits. We scan UTF-8 bytes (a
    /// contiguous view, no grapheme segmentation), reset state at every
    /// line break, and bail early on the first offending line.
    static func exceedsLeadingBlockNesting(_ markdown: String) -> Bool {
        var bqCount = 0          // total leading `>` on this line
        var wsRun = 0            // current contiguous leading-whitespace run
        var atLineStart = true   // still inside the line's leading prefix
        for b in markdown.utf8 {
            switch b {
            case 0x0A, 0x0D:           // \n, \r — line break resets state
                bqCount = 0
                wsRun = 0
                atLineStart = true
            case 0x3E:                 // '>'  blockquote open
                if atLineStart {
                    wsRun = 0           // `>` breaks any contiguous indent run
                    bqCount += 1
                    if bqCount > maxLeadingBlockquoteRun { return true }
                }
            case 0x20, 0x09:           // ' ' / '\t' indent
                if atLineStart {
                    wsRun += 1
                    if wsRun > maxLeadingIndentRun { return true }
                }
            default:                   // any other byte ends the leading prefix
                atLineStart = false
            }
        }
        return false
    }

    /// Render a full HTML page wrapped in `<html>...</html>` with the bundled
    /// stylesheet inlined. The view loads this directly into WKWebView.
    ///
    /// Includes a strict Content-Security-Policy (CRIT-1) that denies network
    /// requests, scripts, iframes, plugins, base/form retargeting. Local file
    /// images are still allowed (markdown documents reference relative images).
    ///
    /// `extraStylesheet` is appended verbatim inside the same `<style>` block.
    /// Used to inline feature-specific CSS (e.g. the mermaid shim's palette)
    /// without forcing every caller to rebuild a combined stylesheet string.
    /// Defaults to empty so existing call sites compile unchanged.
    public func renderPage(_ markdown: String,
                           stylesheet: String,
                           extraStylesheet: String = "") -> String {
        let body = render(markdown)
        let csp = "default-src 'none'; img-src file: data:; style-src 'unsafe-inline'; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none';"
        // Keep the single-stylesheet form byte-identical to the pre-mermaid
        // output so existing tests (and CI snapshots, if any) don't churn.
        // Only emit the extra stylesheet when a caller actually supplies one.
        let styleBlock = extraStylesheet.isEmpty
            ? "<style>\(stylesheet)</style>"
            : "<style>\(stylesheet)\n\(extraStylesheet)</style>"
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <!-- TSK-812: WebKit DNS-prefetches link href HOSTS without a click, as a
             perf optimization the CSP does NOT govern (it's a DNS-layer step
             before any connection). Left on, viewing a doc with external links
             would leak those hostnames — what the user is reading — to DNS. This
             is the documented mechanism to disable it. -->
        <meta http-equiv="x-dns-prefetch-control" content="off">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        \(styleBlock)
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}

struct HTMLVisitor: MarkupVisitor {
    typealias Result = String

    /// Used to de-dupe heading anchor IDs within a single document.
    var usedSlugs: [String: Int] = [:]

    /// Current AST recursion depth. PARSE-03: `swift-markdown` parses
    /// adversarial input like 5000 nested `>` blockquotes (or list
    /// items) into an equally-deep tree, and a naive recursive visitor
    /// blows the stack walking it — a hard crash, not a graceful
    /// failure. We bound the recursion: beyond `maxDepth` we stop
    /// descending and emit a single truncation marker instead of
    /// recursing further.
    var depth: Int = 0

    /// Recursion ceiling. ~512 is comfortably deep enough for any
    /// legitimate document (real prose rarely nests past single
    /// digits) while staying well under the stack budget — each
    /// `visit` frame for a container node is modest, and the default
    /// main-thread stack (512 KB–8 MB) tolerates a few thousand, but we
    /// keep a wide margin since the off-main render hop (G1) may run on
    /// a thread with a smaller stack.
    static let maxDepth = 512

    /// HTML comment emitted in place of a subtree we refused to descend
    /// into. Invisible in the rendered page; greppable in the source.
    static let truncationMarker = "<!-- markdown nesting too deep; truncated -->\n"

    /// Visit `children` one level deeper, returning the truncation
    /// marker (without recursing) once `maxDepth` is hit. Centralizes
    /// the depth bookkeeping so every container visitor shares it.
    mutating func descend<S: Sequence>(_ children: S) -> String
        where S.Element == any Markup {
        if depth >= Self.maxDepth { return Self.truncationMarker }
        depth += 1
        defer { depth -= 1 }
        return children.map { visit($0) }.joined()
    }

    mutating func defaultVisit(_ markup: any Markup) -> String {
        descend(markup.children)
    }

    mutating func visitDocument(_ document: Document) -> String {
        descend(document.children)
    }

    // MARK: Block-level

    mutating func visitHeading(_ heading: Heading) -> String {
        let inner = descend(heading.children)
        let slug = HTMLVisitor.uniqueSlug(for: heading.plainText, used: &usedSlugs)
        return "<h\(heading.level) id=\"\(slug)\">\(inner)</h\(heading.level)>\n"
    }

    /// GitHub-flavored slug: lowercase, ASCII alphanumerics & dashes; spaces and
    /// other characters collapse to single dashes; trim leading/trailing dashes.
    /// `used` tracks already-issued slugs in this document to disambiguate.
    static func uniqueSlug(for text: String, used: inout [String: Int]) -> String {
        var slug = ""
        slug.reserveCapacity(text.count)
        var lastWasDash = true
        for scalar in text.unicodeScalars {
            let ch = Character(scalar)
            if ch.isLetter || ch.isNumber {
                slug.append(Character(ch.lowercased()))
                lastWasDash = false
            } else if !lastWasDash {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "section" }
        if let n = used[slug] {
            used[slug] = n + 1
            return "\(slug)-\(n + 1)"
        } else {
            used[slug] = 0
            return slug
        }
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        let inner = descend(paragraph.children)
        return "<p>\(inner)</p>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let infoString = codeBlock.language ?? ""

        // Mermaid intercept (case-insensitive). Emit a host <div> that
        // the JS shim picks up on DOMContentLoaded — `mermaid.run({ nodes })`
        // reads the raw source from the element's text content. Step
        // annotations + an optional `%% @id` are parsed Swift-side once
        // and serialized into data-attributes so the shim doesn't have
        // to re-walk the source.
        if infoString.lowercased() == "mermaid" {
            return renderMermaidHost(source: codeBlock.code)
        }

        let langAttr = infoString.isEmpty
            ? ""
            : " class=\"language-\(htmlEscape(infoString))\""
        let lang = HighlightLanguage.detect(fromInfoString: infoString)
        let body: String
        if lang != .plainText {
            // Tokenize the fence body and emit per-run spans the
            // stylesheet themes via the tok-* class set. Engine is
            // shared + thread-safe; calling synchronously here is fine.
            let runs = RustHighlightAdapter.tokenize(codeBlock.code, language: lang)
            body = spanned(codeBlock.code, runs: runs)
        } else {
            body = htmlEscape(codeBlock.code)
        }
        return "<pre><code\(langAttr)>\(body)</code></pre>\n"
    }

    /// Builds the `<div class="mdv-mermaid">` host element consumed by
    /// `mermaid-shim.js`. The raw source is preserved both as a child
    /// text node (so mermaid's scanner picks it up unmodified) and as a
    /// `data-mdv-src` attribute (so theme-flip re-renders can restore the
    /// pristine source after mermaid has mutated the host children).
    func renderMermaidHost(source: String) -> String {
        let parsed = MermaidSourceParser.parse(source)
        let hash = MermaidSourceParser.shortHash(source)
        let id = parsed.id ?? "mdv-mermaid-\(hash)"

        var attrs = "class=\"mdv-mermaid\""
        attrs += " data-mdv-id=\"\(htmlEscape(id))\""
        attrs += " data-mdv-src-hash=\"\(hash)\""
        if !parsed.steps.isEmpty {
            let json = MermaidSourceParser.encodeSteps(parsed.steps)
            attrs += " data-mdv-steps=\"\(htmlEscape(json))\""
        }
        // Pristine source stashed for theme-flip re-render. Encoding via
        // htmlEscape collapses quotes/angle-brackets into entity refs,
        // which the shim's `setAttribute`/`getAttribute` pair round-trips
        // through the DOM unmodified.
        attrs += " data-mdv-src=\"\(htmlEscape(source))\""

        // The visible text-node child is what `mermaid.run({ nodes })`
        // parses. We deliberately do not wrap it in `<code>`/`<pre>` —
        // mermaid's tokenizer is whitespace-sensitive and our stylesheet
        // rules for `pre`/`code` would visually leak into the host.
        return "<div \(attrs)>\(htmlEscape(source))</div>\n"
    }

    /// Emit text with per-run `<span class="tok-X">` wrappers using
    /// the engine's UTF-16 NSRange runs. Defensive against unsorted /
    /// overlapping input (the engine resolves overlaps before
    /// returning, but assume nothing).
    func spanned(_ text: String, runs: [HighlightRun]) -> String {
        let ns = text as NSString
        let len = ns.length
        if runs.isEmpty || len == 0 { return htmlEscape(text) }
        var out = ""
        out.reserveCapacity(text.count + runs.count * 32)
        var cursor = 0
        for run in runs.sorted(by: { $0.range.location < $1.range.location }) {
            let lo = max(cursor, run.range.location)
            let hi = min(len, run.range.location + run.range.length)
            if lo > cursor {
                out += htmlEscape(ns.substring(with: NSRange(location: cursor, length: lo - cursor)))
            }
            if hi > lo {
                let chunk = ns.substring(with: NSRange(location: lo, length: hi - lo))
                out += "<span class=\"tok-\(run.kind.rawValue.lowercased())\">"
                out += htmlEscape(chunk)
                out += "</span>"
            }
            cursor = max(cursor, hi)
        }
        if cursor < len {
            out += htmlEscape(ns.substring(with: NSRange(location: cursor, length: len - cursor)))
        }
        return out
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        if depth >= Self.maxDepth { return Self.truncationMarker }
        let inner = descend(blockQuote.children)
        return "<blockquote>\n\(inner)</blockquote>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        if depth >= Self.maxDepth { return Self.truncationMarker }
        let items = descend(orderedList.children)
        return "<ol>\n\(items)</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        if depth >= Self.maxDepth { return Self.truncationMarker }
        let items = descend(unorderedList.children)
        return "<ul>\n\(items)</ul>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        if depth >= Self.maxDepth { return Self.truncationMarker }
        let inner = descend(listItem.children)
        guard let checkbox = listItem.checkbox else { return "<li>\(inner)</li>\n" }
        // TSK-903: GFM task item → disabled checkbox INSIDE the leading <p>, so
        // it matches the Rust path byte-for-byte (the A/B parity suite pins it).
        let box = checkbox == .checked
            ? "<input type=\"checkbox\" disabled checked/> "
            : "<input type=\"checkbox\" disabled/> "
        if inner.hasPrefix("<p>") {
            return "<li><p>\(box)\(inner.dropFirst(3))</li>\n"
        }
        return "<li>\(box)\(inner)</li>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr/>\n"
    }

    mutating func visitTable(_ table: Table) -> String {
        var out = "<table>\n<thead><tr>"
        for cell in table.head.cells {
            let inner = descend(cell.children)
            out += "<th>\(inner)</th>"
        }
        out += "</tr></thead>\n<tbody>\n"
        for row in table.body.rows {
            out += "<tr>"
            for cell in row.cells {
                let inner = descend(cell.children)
                out += "<td>\(inner)</td>"
            }
            out += "</tr>\n"
        }
        out += "</tbody></table>\n"
        return out
    }

    /// A9 — Raw HTML pass-through.
    ///
    /// **Hardened 2026-05-25 (finding §2.1):** raw HTML now flows through
    /// `HTMLSanitizer.sanitize` before being emitted. We still emit
    /// CommonMark's HTMLBlock / InlineHTML payloads so authored markdown
    /// can embed legitimate HTML (figures, asides, tables, MathJax-style
    /// spans, etc.), but `<script>`, `<iframe>`, `<form>`, on-handlers,
    /// and `javascript:` URLs are stripped at the renderer boundary.
    /// The previous defense — inline CSP `<meta>` only — was fragile
    /// against WebKit version differences and against `<script>` blocks
    /// that race the CSP processing order. See
    /// `docs/code-review/SECURITY_CONCURRENCY_2026-05-25.md` §2.1 for
    /// the full threat model.
    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        HTMLSanitizer.sanitize(html.rawHTML)
    }

    // MARK: Inline

    mutating func visitText(_ text: Text) -> String {
        htmlEscape(text.string)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        let inner = descend(emphasis.children)
        return "<em>\(inner)</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        let inner = descend(strong.children)
        return "<strong>\(inner)</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        let inner = descend(strikethrough.children)
        return "<del>\(inner)</del>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(htmlEscape(inlineCode.code))</code>"
    }

    mutating func visitLink(_ link: Link) -> String {
        let href = HTMLVisitor.safeURL(link.destination ?? "", for: .link)
        let inner = descend(link.children)
        let titleAttr: String
        if let title = link.title, !title.isEmpty {
            titleAttr = " title=\"\(htmlEscape(title))\""
        } else {
            titleAttr = ""
        }
        return "<a href=\"\(htmlEscape(href))\"\(titleAttr)>\(inner)</a>"
    }

    mutating func visitImage(_ image: Image) -> String {
        let src = HTMLVisitor.safeURL(image.source ?? "", for: .image)
        let alt = image.plainText
        return "<img src=\"\(htmlEscape(src))\" alt=\"\(htmlEscape(alt))\"/>"
    }

    // MARK: URL scheme safety (S5 / F-06)

    enum URLContext { case link, image }

    /// Returns the URL if its scheme is on the allowlist, otherwise `"about:blank"`.
    /// - Allowed for links: `http`, `https`, `mailto`, fragment (`#…`), and
    ///   anything without a scheme (relative path).
    /// - Allowed for images: `http`, `https`, `file`, `data:` (capped),
    ///   fragment, and anything without a scheme.
    /// `javascript:`, `vbscript:`, custom-app schemes, and (for links) `file:`
    /// and `data:` are rewritten so a malicious markdown can't smuggle them
    /// even if WKWebView's policy delegate is bypassed for the initial load.
    static func safeURL(_ raw: String, for ctx: URLContext) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "about:blank" }
        // Fragment-only ("#foo") and relative paths (no scheme).
        if trimmed.hasPrefix("#") { return trimmed }
        if let colon = trimmed.firstIndex(of: ":") {
            // Authority-relative ("//host/x") starts with "//" before any colon.
            let prefix = trimmed[trimmed.startIndex..<colon].lowercased()
            // If the prefix has chars outside [a-z0-9+.-] it isn't a scheme.
            let isScheme = prefix.allSatisfy {
                $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "."
            } && !prefix.isEmpty
            if !isScheme { return trimmed }
            let allowed: Set<String>
            switch ctx {
            case .link:  allowed = ["http", "https", "mailto"]
            case .image: allowed = ["http", "https", "file", "data"]
            }
            if allowed.contains(prefix) {
                if prefix == "data", ctx == .image {
                    // Only allow image/* data URLs.
                    let rest = trimmed[trimmed.index(after: colon)...]
                    if rest.hasPrefix("image/") { return trimmed }
                    return "about:blank"
                }
                return trimmed
            }
            return "about:blank"
        }
        return trimmed
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        // See visitHTMLBlock for the rationale on routing through
        // HTMLSanitizer (finding §2.1).
        HTMLSanitizer.sanitize(inlineHTML.rawHTML)
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String { "\n" }
    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String { "<br/>\n" }

    // MARK: Helpers

    /// HTML-escape the five significant characters. PERF-06-escape:
    /// iterates `s.utf8` (a contiguous byte view, no grapheme-cluster
    /// segmentation) with a fast path that copies whole runs of safe
    /// bytes via `appendUnsafe`, only breaking the run to emit an
    /// entity reference for `& < > " '`. The escapable set is all
    /// ASCII, and UTF-8 guarantees a multibyte scalar's continuation
    /// bytes are all ≥ 0x80, so they can never be mistaken for one of
    /// the escapables — byte-level scanning is correct without decoding
    /// scalars. The previous version walked `Character`s, paying
    /// grapheme-breaking cost on every char of (typically) escape-free
    /// text.
    func htmlEscape(_ s: String) -> String {
        let utf8 = s.utf8
        var out = ""
        out.reserveCapacity(utf8.count)
        var run = utf8.startIndex
        var i = utf8.startIndex
        // Flush the pending safe-byte run [run, i) into `out`.
        func flush() {
            if run < i {
                out += String(decoding: utf8[run..<i], as: UTF8.self)
            }
        }
        while i < utf8.endIndex {
            let b = utf8[i]
            let entity: StaticString?
            switch b {
            case 0x26: entity = "&amp;"   // &
            case 0x3C: entity = "&lt;"    // <
            case 0x3E: entity = "&gt;"    // >
            case 0x22: entity = "&quot;"  // "
            case 0x27: entity = "&#39;"   // '
            default:   entity = nil
            }
            if let entity {
                flush()
                entity.withUTF8Buffer { out += String(decoding: $0, as: UTF8.self) }
                i = utf8.index(after: i)
                run = i
            } else {
                i = utf8.index(after: i)
            }
        }
        flush()
        return out
    }
}
