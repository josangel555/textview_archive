import Foundation

/// Serialize the restricted ``RichTextDocument`` IR back to canonical Markdown
/// (TSK-706). "Canonical" means a single, stable spelling per construct so the
/// round-trip is idempotent:
///
///     parse(serialize(parse(x))) == parse(x)
///
/// Choices that pin the canonical form:
///   - Headings: `#`/`##`/`###` + single space.
///   - Bold: `**…**`. Italic: `*…*`. Strike: `~~…~~`. Code: `` `…` ``.
///   - Bullet lists: `- ` per item. Ordered lists: renumber sequentially from
///     `start` with `N. `.
///   - Blockquote: each inner paragraph as a `> `-prefixed line, paragraphs
///     separated by a blank `>` line.
///   - Blocks separated by a single blank line.
///   - Inline code that itself contains backticks is fenced with a longer
///     backtick run (CommonMark) so it parses back identically.
public enum RichTextSerializer {

    public static func serialize(_ doc: RichTextDocument) -> String {
        let parts = doc.blocks.map(serializeBlock)
        return parts.joined(separator: "\n\n")
    }

    static func serializeBlock(_ block: RichBlock) -> String {
        switch block {
        case let .heading(level, inlines):
            let clamped = min(max(level, 1), RichBlock.maxHeadingLevel)
            return String(repeating: "#", count: clamped) + " " + serializeInlines(inlines)

        case let .paragraph(inlines):
            return serializeInlines(inlines)

        case let .bulletList(items):
            return items.map { "- " + serializeInlines($0.inlines) }
                .joined(separator: "\n")

        case let .orderedList(start, items):
            var lines: [String] = []
            var n = max(start, 1)
            for item in items {
                lines.append("\(n). " + serializeInlines(item.inlines))
                n += 1
            }
            return lines.joined(separator: "\n")

        case let .blockquote(paras):
            let rendered = paras.map { serializeInlines($0) }
            // Join paragraphs with an empty quote line so they re-parse as
            // separate paragraphs inside the quote.
            return rendered
                .map { "> " + $0 }
                .joined(separator: "\n>\n")

        case let .codeBlock(code):
            // TSK-1327: a fenced block. Per CommonMark, the fence must be longer
            // than any backtick run inside the code so it can't close early.
            var longestRun = 0, run = 0
            for ch in code {
                if ch == "`" { run += 1; longestRun = max(longestRun, run) } else { run = 0 }
            }
            let fence = String(repeating: "`", count: max(3, longestRun + 1))
            return fence + "\n" + code + "\n" + fence

        case let .table(header, rows):
            // TSK-1427: GFM pipe table. Cells: serialize inlines, then escape `|`
            // and flatten newlines so a cell can't break the row. Ragged rows are
            // padded/truncated to the header's column count.
            func cell(_ inlines: [RichInline]) -> String {
                serializeInlines(inlines)
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "|", with: "\\|")
            }
            let cols = max(1, header.count)
            func row(_ cells: [[RichInline]]) -> String {
                var c = cells.map(cell)
                if c.count < cols { c += Array(repeating: "", count: cols - c.count) }
                if c.count > cols { c = Array(c.prefix(cols)) }
                return "| " + c.joined(separator: " | ") + " |"
            }
            var lines = [row(header)]
            lines.append("| " + Array(repeating: "---", count: cols).joined(separator: " | ") + " |")
            for r in rows { lines.append(row(r)) }
            return lines.joined(separator: "\n")
        }
    }

    static func serializeInlines(_ inlines: [RichInline]) -> String {
        inlines.map(serializeInline).joined()
    }

    private static func serializeInline(_ inline: RichInline) -> String {
        switch inline {
        case let .text(t):
            return escapeText(t)
        case let .bold(children):
            return "**" + serializeInlines(children) + "**"
        case let .italic(children):
            return "*" + serializeInlines(children) + "*"
        case let .strike(children):
            return "~~" + serializeInlines(children) + "~~"
        case let .code(c):
            return serializeCode(c)
        case let .link(text, url):
            return "[" + serializeInlines(text) + "](" + url + ")"
        }
    }

    /// Wrap inline code in the shortest backtick run that doesn't collide with a
    /// backtick run inside the content (CommonMark). Pad with a space when the
    /// content begins/ends with a backtick.
    private static func serializeCode(_ c: String) -> String {
        let maxRun = longestBacktickRun(c)
        let fence = String(repeating: "`", count: maxRun + 1)
        let needsPad = c.hasPrefix("`") || c.hasSuffix("`")
        if needsPad {
            return fence + " " + c + " " + fence
        }
        return fence + c + fence
    }

    private static func longestBacktickRun(_ s: String) -> Int {
        var maxRun = 0
        var cur = 0
        for ch in s {
            if ch == "`" { cur += 1; maxRun = max(maxRun, cur) }
            else { cur = 0 }
        }
        return maxRun
    }

    /// Escape the Markdown metacharacters that would otherwise re-parse as
    /// markup, so a literal text leaf round-trips. We escape the inline
    /// delimiters (`*`, `_`, `` ` ``, `~`), brackets/parens that begin links,
    /// and a leading `#`/`>`/`-` that would start a block. Conservative: only
    /// what the restricted parser actually re-interprets.
    private static func escapeText(_ t: String) -> String {
        var out = ""
        let chars = Array(t)
        for (idx, ch) in chars.enumerated() {
            switch ch {
            case "\\", "*", "_", "`", "~", "[", "]":
                out.append("\\"); out.append(ch)
            case "<":
                // The parser strips HTML tag spans; escape so literal `<` text
                // survives.
                out.append("\\"); out.append(ch)
            case "#", ">", "-", "+":
                // Only block-significant at the START of a line/block; escape
                // there to avoid being re-read as a heading/quote/list marker.
                if idx == 0 { out.append("\\") }
                out.append(ch)
            default:
                out.append(ch)
            }
        }
        return out
    }
}
