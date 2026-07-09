import Foundation

/// TSK-1572 — the PURE section model for the new-tab launchpad: split the flat
/// recents into "Recent Files" + "Recent Folders" and add a "Bookmarks" section,
/// each deduped by path and capped. Host-testable; the view maps these to rows
/// (and the arrow-nav flattens them via `LaunchpadSelection`).
public enum LaunchpadSections {

    public struct Item: Equatable, Sendable {
        public let title: String       // display name (usually the last path component)
        public let path: String        // absolute path (the dedup + open key)
        public let isDirectory: Bool
        public init(title: String, path: String, isDirectory: Bool) {
            self.title = title; self.path = path; self.isDirectory = isDirectory
        }
    }

    public struct Section: Equatable, Sendable {
        public let title: String
        public let items: [Item]
        public init(title: String, items: [Item]) { self.title = title; self.items = items }
    }

    /// Build the launchpad sections. `recents` is the flat recents list (files +
    /// folders, newest-first); it's split by `isDirectory`. Each section is
    /// deduped by path (first occurrence wins → newest-first order preserved) and
    /// capped at `limit`; empty sections are omitted.
    public static func build(
        recents: [Item], bookmarks: [Item], limit: Int = 8
    ) -> [Section] {
        var sections: [Section] = []
        func add(_ title: String, _ items: [Item]) {
            let capped = Array(dedupedByPath(items).prefix(limit))
            if !capped.isEmpty { sections.append(Section(title: title, items: capped)) }
        }
        add("Recent Files", recents.filter { !$0.isDirectory })
        add("Recent Folders", recents.filter { $0.isDirectory })
        add("Bookmarks", bookmarks)
        return sections
    }

    /// The flat row list (all sections' items in order) — what `LaunchpadSelection`
    /// indexes into and what Enter/click activates.
    public static func flatItems(_ sections: [Section]) -> [Item] {
        sections.flatMap(\.items)
    }

    private static func dedupedByPath(_ items: [Item]) -> [Item] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.path).inserted }
    }
}
