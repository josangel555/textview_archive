import Foundation

/// User-curated "favorite" terminal commands (TSK-769 terminal-UX slice) — a
/// small, persisted, user-editable list the in-app terminal can offer for one-
/// click insertion (e.g. `npm run build`, `git status`). Shell history (up-arrow)
/// is the PTY shell's job; this is the cross-session, app-level shortlist.
///
/// Persisted as a plain JSON array at `<App Support>/MarkdownViewer/
/// terminal-favorites.json`, so the user can hand-edit it (an "Edit Favorites…"
/// menu item opens the file). The STORE is the host-testable core — the menu
/// that lists favorites and the actual PTY insertion are the VM render tail.
public final class TerminalFavoritesStore {

    public struct Favorite: Codable, Equatable, Identifiable, Sendable {
        /// Optional display label; falls back to the command text when empty.
        public let title: String
        /// The command text inserted at the terminal prompt (no trailing newline —
        /// the user reviews + presses Return).
        public let command: String
        public var id: String { command }
        public init(title: String = "", command: String) {
            self.title = title
            self.command = command
        }
        /// What the menu shows: the title if set, else the command itself.
        public var displayLabel: String { title.isEmpty ? command : title }
    }

    /// Conservative caps — this is a hand-curated shortlist, not a log.
    public static let maxFavorites = 100
    public static let maxStoreFileBytes = 256 * 1024

    public let storeURL: URL
    private var items: [Favorite] = []

    public static func defaultURL() -> URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = support.appendingPathComponent("MarkdownViewer")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("terminal-favorites.json")
    }

    public init(storeURL: URL = TerminalFavoritesStore.defaultURL()) {
        self.storeURL = storeURL
        load()
    }

    /// All favorites in stored order.
    public var all: [Favorite] { items }

    /// Add a command (deduped by command text — re-adding moves it to the front
    /// so the most-recently-favorited is first). No-op on a blank command.
    @discardableResult
    public func add(command: String, title: String = "") -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        items.removeAll { $0.command == trimmed }
        items.insert(Favorite(title: title, command: trimmed), at: 0)
        if items.count > Self.maxFavorites { items = Array(items.prefix(Self.maxFavorites)) }
        save()
        return true
    }

    /// Remove the favorite whose command matches (no-op if absent).
    @discardableResult
    public func remove(command: String) -> Bool {
        let before = items.count
        items.removeAll { $0.command == command }
        guard items.count != before else { return false }
        save()
        return true
    }

    public func removeAll() {
        guard !items.isEmpty else { return }
        items = []
        save()
    }

    /// Re-read from disk — used after the user hand-edits the JSON file.
    public func reload() { load() }

    // MARK: - Persistence

    private func load() {
        guard let decoded = JSONFileStore.read(
            [Favorite].self, from: storeURL, maxSize: Self.maxStoreFileBytes
        ) else { return }
        // Drop blanks + dedupe defensively (the file is hand-editable).
        var seen = Set<String>()
        items = decoded.compactMap { fav in
            let c = fav.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !c.isEmpty, seen.insert(c).inserted else { return nil }
            return Favorite(title: fav.title, command: c)
        }
        if items.count > Self.maxFavorites { items = Array(items.prefix(Self.maxFavorites)) }
    }

    private func save() { JSONFileStore.enqueueWrite(items, to: storeURL) }

    /// Block until pending writes land (persistence-roundtrip tests).
    public func flush() { JSONFileStore.flushSync() }
}
