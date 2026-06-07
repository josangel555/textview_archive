import Foundation

/// Translate TreeSitter `FoldRegion` records (1-based, line-inclusive
/// syntax folds — the same folds the read-only Source view uses, #139)
/// into the CM6-flavored `CMFoldRange` (`{from, to}` in UTF-16 doc
/// offsets) the editor bridge ships to JS.
///
/// This is the syntax-fold twin of `CMFoldRangeMapping` (which maps
/// LSP `LSPFoldingRange`). It follows the IDENTICAL CM6/VSCode rule so
/// the two sources are interchangeable downstream:
///
/// - `from` = end of `startLine` content (the fold opens after the
///   brace / heading line, leaving the header visible);
/// - `to`   = end of `endLine` content (inclusive end-of-line);
/// - ranges where `to <= from` after clamping are dropped (CM6 would
///   render a no-op widget).
///
/// `FoldRegion.Kind.rawValue` is forwarded as the opaque `kind` string
/// (CM6 ignores it today; kept for parity with the LSP mapping and
/// possible future per-kind styling). Pure logic — no I/O, no UI.
///
/// NOTE (TSK-466): this mapping is the design-agnostic core of editor
/// folding. Whichever source a future wiring chooses (TreeSitter-only,
/// LSP-when-attached, or union), the line→offset conversion lives here.
public enum SyntaxFoldRangeMapping {

    /// Map syntax fold regions to CM6 doc-offset ranges against
    /// `documentText`. Builds a fresh position converter; for repeated
    /// calls over the same text, prefer the converter overload.
    public static func cmFoldRanges(
        from regions: [FoldRegion],
        documentText: String,
        encoding: LSPPositionEncoding = .utf16
    ) -> [CMFoldRange] {
        guard !regions.isEmpty else { return [] }
        let converter = LSPPositionConverter(text: documentText, encoding: encoding)
        return cmFoldRanges(from: regions, documentText: documentText, converter: converter)
    }

    /// Converter overload — pass a cached `LSPPositionConverter` built
    /// from the SAME `documentText`.
    public static func cmFoldRanges(
        from regions: [FoldRegion],
        documentText: String,
        converter: LSPPositionConverter
    ) -> [CMFoldRange] {
        guard !regions.isEmpty else { return [] }
        let docUTF16Count = documentText.utf16.count
        var out: [CMFoldRange] = []
        out.reserveCapacity(regions.count)

        for r in regions {
            // FoldRegion lines are 1-based inclusive; LSPPosition is
            // 0-based. `character: Int.max` clamps to end-of-line content
            // (mirrors CMFoldRangeMapping's "no startCharacter" rule).
            guard r.startLine >= 1, r.endLine >= r.startLine else { continue }
            let from = converter.utf16Offset(
                for: LSPPosition(line: r.startLine - 1, character: Int.max))
            let to = converter.utf16Offset(
                for: LSPPosition(line: r.endLine - 1, character: Int.max))
            let clampedFrom = max(0, min(docUTF16Count, from))
            let clampedTo = max(clampedFrom, min(docUTF16Count, to))
            if clampedTo <= clampedFrom { continue }
            out.append(CMFoldRange(from: clampedFrom, to: clampedTo, kind: r.kind.rawValue))
        }
        return out
    }
}
