import Foundation

/// TSK-1176 — the unified search model behind the in-app terminal command
/// palette: one ranked, de-duplicated list over the user's pinned FAVORITES
/// (`TerminalFavoritesStore`) and auto-recorded HISTORY (`TerminalCommandHistory`).
///
/// Ranking (the palette renders this order top-to-bottom):
///   1. FAVORITES first — pinned, most-recently-favorited first (the store's order),
///      tagged `isFavorite` with their display title.
///   2. then HISTORY commands NOT already shown as a favorite — deduped by command
///      text, most-recent first (the history store's MRU order).
/// A command that is BOTH favorited and in history appears ONCE, as the favorite
/// (so the user sees its title + pin, not a duplicate). Case-insensitive matching
/// is delegated to each store's own `search`. A blank query returns everything
/// (favorites then history), so the palette can open to the full list.
///
/// Pure model (no IO of its own — it reads the two stores) → fully host-testable.
/// The palette VIEW that renders these results + inserts the chosen command at the
/// PTY prompt is the render/VM tail.
public enum TerminalCommandSearch {

    /// One palette row: the command to insert, its display label, and whether it
    /// came from the favorites list (for the pin badge / sectioning).
    public struct Result: Equatable, Sendable {
        public let command: String
        /// Favorite title when `isFavorite` (may be empty → falls back to command);
        /// always empty for a history-only row.
        public let title: String
        public let isFavorite: Bool

        public init(command: String, title: String, isFavorite: Bool) {
            self.command = command
            self.title = title
            self.isFavorite = isFavorite
        }

        /// What the palette shows: the favorite's title if set, else the command.
        public var displayLabel: String { title.isEmpty ? command : title }
    }

    /// Unified, de-duplicated, favorites-first results for `query`.
    public static func unified(
        query: String,
        favorites: TerminalFavoritesStore,
        history: TerminalCommandHistory
    ) -> [Result] {
        var results: [Result] = []
        var seen = Set<String>()

        for fav in favorites.search(query) where seen.insert(fav.command).inserted {
            results.append(Result(command: fav.command, title: fav.title, isFavorite: true))
        }
        for command in history.search(query) where seen.insert(command).inserted {
            results.append(Result(command: command, title: "", isFavorite: false))
        }
        return results
    }
}
