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

    /// How author-embedded raw HTML (CommonMark §6.6 HTML blocks / inline
    /// HTML) is treated when rendering the body.
    ///
    /// - `.sanitize`: emit it through `HTMLSanitizer.sanitize` (the in-app
    ///   default). The in-app `WKWebView` document carries a strict
    ///   `default-src 'none'` CSP that backstops any sanitizer miss, so richer
    ///   author HTML (figures, asides, MathJax spans) is allowed there.
    /// - `.escape`: HTML-escape it to VISIBLE TEXT — no live markup at all.
    ///   Used on the CSP-light standalone EXPORT / Open-in-Browser path
    ///   (TSK-966): that document is opened in a normal browser with
    ///   `file://` privileges where the regex sanitizer would be the SOLE
    ///   defense and has confirmed bypasses. Escaping removes the renderer
    ///   as an injection vector entirely; the document's own `<meta>` CSP is
    ///   then the second, independent layer.
    public enum AuthorHTMLDisposition: Sendable {
        case sanitize
        case escape
    }

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

    public func render(_ markdown: String,
                       authorHTML: AuthorHTMLDisposition = .sanitize) -> String {
        PerfSignpost.withInterval(.render, "HTMLRenderer.render") {
            // Routed through the `.markdown` gate (TSK-648): the Rust core's
            // structural render + host chunk splice when on, the incumbent
            // Swift visitor path otherwise. `authorHTML` decides how embedded
            // raw HTML is treated at BOTH the rust splice and the Swift visitor
            // (TSK-966): in-app sanitizes (CSP backstops); export escapes.
            RustMarkdownAdapter.render(markdown, authorHTML: authorHTML)
        }
    }

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


/// STAGE-B DELETED TWIN (TSK-649, 2026-07-07): the Swift `MarkupVisitor`
/// traversal (the markdown→HTML structural renderer) that lived here was
/// deleted — the engine is rust-core's `markdown.rs` (TSK-631 port:
/// structure, slugs, frontmatter, metadata blocks, URL safety pinned
/// there), and `HTMLRenderer.render` routes through `RustMarkdownAdapter`.
/// What remains is the UTILITY surface shared by the rust splice path and
/// the TOC: `htmlEscape`, `spanned` (highlight-run spans), and the slug
/// algorithm (`baseSlug`/`uniqueSlug` ≡ rust `unique_slug`).
/// The PARSE-03 leading-nesting guard died with the recursive visitor —
/// pulldown-cmark is iterative (no C stack to protect).
struct HTMLVisitor {

    /// The labeled diagram-source figure for a dot/plantuml fence — spliced
    /// by `RustMarkdownAdapter.enrich` for the core's `diagram` chunks
    /// (TSK-713 parity with the deleted visitor's diagram routing).
    func renderDiagramSourceBlock(_ descriptor: DiagramDescriptor) -> String {
        let kind = descriptor.kind.rawValue
        let label: String
        switch descriptor.kind {
        case .dot:      label = "Graphviz DOT"
        case .plantuml: label = "PlantUML"
        case .mermaid:  label = "Mermaid"
        }
        var caption = label
        if let type = descriptor.metadata["diagramType"] {
            caption += " (\(type))"
        } else if descriptor.metadata["directed"] == "true" {
            caption += " (digraph)"
        } else if descriptor.metadata["directed"] == "false" {
            caption += " (graph)"
        }
        let body = htmlEscape(descriptor.source)
        return "<figure class=\"mdv-diagram\" data-mdv-diagram=\"\(htmlEscape(kind))\">"
            + "<figcaption class=\"mdv-diagram-caption\">\(htmlEscape(caption))</figcaption>"
            + "<pre><code class=\"language-\(htmlEscape(descriptor.language))\">\(body)</code></pre>"
            + "</figure>\n"
    }

    static func baseSlug(for text: String) -> String {
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
        return slug.isEmpty ? "section" : slug
    }

    static func uniqueSlug(for text: String, used: inout [String: Int]) -> String {
        let slug = baseSlug(for: text)
        if let n = used[slug] {
            used[slug] = n + 1
            return "\(slug)-\(n + 1)"
        } else {
            used[slug] = 0
            return slug
        }
    }


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
