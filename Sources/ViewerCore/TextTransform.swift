// TextEdit-parity "Format ▸ Transformations" — Make Upper Case / Make Lower
// Case / Capitalize (TSK-351, one host foundation slice of TextEdit feature
// parity). macOS TextEdit exposes these three case transforms on the active
// selection; this is the pure, host-testable engine behind the same commands
// for our CM6 editor surface.
//
// Design constraints (mirrors `CMEditApplier`):
//
// - Selection offsets are **UTF-16 code units**, matching CM6's
//   `EditorState.doc` indexing (Swift `String` is grapheme-based, so we step
//   through `text.utf16`).
// - The engine is a pure reducer: it takes the buffer + a selection range +
//   a transform kind and returns a single `CMEdit` to apply over the bridge
//   (`replaceRange` / `applyEdits`), or `nil` for a no-op (empty/identity
//   transform). No I/O, no AppKit, no WebKit — testable from
//   `ViewerCoreTests` on host.
// - TextEdit semantics: when nothing is selected (`from == to`), the
//   transform applies to the **whole document** (the common "fix the casing
//   of this file" intent), matching how the Edit-menu transforms behave with
//   an empty selection in practice. With a non-empty selection only that
//   span is transformed.
// - Producing an edit (rather than mutating in place) keeps the change
//   undoable through CM6's own history and preserves the selection mapping —
//   the same reason `setSelection`'s doc-comment cites `replaceSelection`.

import Foundation

public enum TextTransform {

    /// The three TextEdit "Transformations" submenu commands.
    public enum Kind: String, CaseIterable, Sendable, Equatable {
        /// "Make Upper Case" — every cased character to uppercase.
        case uppercase
        /// "Make Lower Case" — every cased character to lowercase.
        case lowercase
        /// "Capitalize" — title-case: first letter of each word upper, rest
        /// lower (Foundation's locale-aware `.capitalized`, matching
        /// TextEdit's word-boundary behavior).
        case capitalize
    }

    /// Compute the edit that applies `kind` to the selection `[from, to)` of
    /// `text` (offsets are UTF-16 code units, CM6 convention).
    ///
    /// - When `from == to` (no selection) the whole document is transformed.
    /// - Returns `nil` if the range is out of bounds, inverted, the document
    ///   is empty, or the transform is an identity (the substring is already
    ///   in the target form) — so the caller can skip a no-op transaction and
    ///   avoid dirtying the buffer / pushing an empty undo step.
    public static func edit(
        for kind: Kind,
        in text: String,
        from rawFrom: Int,
        to rawTo: Int
    ) -> CMEdit? {
        let units = Array(text.utf16)
        let length = units.count
        if length == 0 { return nil }

        // No selection → whole document (TextEdit-style).
        let from = (rawFrom == rawTo) ? 0 : rawFrom
        let to = (rawFrom == rawTo) ? length : rawTo

        // Bounds + ordering guard. Out-of-range or inverted ranges are a
        // bug in the caller (stale selection vs. resynced doc); refuse rather
        // than corrupt the buffer.
        guard from >= 0, to <= length, from < to else { return nil }

        // Slice the selected span back out as a String. The slice is always
        // well-formed UTF-16 here (CM6 never reports a selection boundary
        // inside a surrogate pair), but decode defensively so a malformed
        // range becomes a no-op instead of an exception.
        guard let slice = decodeValidatingUTF16(Array(units[from ..< to])) else {
            return nil
        }

        let transformed = apply(kind, to: slice)

        // Identity transform → no edit (don't dirty the buffer for "make
        // upper case" on already-uppercase text).
        if transformed == slice { return nil }

        return CMEdit(from: from, to: to, insert: transformed)
    }

    /// Pure string transform for `kind` (exposed for direct unit testing and
    /// for callers that already hold the substring).
    public static func apply(_ kind: Kind, to s: String) -> String {
        switch kind {
        case .uppercase:  return s.uppercased()
        case .lowercase:  return s.lowercased()
        case .capitalize: return s.capitalized
        }
    }

    /// Decode a UTF-16 code-unit array to a `String`, returning `nil` on any
    /// ill-formed sequence (unpaired surrogate) — no U+FFFD substitution.
    /// Mirrors `CMEditApplier.decodeValidatingUTF16`; kept local so the two
    /// engines stay independently testable.
    static func decodeValidatingUTF16(_ codeUnits: [UTF16.CodeUnit]) -> String? {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(codeUnits.count)
        var parser = Unicode.UTF16.ForwardParser()
        var iter = codeUnits.makeIterator()
        loop: while true {
            switch parser.parseScalar(from: &iter) {
            case .valid(let encoded):
                scalars.append(Unicode.UTF16.decode(encoded))
            case .emptyInput:
                break loop
            case .error:
                return nil
            }
        }
        return String(scalars)
    }
}
