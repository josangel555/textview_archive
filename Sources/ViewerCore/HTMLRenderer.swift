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

    public func render(_ markdown: String) -> String {
        let document = Document(parsing: markdown)
        var visitor = HTMLVisitor()
        return visitor.visit(document)
    }

    /// Render a full HTML page wrapped in `<html>...</html>` with the bundled
    /// stylesheet inlined. The view loads this directly into WKWebView.
    ///
    /// Includes a strict Content-Security-Policy (CRIT-1) that denies network
    /// requests, scripts, iframes, plugins, base/form retargeting. Local file
    /// images are still allowed (markdown documents reference relative images).
    public func renderPage(_ markdown: String, stylesheet: String) -> String {
        let body = render(markdown)
        let csp = "default-src 'none'; img-src file: data:; style-src 'unsafe-inline'; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none';"
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(stylesheet)</style>
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

    mutating func defaultVisit(_ markup: any Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    mutating func visitDocument(_ document: Document) -> String {
        document.children.map { visit($0) }.joined()
    }

    // MARK: Block-level

    mutating func visitHeading(_ heading: Heading) -> String {
        let inner = heading.children.map { visit($0) }.joined()
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
        let inner = paragraph.children.map { visit($0) }.joined()
        return "<p>\(inner)</p>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let infoString = codeBlock.language ?? ""
        let langAttr = infoString.isEmpty
            ? ""
            : " class=\"language-\(htmlEscape(infoString))\""
        let lang = HighlightLanguage.detect(fromInfoString: infoString)
        let body: String
        if lang != .plainText {
            // Tokenize the fence body and emit per-run spans the
            // stylesheet themes via the tok-* class set. Engine is
            // shared + thread-safe; calling synchronously here is fine.
            let runs = TreeSitterEngine.shared.tokenize(codeBlock.code, language: lang)
            body = spanned(codeBlock.code, runs: runs)
        } else {
            body = htmlEscape(codeBlock.code)
        }
        return "<pre><code\(langAttr)>\(body)</code></pre>\n"
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
        let inner = blockQuote.children.map { visit($0) }.joined()
        return "<blockquote>\n\(inner)</blockquote>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        let items = orderedList.children.map { visit($0) }.joined()
        return "<ol>\n\(items)</ol>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        let items = unorderedList.children.map { visit($0) }.joined()
        return "<ul>\n\(items)</ul>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        let inner = listItem.children.map { visit($0) }.joined()
        return "<li>\(inner)</li>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr/>\n"
    }

    mutating func visitTable(_ table: Table) -> String {
        var out = "<table>\n<thead><tr>"
        for cell in table.head.cells {
            let inner = cell.children.map { visit($0) }.joined()
            out += "<th>\(inner)</th>"
        }
        out += "</tr></thead>\n<tbody>\n"
        for row in table.body.rows {
            out += "<tr>"
            for cell in row.cells {
                let inner = cell.children.map { visit($0) }.joined()
                out += "<td>\(inner)</td>"
            }
            out += "</tr>\n"
        }
        out += "</tbody></table>\n"
        return out
    }

    /// A9 — Raw HTML pass-through. We deliberately emit CommonMark's
    /// HTMLBlock / InlineHTML payloads verbatim so authored markdown can
    /// embed legitimate HTML (figures, asides, etc). The trust assumption is
    /// "the markdown file is something the user opened", and the WKWebView
    /// host neutralizes the dangerous payloads via:
    ///  • allowsContentJavaScript = false (no inline `<script>` execution)
    ///  • CSP `<meta>` injected by renderPage (no remote resources,
    ///    no iframes/objects/forms/connect)
    /// If we ever render markdown from a truly untrusted source (network
    /// fetch, etc.), this method should be swapped for one that sanitizes
    /// against an allowlist.
    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        html.rawHTML
    }

    // MARK: Inline

    mutating func visitText(_ text: Text) -> String {
        htmlEscape(text.string)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        let inner = emphasis.children.map { visit($0) }.joined()
        return "<em>\(inner)</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        let inner = strong.children.map { visit($0) }.joined()
        return "<strong>\(inner)</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        let inner = strikethrough.children.map { visit($0) }.joined()
        return "<del>\(inner)</del>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(htmlEscape(inlineCode.code))</code>"
    }

    mutating func visitLink(_ link: Link) -> String {
        let href = HTMLVisitor.safeURL(link.destination ?? "", for: .link)
        let inner = link.children.map { visit($0) }.joined()
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
        inlineHTML.rawHTML
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String { "\n" }
    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String { "<br/>\n" }

    // MARK: Helpers

    func htmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&":  out += "&amp;"
            case "<":  out += "&lt;"
            case ">":  out += "&gt;"
            case "\"": out += "&quot;"
            case "'":  out += "&#39;"
            default:   out.append(ch)
            }
        }
        return out
    }
}
