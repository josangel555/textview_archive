import Foundation

/// Deterministic normalization for the restricted RichText IR (TSK-706).
///
/// The ``RichTextParser`` already only emits allowed nodes, so on parser output
/// this pass is an idempotent *stabilizer* (drop empties, clamp, coalesce). Its
/// real job is to make `RichTextDocument` SAFE when constructed by hand or from
/// a less-restricted source: it guarantees that whatever goes in, what comes
/// out is strictly in-vocabulary and canonical, so the editor never has to
/// defend against an out-of-bound heading level, an empty block, or a stray
/// nested structure.
///
/// Rules (all deterministic):
///   - Heading `level` clamped to `1...RichBlock.maxHeadingLevel` (H4+ → H3 if
///     somehow constructed; the parser already downgrades H4+ to paragraphs).
///   - Empty blocks (a paragraph/heading/list/quote with no visible content)
///     are dropped.
///   - Inline runs are coalesced (adjacent `.text` merged) and emptied of
///     zero-content leaves; empty emphasis wrappers collapse to their content
///     or vanish.
///   - Blockquote inner paragraphs that are empty are dropped; an all-empty
///     quote vanishes.
public enum RichTextNormalizer {

    public static func normalize(_ doc: RichTextDocument) -> RichTextDocument {
        var out: [RichBlock] = []
        for block in doc.blocks {
            if let n = normalizeBlock(block) { out.append(n) }
        }
        return RichTextDocument(out)
    }

    /// Returns the normalized block, or nil if it should be dropped (empty).
    static func normalizeBlock(_ block: RichBlock) -> RichBlock? {
        switch block {
        case let .heading(level, inlines):
            let clamped = min(max(level, 1), RichBlock.maxHeadingLevel)
            let runs = normalizeInlines(inlines)
            return runs.isEmpty ? nil : .heading(level: clamped, inlines: runs)

        case let .paragraph(inlines):
            let runs = normalizeInlines(inlines)
            return runs.isEmpty ? nil : .paragraph(runs)

        case let .bulletList(items):
            let kept = items.compactMap { normalizeItem($0) }
            return kept.isEmpty ? nil : .bulletList(kept)

        case let .orderedList(start, items):
            let kept = items.compactMap { normalizeItem($0) }
            // Clamp a nonsensical start to a positive integer.
            return kept.isEmpty ? nil : .orderedList(start: max(start, 1), items: kept)

        case let .blockquote(paras):
            let kept = paras.map { normalizeInlines($0) }.filter { !$0.isEmpty }
            return kept.isEmpty ? nil : .blockquote(kept)
        case let .codeBlock(code):
            // Already in-vocabulary + opaque; drop only an empty block.
            return code.isEmpty ? nil : .codeBlock(code)
        case let .table(header, rows):
            let nh = header.map { normalizeInlines($0) }
            guard !nh.isEmpty else { return nil }
            return .table(header: nh, rows: rows.map { $0.map { normalizeInlines($0) } })
        }
    }

    private static func normalizeItem(_ item: RichListItem) -> RichListItem? {
        let runs = normalizeInlines(item.inlines)
        return runs.isEmpty ? nil : RichListItem(runs)
    }

    /// Coalesce adjacent text, collapse empty emphasis wrappers, drop empty
    /// leaves. Idempotent.
    static func normalizeInlines(_ inlines: [RichInline]) -> [RichInline] {
        var result: [RichInline] = []
        for inline in inlines {
            switch inline {
            case let .text(t):
                guard !t.isEmpty else { continue }
                if case let .text(prev)? = result.last {
                    result[result.count - 1] = .text(prev + t)
                } else {
                    result.append(.text(t))
                }

            case let .bold(children):
                let n = normalizeInlines(children)
                if !n.isEmpty { result.append(.bold(n)) }

            case let .italic(children):
                let n = normalizeInlines(children)
                if !n.isEmpty { result.append(.italic(n)) }

            case let .strike(children):
                let n = normalizeInlines(children)
                if !n.isEmpty { result.append(.strike(n)) }

            case let .code(c):
                // Code may be intentionally whitespace; only drop a truly empty
                // span.
                if !c.isEmpty { result.append(.code(c)) }

            case let .link(text, url):
                let n = normalizeInlines(text)
                let trimmedURL = url.trimmingCharacters(in: .whitespaces)
                if trimmedURL.isEmpty {
                    // A link with no destination degrades to its label text.
                    result.append(contentsOf: n)
                } else if n.isEmpty {
                    // No visible label: surface the URL as the label.
                    result.append(.link(text: [.text(trimmedURL)], url: trimmedURL))
                } else {
                    result.append(.link(text: n, url: trimmedURL))
                }
            }
        }
        return result
    }
}
