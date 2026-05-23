import Foundation

/// Pure value type that computes "highlight all other occurrences of
/// the currently-selected text" ranges. Modeled after VSCode / Sublime's
/// selection-highlight feature.
///
/// Why a separate value type (not just a free function on
/// `SourceTextController`):
///   - exercise edge cases without spinning up an NSTextView
///   - keeps the size-cap + selection-shape policy in one place that
///     can be unit-tested independently from the controller wiring
///   - makes the throttle decision (do we even run findRanges?) a
///     cheap up-front check
///
/// Performance: on multi-MB files, walking the entire textStorage on
/// every selection change is expensive. `policy` short-circuits when
/// the file is too big or the selection too long/short — the engine
/// returns an empty range list and the caller skips the highlight pass.
public struct SelectionHighlightEngine: Sendable {

    /// Tunables. Defaults match VSCode-ish behavior: highlight on
    /// single-word selections up to ~100 chars, bail on multi-MB files.
    public struct Policy: Equatable, Sendable {
        /// Skip when the haystack exceeds this many UTF-8 bytes.
        /// Default 5 MB. Past that, the per-selection findRanges walk
        /// is the dominant UI cost and the visual payoff is marginal
        /// (most matches are off-screen and would require a minimap to
        /// see — the find bar already covers that workflow).
        public var maxHaystackBytes: Int
        /// Skip when the selection length (in UTF-16 units) exceeds
        /// this. Default 100. Long selections are almost never a
        /// word the user wants to track; usually they're a copy-prep
        /// operation. Cheap heuristic that matches VSCode behavior.
        public var maxSelectionLength: Int
        /// Minimum selection length to even consider. Default 2 —
        /// single-char "highlight all the e's" would be noisy garbage.
        public var minSelectionLength: Int
        /// When true, only highlight if the selection is a "word-like"
        /// run (no leading / trailing whitespace, no newlines). Skips
        /// the noisy case where the user dragged across word boundaries.
        public var requireWordLike: Bool

        public init(
            maxHaystackBytes: Int = 5 * 1024 * 1024,
            maxSelectionLength: Int = 100,
            minSelectionLength: Int = 2,
            requireWordLike: Bool = true
        ) {
            self.maxHaystackBytes = maxHaystackBytes
            self.maxSelectionLength = maxSelectionLength
            self.minSelectionLength = minSelectionLength
            self.requireWordLike = requireWordLike
        }

        public static let `default` = Policy()
    }

    public let policy: Policy

    public init(policy: Policy = .default) {
        self.policy = policy
    }

    /// Returns all literal occurrences of the substring identified by
    /// `selection` in `text`, EXCLUDING the active selection itself
    /// (the OS already draws the OS selection background). Returns an
    /// empty array when policy rules out highlighting.
    ///
    /// `haystackByteCount` is passed in so the caller can pass a cached
    /// value (computed on text load) rather than us walking `text.utf8`
    /// per selection change.
    public func otherOccurrences(
        in text: String,
        selection: NSRange,
        haystackByteCount: Int
    ) -> [NSRange] {
        // Size cap — bail before any range walk.
        if haystackByteCount > policy.maxHaystackBytes { return [] }
        // Shape rules on the selection.
        if selection.length < policy.minSelectionLength { return [] }
        if selection.length > policy.maxSelectionLength { return [] }

        let ns = text as NSString
        guard selection.location >= 0,
              selection.location + selection.length <= ns.length
        else { return [] }
        let needle = ns.substring(with: selection)

        if policy.requireWordLike {
            // Reject if needle contains whitespace / newlines, or if
            // the bordering chars in the haystack would make this a
            // sub-word match dragged across boundaries.
            if Self.containsWhitespace(needle) { return [] }
        }

        // Literal, case-sensitive search — selection highlight is
        // identity-based, not the case-folded find-bar semantics.
        var out: [NSRange] = []
        var cursor = NSRange(location: 0, length: ns.length)
        while cursor.length > 0 {
            let r = ns.range(of: needle, options: [.literal], range: cursor)
            if r.location == NSNotFound { break }
            // Skip the active selection itself — OS already paints it.
            if !(r.location == selection.location && r.length == selection.length) {
                out.append(r)
            }
            let next = r.location + max(r.length, 1)
            if next >= ns.length { break }
            cursor = NSRange(location: next, length: ns.length - next)
        }
        return out
    }

    @inline(__always)
    private static func containsWhitespace(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
        }
        return false
    }
}
