import Foundation

/// Translate `LSPDiagnostic` records into the CM6-flavored
/// `CMDiagnostic` value the bridge ships to JS.
///
/// CM6's document positions are UTF-16 code-unit offsets (JS strings
/// are UTF-16 internally; `EditorState.doc.length` counts UTF-16
/// units). LSP positions are `(line, character)` in the negotiated
/// position encoding (utf-16 by spec default; sourcekit-lsp also
/// advertises utf-8). We reuse `LSPPositionConverter` to translate
/// to a Swift `String.Index`, then walk the UTF-16 view to get the
/// JS-compatible offset.
///
/// Pure-logic: takes the doc text + LSP encoding + diagnostics in,
/// returns the bridge payload. No I/O, no UI imports. Tested in
/// `CMDiagnosticMappingTests`.
public enum CMDiagnosticMapping {

    /// Convert a batch of LSP diagnostics against `documentText` into
    /// CM6 bridge diagnostics. Out-of-range ranges are clamped to the
    /// document; zero-length ranges are widened to one code unit so the
    /// squiggle has somewhere to draw.
    public static func cmDiagnostics(
        from lspDiagnostics: [LSPDiagnostic],
        documentText: String,
        encoding: LSPPositionEncoding
    ) -> [CMDiagnostic] {
        guard !lspDiagnostics.isEmpty else { return [] }
        let converter = LSPPositionConverter(text: documentText, encoding: encoding)
        return cmDiagnostics(
            from: lspDiagnostics, documentText: documentText, converter: converter)
    }

    /// PERF-02 overload: translate using a caller-supplied (possibly
    /// cached) converter, avoiding the O(documentLength) rebuild on
    /// every diagnostics push against an unchanged buffer. `converter`
    /// MUST have been built from `documentText` — the UTF-16 clamp uses
    /// `documentText.utf16.count` for bounds. See
    /// `LSPPositionConverterCache`.
    public static func cmDiagnostics(
        from lspDiagnostics: [LSPDiagnostic],
        documentText: String,
        converter: LSPPositionConverter
    ) -> [CMDiagnostic] {
        guard !lspDiagnostics.isEmpty else { return [] }
        let docUTF16Count = documentText.utf16.count
        var out: [CMDiagnostic] = []
        out.reserveCapacity(lspDiagnostics.count)
        for d in lspDiagnostics {
            // PERF-02: `converter.utf16Offset(for:)` is O(intra-line);
            // the prior `utf16.distance(from: startIndex, to: idx)`
            // rescanned the whole document prefix per range (O(N · D)).
            let from = converter.utf16Offset(for: d.range.start)
            let to = converter.utf16Offset(for: d.range.end)
            let clampedFrom = max(0, min(docUTF16Count, from))
            var clampedTo = max(clampedFrom, min(docUTF16Count, to))
            if clampedTo == clampedFrom {
                // Widen to one code unit so the squiggle is visible.
                // CM6's lint will otherwise drop the diagnostic.
                clampedTo = min(docUTF16Count, clampedFrom + 1)
            }
            // If the doc is empty, clampedTo == clampedFrom == 0 — emit
            // a (0,0) record; CM-side will skip it. Cheaper than a guard
            // here, and keeps the shape predictable.
            out.append(CMDiagnostic(
                from: clampedFrom,
                to: clampedTo,
                severity: cmSeverity(d.severity),
                message: d.message,
                source: d.source,
                code: d.code
            ))
        }
        return out
    }

    public static func cmSeverity(_ s: LSPDiagnostic.Severity) -> CMDiagnostic.Severity {
        switch s {
        case .error:        return .error
        case .warning:      return .warning
        case .information:  return .info
        case .hint:         return .hint
        }
    }
}
