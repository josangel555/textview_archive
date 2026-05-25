import Foundation

/// Translate `LSPFoldingRange` records into the CM6-flavored
/// `CMFoldRange` value the bridge ships to JS for the LSP-driven
/// `foldService.of(...)` extension.
///
/// LSP fold ranges are line-based (0-indexed `startLine`/`endLine` with
/// optional column offsets). CM6's fold service expects doc-offset
/// `{from, to}` in UTF-16 units. The mapping rule we follow matches the
/// VSCode default:
///
/// - `from` = end of `startLine` (the fold opens after the brace /
///   colon / heading line); when `startCharacter` is present, use that
///   column on `startLine` instead.
/// - `to` = end of `endLine` (inclusive end-of-line); when
///   `endCharacter` is present, use that column on `endLine`.
///
/// Ranges where `to <= from` after clamping are dropped (CM6 would
/// otherwise treat them as no-op folds). Pure-logic — no I/O, no UI.
public enum CMFoldRangeMapping {

    public static func cmFoldRanges(
        from lspFolds: [LSPFoldingRange],
        documentText: String,
        encoding: LSPPositionEncoding = .utf16
    ) -> [CMFoldRange] {
        guard !lspFolds.isEmpty else { return [] }
        let converter = LSPPositionConverter(text: documentText, encoding: encoding)
        let docUTF16Count = documentText.utf16.count
        var out: [CMFoldRange] = []
        out.reserveCapacity(lspFolds.count)

        // Pre-compute line bounds via a single scan; cheaper than
        // re-walking the doc for every range.
        for r in lspFolds {
            // Resolve start position. Without `startCharacter`, fold
            // opens at the end of `startLine` (CM6 + VSCode convention
            // — folds the body, leaves the header visible).
            let startCol = r.startCharacter ?? Int.max
            let endCol = r.endCharacter ?? Int.max
            let startIdx = converter.stringIndex(for:
                LSPPosition(line: r.startLine, character: startCol))
            let endIdx = converter.stringIndex(for:
                LSPPosition(line: r.endLine, character: endCol))
            let from = documentText.utf16.distance(
                from: documentText.startIndex, to: startIdx)
            let to = documentText.utf16.distance(
                from: documentText.startIndex, to: endIdx)
            let clampedFrom = max(0, min(docUTF16Count, from))
            let clampedTo = max(clampedFrom, min(docUTF16Count, to))
            // Drop zero / negative spans. CM6's fold service would
            // accept them but render no widget.
            if clampedTo <= clampedFrom { continue }
            out.append(CMFoldRange(
                from: clampedFrom, to: clampedTo, kind: r.kind))
        }
        return out
    }
}
