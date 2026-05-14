import Foundation
import Markdown

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
    public func renderPage(_ markdown: String, stylesheet: String) -> String {
        let body = render(markdown)
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
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

    mutating func defaultVisit(_ markup: any Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }

    mutating func visitDocument(_ document: Document) -> String {
        document.children.map { visit($0) }.joined()
    }

    // MARK: Block-level

    mutating func visitHeading(_ heading: Heading) -> String {
        let inner = heading.children.map { visit($0) }.joined()
        return "<h\(heading.level)>\(inner)</h\(heading.level)>\n"
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        let inner = paragraph.children.map { visit($0) }.joined()
        return "<p>\(inner)</p>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let lang = codeBlock.language ?? ""
        let langAttr = lang.isEmpty ? "" : " class=\"language-\(htmlEscape(lang))\""
        return "<pre><code\(langAttr)>\(htmlEscape(codeBlock.code))</code></pre>\n"
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
        let href = link.destination ?? ""
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
        let src = image.source ?? ""
        let alt = image.plainText
        return "<img src=\"\(htmlEscape(src))\" alt=\"\(htmlEscape(alt))\"/>"
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
