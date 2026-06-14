import Foundation

/// Ranks a markdown document's headings against a palette `@` query (TSK-727
/// slice 4) so the palette can jump to a heading by name. Pure — the heading
/// source (`MarkdownOutline.headings`) and the fuzzy matcher are both
/// host-tested; this composes them. The palette `@`-mode hint / jump render is
/// the view tail.
public enum SymbolJump {

    /// Rank `headings` for the `@` operator: an empty/blank query returns every
    /// heading in document order; otherwise fuzzy-rank by title (best first),
    /// dropping non-matches. Routed through the shared fuzzy adapter so it
    /// matches the palette's command/file ranking behaviour.
    public static func rank(headings: [MarkdownHeading], query: String) -> [MarkdownHeading] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return headings }
        return RustFuzzyAdapter.filterWithMatches(headings, query: q) { $0.title }
            .map { $0.item }
    }
}
