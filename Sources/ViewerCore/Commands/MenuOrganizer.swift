import Foundation

/// TSK-1318 — the menus are a flat "kitchen-sink" list; group + order them.
/// This is the pure MODEL half: `organize` turns the registered commands into
/// category-grouped, deterministically-ordered menu sections that the menu bar
/// renders from — so the reorg is a data transform (host-tested) instead of a
/// scatter of ad-hoc SwiftUI/AppKit menu edits. `CommandDescriptor` already
/// carries a `CommandCategory`; this projects the flat list into the section
/// tree. The actual NSMenu/SwiftUI build from these sections is the render tail.
public enum MenuOrganizer {

    /// One menu = a category with its ordered commands.
    public struct Section: Equatable, Sendable, Identifiable {
        public let category: CommandCategory
        public let title: String
        public let commands: [CommandDescriptor]
        public var id: CommandCategory { category }
        public init(category: CommandCategory, commands: [CommandDescriptor]) {
            self.category = category
            self.title = category.title
            self.commands = commands
        }
    }

    /// Group `commands` by category (sections in `CommandCategory` declaration
    /// order) and sort within each section. Empty categories are omitted so a
    /// category with no commands never renders an empty menu.
    ///
    /// - Parameters:
    ///   - menuInvokableOnly: keep only commands that can actually fire a menu
    ///     action (a `scriptVerb`); `NSApp`-coupled no-verb entries are dropped
    ///     from the model (they stay menu-only in the render layer). Default
    ///     `false` = include everything.
    ///   - order: within-section ordering. `.byTitle` (default) is
    ///     deterministic + predictable; `.byRegistration` preserves the input
    ///     order (for when the caller pre-sorts logically, e.g. New/Open/Save).
    public static func organize(
        _ commands: [CommandDescriptor],
        menuInvokableOnly: Bool = false,
        order: SectionOrder = .byTitle
    ) -> [Section] {
        let filtered = menuInvokableOnly ? commands.filter(\.isPaletteInvokable) : commands
        var byCategory: [CommandCategory: [CommandDescriptor]] = [:]
        for cmd in filtered {
            byCategory[cmd.category, default: []].append(cmd)
        }
        return CommandCategory.allCases.compactMap { category in
            guard let cmds = byCategory[category], !cmds.isEmpty else { return nil }
            let ordered: [CommandDescriptor]
            switch order {
            case .byTitle:
                // Stable, case-insensitive title sort; id breaks ties so the
                // order is fully deterministic for equal titles.
                ordered = cmds.sorted {
                    let lt = $0.title.localizedCaseInsensitiveCompare($1.title)
                    if lt != .orderedSame { return lt == .orderedAscending }
                    return $0.id < $1.id
                }
            case .byRegistration:
                ordered = cmds
            }
            return Section(category: category, commands: ordered)
        }
    }

    public enum SectionOrder: Sendable {
        case byTitle
        case byRegistration
    }
}
