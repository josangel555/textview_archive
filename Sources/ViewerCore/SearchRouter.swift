import Foundation

/// TSK-677 — Unified search routing.
///
/// The app historically grew THREE separate search entry points with three
/// separate mental models:
///   - the command palette's *bare* mode = fuzzy over **recents / bookmarks**
///   - the command palette's `>` mode    = fuzzy over **registered commands**
///   - the `SearchAnywhereSection` / `CrossSearchPanel` = **global cross-file
///     text grep** under the sidebar root (a wholly separate widget)
///
/// plus the palette's already-shipped in-file affordances (`@` symbol, `:`
/// line, `#` in-file text — see `GotoQueryParser`).
///
/// `SearchRouter` is the single pure classifier that maps ONE query string to
/// the search **source** it targets and the action Return fires. It is a thin,
/// total wrapper over `GotoQueryParser` (no I/O, fully host-testable) that:
///   1. adds the missing `?` operator → **global cross-file text search**, the
///      source that previously had no palette route at all; and
///   2. names each route as a `SearchSource` so the view layer dispatches by a
///      single switch instead of re-deriving "which widget handles this" inline.
///
/// This is the routing MODEL slice. The palette consumes `route(_:)` and
/// dispatches each `SearchSource` to the matching existing engine — the
/// renderers (file list, command list, cross-search overlay) are unchanged.
public enum SearchRouter {

    /// Which search SOURCE a unified query targets. One case per distinct
    /// engine/result-set so the palette dispatches by a single switch.
    public enum SearchSource: String, Equatable, Sendable, CaseIterable {
        /// Bare query → fuzzy over recent files + bookmarks (the palette's
        /// default file finder).
        case recents
        /// `>` → fuzzy over the registered command catalog.
        case commands
        /// `?` → global cross-file text grep under the search root
        /// (the `SearchAnywhereSection` / `CrossSearchPanel` engine). This is
        /// the route that the palette previously lacked entirely.
        case globalText
        /// `#` → text search within the ACTIVE file only.
        case inFileText
        /// `@` → jump to a symbol / Markdown heading in the active file.
        case symbol
        /// `:` → go to a line[:column] in the active file.
        case line
    }

    /// What the palette should DO when the user presses Return on a routed
    /// query. Extends `PaletteSubmitAction`'s vocabulary with the global-search
    /// hand-off so the view's submit dispatch is host-tested end to end.
    public enum SubmitAction: Equatable, Sendable {
        /// Open the selected file result (bare query).
        case openFile
        /// Run the selected registered command (`>`).
        case runCommand
        /// Jump to a 1-based line in the active editor (`:42`).
        case goToLine(Int)
        /// Hand `term` to the global cross-file search overlay (`?term`). The
        /// payload is the trimmed term so the view doesn't re-trim.
        case runGlobalSearch(String)
        /// Jump within the active file (`#`/`@`) — the view owns the selected
        /// row, so the action carries no payload (mirrors today's behaviour).
        case jumpInFile
        /// Nothing actionable yet (e.g. a bare `:`/`?` with no term) — dismiss.
        case none
    }

    /// A fully routed query: the target `source`, the residual `term` after the
    /// operator, the `submit` action, and — when the route is `.globalText` —
    /// the trimmed term ready to feed the cross-file engine.
    public struct Route: Equatable, Sendable {
        public let source: SearchSource
        /// The query text AFTER the operator (untrimmed, as `GotoQuery.term`).
        public let term: String
        public let submit: SubmitAction
        /// The underlying parsed goto-query, exposed so existing call sites that
        /// already speak `GotoQuery` (line/column, etc.) need not re-parse.
        public let goto: GotoQuery

        public init(source: SearchSource, term: String, submit: SubmitAction, goto: GotoQuery) {
            self.source = source
            self.term = term
            self.submit = submit
            self.goto = goto
        }
    }

    /// The operator that routes to the global cross-file text search. `?` is
    /// unused by `GotoQueryParser`, mnemonic for "search everywhere", and does
    /// not collide with the existing `>`/`@`/`#`/`:` table.
    public static let globalSearchOperator: Character = "?"

    /// Classify `raw` into its routed search source + submit action. Total
    /// function, no I/O. `?` is handled here (the only operator the legacy
    /// `GotoQueryParser` doesn't own); everything else delegates to the parser
    /// so the two stay in lock-step.
    public static func route(_ raw: String) -> Route {
        // The global-search operator must be the FIRST character (a leading
        // space disables it → plain file search), matching the parser's rule so
        // `?` behaves exactly like the other operators.
        if raw.first == globalSearchOperator {
            let term = String(raw.dropFirst())
            let trimmed = term.trimmingCharacters(in: .whitespaces)
            // A `GotoQuery` for downstream consumers; global text isn't a
            // GotoMode, so represent it as `.text` (in-file's sibling) with the
            // residual term — callers that care use `Route.source`, not this.
            let g = GotoQuery(mode: .text, term: term)
            return Route(
                source: .globalText,
                term: term,
                submit: trimmed.isEmpty ? .none : .runGlobalSearch(trimmed),
                goto: g)
        }

        let g = GotoQueryParser.parse(raw)
        let source = mapSource(g.mode)
        return Route(
            source: source,
            term: g.term,
            submit: mapSubmit(g, source: source),
            goto: g)
    }

    /// Map a legacy `GotoMode` to its `SearchSource`. Pure 1:1 table.
    private static func mapSource(_ mode: GotoMode) -> SearchSource {
        switch mode {
        case .files:   return .recents
        case .command: return .commands
        case .symbol:  return .symbol
        case .line:    return .line
        case .text:    return .inFileText
        }
    }

    /// Translate the parser's submit action into the router's richer vocabulary.
    /// In-file routes (`#`/`@`) resolve to `.jumpInFile` (the view selects the
    /// row); everything else carries through `GotoQuery.submitAction`.
    private static func mapSubmit(_ g: GotoQuery, source: SearchSource) -> SubmitAction {
        switch source {
        case .inFileText, .symbol:
            return .jumpInFile
        case .globalText:
            // Unreachable via this path (`?` is handled in `route`), kept total.
            let trimmed = g.term.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? .none : .runGlobalSearch(trimmed)
        case .recents, .commands, .line:
            switch g.submitAction {
            case .openFile:        return .openFile
            case .runCommand:      return .runCommand
            case .goToLine(let n): return .goToLine(n)
            case .none:            return .none
            }
        }
    }
}
