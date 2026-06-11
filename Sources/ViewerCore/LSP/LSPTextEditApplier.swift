import Foundation

/// Apply `textDocument/formatting` results to a document string
/// (TSK-627). Pure logic — text + edits in, text out; no I/O, no UI.
///
/// LSP contract (3.17 §15.13): every edit's `range` refers to the
/// ORIGINAL document, and edits in one response never overlap. We
/// therefore resolve all ranges against the original text up front,
/// then apply in REVERSE document order so earlier offsets remain
/// valid while later spans are being replaced. Hostile/buggy server
/// input (out-of-range positions, end < start, overlap) is clamped or
/// tolerated rather than trapped — a bad formatter response must never
/// crash the app, worst case it mis-formats and ⌘Z is the recovery.
public enum LSPTextEditApplier {

    /// Apply `edits` to `text`. Empty edits returns `text` unchanged.
    public static func apply(
        _ edits: [LSPTextEdit],
        to text: String,
        encoding: LSPPositionEncoding
    ) -> String {
        guard !edits.isEmpty else { return text }
        let converter = LSPPositionConverter(text: text, encoding: encoding)
        let docCount = text.utf16.count

        struct Resolved {
            let from: Int
            let to: Int
            let newText: [UInt16]
        }
        var resolved: [Resolved] = edits.map { e in
            let rawFrom = converter.utf16Offset(for: e.range.start)
            let rawTo = converter.utf16Offset(for: e.range.end)
            let from = max(0, min(docCount, rawFrom))
            let to = max(from, min(docCount, rawTo)) // end < start → empty range
            return Resolved(from: from, to: to, newText: Array(e.newText.utf16))
        }
        // Reverse document order; ties (same start: pure insertions at one
        // point) keep their response order by using a stable sort key.
        resolved.sort { a, b in
            if a.from != b.from { return a.from > b.from }
            return a.to > b.to
        }

        var units = Array(text.utf16)
        var lastAppliedStart = Int.max
        for e in resolved {
            // Spec says no overlap; if a buggy server sends one anyway,
            // drop the offender instead of corrupting offsets.
            guard e.to <= lastAppliedStart else { continue }
            units.replaceSubrange(e.from..<e.to, with: e.newText)
            lastAppliedStart = e.from
        }
        return String(decoding: units, as: UTF16.self)
    }
}
