import Foundation
import ViewerKit

/// TSK-962 — parity harness for the two highlight paths.
///
/// Reduces both paths to a single comparable shape — the ordered
/// `(range, TokenKind)` token sequence each WOULD apply — so a divergence in
/// the model layer fails the host gate (pixel parity stays the VM tail). It
/// works at the SCOPE-MAP level because the two paths tokenize with different
/// engines:
///
/// - The Source path's token sequence is the actual `[HighlightRun]` the
///   TreeSitter engine emits (`scopeSequence(for:language:)`).
/// - The CM6 path tokenizes in JS (Lezer) — not host-runnable — so we can't
///   produce its sequence here. What we CAN pin host-side is REACHABILITY: any
///   `TokenKind` the Source path emits must have a Lezer-tag mapping on the CM6
///   side, otherwise the editor can NEVER paint that kind and the two diverge
///   for that scope. `unreachableKinds(...)` returns the gap; an empty set is
///   parity. (The end-to-end *pixel* equality is `EditorThemeParityTests` on
///   the VM.)
///
/// Plus the canonical-map self-consistency checks (`coverage`) that guard the
/// single-source-of-truth invariant: every `TokenKind` declared once, every
/// path mapped.
public enum HighlightParityHarness {

    /// One token as both paths would classify it, reduced to the comparable
    /// `(range, scope)` form the epic specifies.
    public struct ScopeToken: Sendable, Equatable {
        public let range: NSRange
        public let kind: TokenKind
        public init(range: NSRange, kind: TokenKind) {
            self.range = range; self.kind = kind
        }
    }

    /// The Source path's ordered token-scope sequence for `text` in
    /// `language`: exactly the runs `TreeSitterEngine` produces (post
    /// paint-over), surfaced as `ScopeToken`s sorted by start offset. This is
    /// the canonical "what the View tab WOULD apply" sequence.
    public static func sourceScopeSequence(
        for text: String, language: HighlightLanguage
    ) -> [ScopeToken] {
        TreeSitterEngine.shared.tokenize(text, language: language)
            .map { ScopeToken(range: $0.range, kind: $0.kind) }
            .sorted { $0.range.location < $1.range.location }
    }

    /// The set of `TokenKind`s the Source path emits over `text` that the CM6
    /// path has NO Lezer-tag mapping for — i.e. scopes the editor can never
    /// paint to the same color, a real View↔Edit divergence. Empty ⇒ every
    /// scope the source produced is reachable on the editor side.
    public static func unreachableKinds(
        for text: String, language: HighlightLanguage
    ) -> Set<TokenKind> {
        let emitted = Set(sourceScopeSequence(for: text, language: language)
            .map(\.kind))
        return emitted.filter { kind in
            (HighlightScopeMap.lezerTagsByKind[kind] ?? []).isEmpty
        }
    }

    /// Self-consistency of the canonical `HighlightScopeMap`. A non-empty
    /// report is a parity defect in the table itself.
    public struct Coverage: Sendable, Equatable {
        /// TokenKinds with no `Entry` at all (Source path cannot resolve them).
        public let kindsMissingEntry: Set<TokenKind>
        /// TokenKinds whose entry declares no TreeSitter captures (Source path
        /// can never emit them — dead palette key).
        public let kindsMissingCaptures: Set<TokenKind>
        /// TokenKinds whose entry declares no Lezer tags (CM6 path can never
        /// paint them — the editor-only blind spot this slice closes).
        public let kindsMissingLezerTags: Set<TokenKind>
        /// TokenKinds declared by more than one `Entry` (ambiguous mapping).
        public let duplicateKinds: Set<TokenKind>

        public var isParity: Bool {
            kindsMissingEntry.isEmpty && kindsMissingCaptures.isEmpty
                && kindsMissingLezerTags.isEmpty && duplicateKinds.isEmpty
        }
    }

    public static func coverage() -> Coverage {
        let entries = HighlightScopeMap.entries
        var seen: [TokenKind: Int] = [:]
        for e in entries { seen[e.kind, default: 0] += 1 }

        let declared = Set(entries.map(\.kind))
        let all = Set(TokenKind.allCases)

        let missingEntry = all.subtracting(declared)
        let duplicates = Set(seen.filter { $0.value > 1 }.keys)
        let missingCaptures = Set(entries.filter { $0.captures.isEmpty }
            .map(\.kind))
        let missingLezer = Set(entries.filter { $0.lezerTags.isEmpty }
            .map(\.kind))

        return Coverage(
            kindsMissingEntry: missingEntry,
            kindsMissingCaptures: missingCaptures,
            kindsMissingLezerTags: missingLezer,
            duplicateKinds: duplicates)
    }
}
