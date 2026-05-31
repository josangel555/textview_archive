// Apply CodeMirror incremental edits to a Swift `String` mirror of the
// doc. Phase 4 (v2 protocol) ships incremental edits over the bridge
// instead of the full doc text on every debounce; this helper is the
// Swift-side reducer.
//
// Design constraints:
//
// - Edit offsets are **UTF-16 code units**, matching CM6's
//   `EditorState.doc` indexing. Swift `String` indexing is grapheme-
//   based; we step through `text.utf16` instead.
// - All edits in the batch reference offsets **before** the batch is
//   applied (the same convention CM6 uses for a multi-change
//   `Transaction` — every range is mapped through prior changes by the
//   reducer). We sort edits by `from` ascending and walk forward,
//   maintaining a running delta to translate each subsequent `from`/`to`.
// - Edits whose ranges overlap (after sorting + delta-adjust) are
//   rejected — they're a bug in the JS encoder, and silently merging
//   them would diverge the buffer from CM's.
// - Pure-logic: no I/O, no AppKit, no WebKit. Testable from
//   `ViewerCoreTests` on host.

import Foundation

public enum CMEditApplier {

    /// Apply `edits` to `base` (a UTF-16-indexed CodeMirror doc mirror).
    /// Returns the resulting string, or `nil` if any edit is out of
    /// bounds or overlaps a prior one in the batch. A non-nil result
    /// is byte-identical to what CM6 produces from the same batch.
    public static func apply(_ edits: [CMEdit], to base: String) -> String? {
        if edits.isEmpty { return base }

        // Snapshot the base as UTF-16 so we can index by the same
        // offsets CM6 uses (matches `EditorState.doc.length`).
        let baseUnits = Array(base.utf16)
        let baseLen = baseUnits.count

        // Sort ascending by `from`. CM6's `iterChangedRanges` already
        // produces sorted, non-overlapping ranges, but JS could have
        // reordered them during accumulation across the debounce
        // window. Stable sort to keep deterministic.
        let sorted = edits.sorted { a, b in
            if a.from != b.from { return a.from < b.from }
            return a.to < b.to
        }

        // Reject any edit whose pre-edit range falls outside the doc.
        // Caller's only sane response is to request a full-text resync.
        var lastTo = -1
        for e in sorted {
            if e.from < 0 || e.to > baseLen || e.from > e.to { return nil }
            if e.from < lastTo { return nil } // overlap with prior edit
            lastTo = e.to
        }

        // Build the new doc by walking `baseUnits` and inserting / skipping
        // per the sorted edits. Linear in the base length, which is the
        // same cost as `String(replacingOccurrences:)` would be for a
        // single replace — and we'd otherwise pay it N times.
        var out: [UTF16.CodeUnit] = []
        out.reserveCapacity(baseLen)
        var cursor = 0
        for e in sorted {
            if e.from > cursor {
                out.append(contentsOf: baseUnits[cursor ..< e.from])
            }
            for u in e.insert.utf16 { out.append(u) }
            cursor = e.to
        }
        if cursor < baseLen {
            out.append(contentsOf: baseUnits[cursor ..< baseLen])
        }
        // Validating decode: `String(decoding:as:)` would silently
        // substitute U+FFFD for any ill-formed UTF-16 (a lone surrogate
        // from a split-surrogate edit, or a hostile/buggy JS payload),
        // permanently corrupting the buffer. Returning `nil` instead
        // lets the caller fall back to a full-text resync (the
        // drift-recovery path) so the buffer never diverges silently.
        return Self.decodeValidatingUTF16(out)
    }

    /// Decode a UTF-16 code-unit array to a `String`, returning `nil`
    /// on any ill-formed sequence (unpaired surrogate). Unlike
    /// `String(decoding:as:)`, no U+FFFD substitution occurs.
    static func decodeValidatingUTF16(_ units: [UTF16.CodeUnit]) -> String? {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(units.count)
        var parser = Unicode.UTF16.ForwardParser()
        var iter = units.makeIterator()
        loop: while true {
            switch parser.parseScalar(from: &iter) {
            case .valid(let encoded):
                scalars.append(Unicode.UTF16.decode(encoded))
            case .emptyInput:
                break loop
            case .error:
                // Ill-formed (e.g. lone surrogate) — refuse rather than
                // substituting U+FFFD.
                return nil
            }
        }
        return String(scalars)
    }
}
