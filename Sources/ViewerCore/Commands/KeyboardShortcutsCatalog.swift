import Foundation

/// A presentation-ready, grouped list of every BOUND keyboard shortcut, derived
/// from the `CommandRegistry` (the single source of truth — built-in defaults
/// folded with the user's `keybinding.json` overrides). Drives the Keyboard
/// Shortcuts help page (TSK-678).
///
/// Pure value type — no AppKit, no `@MainActor` — so the grouping, the glyph
/// rendering, and the search filter are all host-testable. Commands with no
/// binding (`defaultShortcut == nil`) are omitted: this is a *shortcuts* list.
public struct KeyboardShortcutsCatalog: Sendable, Equatable {

    /// One bound command: its title and the shortcut in macOS-glyph form.
    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: String       // the stable command id (e.g. "file.save")
        public let title: String
        public let glyph: String    // e.g. "⇧⌘R"
        /// Lowercased haystack for the search filter (title + both shortcut
        /// renderings) so a user can find by name OR by keystroke.
        public let searchKey: String

        public init(id: String, title: String, glyph: String, searchKey: String) {
            self.id = id
            self.title = title
            self.glyph = glyph
            self.searchKey = searchKey
        }
    }

    /// One category group, in `CommandCategory` declaration order.
    public struct Section: Sendable, Equatable, Identifiable {
        public var id: String { category.rawValue }
        public let category: CommandCategory
        public var title: String { category.title }
        public let entries: [Entry]

        public init(category: CommandCategory, entries: [Entry]) {
            self.category = category
            self.entries = entries
        }
    }

    public let sections: [Section]

    /// Build from a registry. `includeDebug` defaults to `false` — the Debug
    /// category's commands only exist when the diagnostic gate is on, so they're
    /// off the user-facing list by default. Within a category, entries keep the
    /// registry's declaration order (which mirrors the menu order).
    public init(registry: CommandRegistry, includeDebug: Bool = false) {
        var byCategory: [CommandCategory: [Entry]] = [:]
        for cmd in registry.commands {
            guard let shortcut = cmd.defaultShortcut else { continue }
            if !includeDebug, cmd.category == .debug { continue }
            let glyph = shortcut.glyphString
            let entry = Entry(
                id: cmd.id,
                title: cmd.title,
                glyph: glyph,
                searchKey: "\(cmd.title) \(glyph) \(shortcut.displayString)".lowercased())
            byCategory[cmd.category, default: []].append(entry)
        }
        self.sections = CommandCategory.allCases.compactMap { category in
            guard let entries = byCategory[category], !entries.isEmpty else { return nil }
            return Section(category: category, entries: entries)
        }
    }

    /// Direct section construction (used by `filtered`).
    public init(sections: [Section]) {
        self.sections = sections
    }

    /// Total number of bound shortcuts across all sections.
    public var totalCount: Int {
        sections.reduce(0) { $0 + $1.entries.count }
    }

    /// Case-insensitive filter over each entry's title + shortcut. An empty /
    /// whitespace query returns the catalog unchanged; sections left with no
    /// matching entries are dropped.
    public func filtered(_ query: String) -> KeyboardShortcutsCatalog {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return self }
        let kept = sections.compactMap { section -> Section? in
            let entries = section.entries.filter { $0.searchKey.contains(needle) }
            return entries.isEmpty ? nil : Section(category: section.category, entries: entries)
        }
        return KeyboardShortcutsCatalog(sections: kept)
    }
}
