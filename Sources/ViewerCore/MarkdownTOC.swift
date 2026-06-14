import Foundation

/// Generates a Markdown table-of-contents from a heading outline and inserts it
/// idempotently (TSK-675 robust-editor / a top markdown-editor feature). A pure
/// CONSUMER of `MarkdownOutline.headings` — it does not touch the (Rust-ported)
/// markdown→HTML engine or the outline parser, so it's migration-safe and
/// survives any future outline port (just swap the heading source).
///
/// The TOC is wrapped in `<!-- toc -->` / `<!-- /toc -->` HTML comments so a
/// re-run REPLACES the block in place (idempotent) rather than stacking copies.
public enum MarkdownTOC {

    public static let openMarker = "<!-- toc -->"
    public static let closeMarker = "<!-- /toc -->"

    /// A GitHub-style anchor slug: lowercase; drop everything that isn't a
    /// letter, number, space, or hyphen; spaces → hyphens (runs are NOT
    /// collapsed, matching GitHub). Letters include Unicode (é, λ stay).
    public static func slug(_ title: String) -> String {
        var out = ""
        for ch in title.lowercased() {
            if ch.isLetter || ch.isNumber { out.append(ch) }
            else if ch == " " || ch == "-" { out.append("-") }
            // every other char (punctuation, etc.) is dropped
        }
        return out
    }

    /// A nested Markdown bullet list of `[title](#slug)` links, indented two
    /// spaces per heading level relative to the shallowest heading present.
    /// Duplicate slugs get GitHub's `-1`, `-2`, … suffixes. Empty for no headings.
    public static func generate(from headings: [MarkdownHeading]) -> String {
        guard !headings.isEmpty else { return "" }
        let minLevel = headings.map(\.level).min() ?? 1
        var seen: [String: Int] = [:]
        var lines: [String] = []
        for h in headings {
            let base = slug(h.title)
            let anchor: String
            if let n = seen[base] {
                seen[base] = n + 1
                anchor = "\(base)-\(n)"
            } else {
                seen[base] = 1
                anchor = base
            }
            let indent = String(repeating: "  ", count: max(0, h.level - minLevel))
            lines.append("\(indent)- [\(escapeLinkText(h.title))](#\(anchor))")
        }
        return lines.joined(separator: "\n")
    }

    /// Insert or refresh the TOC for `text` given its `headings`. If the marker
    /// pair already exists, the content between them is replaced (idempotent
    /// regenerate). Otherwise a new marked block is inserted at the top — after a
    /// leading YAML front-matter block, if present (so the front-matter stays
    /// first). A document with no headings AND no existing markers is returned
    /// unchanged (nothing to table).
    public static func insert(into text: String, headings: [MarkdownHeading]) -> String {
        let toc = generate(from: headings)
        let block = "\(openMarker)\n\(toc)\n\(closeMarker)"

        if let open = text.range(of: openMarker),
           let close = text.range(of: closeMarker, range: open.upperBound..<text.endIndex) {
            return String(text[text.startIndex..<open.lowerBound]) + block
                + String(text[close.upperBound..<text.endIndex])
        }

        guard !headings.isEmpty else { return text }   // nothing to insert

        let at = insertionIndex(in: text)
        let head = String(text[text.startIndex..<at])
        let tail = String(text[at..<text.endIndex])
        let sep = tail.isEmpty ? "\n" : "\n\n"
        return head + block + sep + tail
    }

    // MARK: - helpers

    /// `[` / `]` would break the link text — escape them; other chars are fine.
    private static func escapeLinkText(_ s: String) -> String {
        s.replacingOccurrences(of: "[", with: "\\[")
         .replacingOccurrences(of: "]", with: "\\]")
    }

    /// The index to insert a fresh TOC at: just after a leading YAML front-matter
    /// block (`---` … `---`/`...`), else the very start.
    private static func insertionIndex(in text: String) -> String.Index {
        guard let firstNL = text.firstIndex(of: "\n") else { return text.startIndex }
        let firstLine = text[text.startIndex..<firstNL].trimmingCharacters(in: .whitespacesAndNewlines)
        guard firstLine == "---" else { return text.startIndex }

        var lineStart = text.index(after: firstNL)
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[lineStart..<lineEnd].trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "---" || line == "..." {
                return lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
            }
            if lineEnd == text.endIndex { break }
            lineStart = text.index(after: lineEnd)
        }
        return text.startIndex   // unterminated front-matter → top
    }
}
