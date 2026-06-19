import Foundation

/// The §2.x "contribute a menu item" extension point (TSK-754). The
/// AppKit menu builder (`AppDelegate.buildMenu`) reads `menuModel()` at
/// menu-construction time and materialises a "Plugins" top-level menu
/// from it. The registry is `@MainActor` for the same reason the
/// sidebar registry is — the host consumes it on the main actor and we
/// keep the plugin host single-actor (no cross-actor hop while building
/// the menu).
///
/// The registry stays UI-framework-agnostic: it holds plain value
/// `Entry`s plus an `invoke` closure, and produces an ordered tree
/// (`MenuModel`) of top-level items and named submenus. Turning that
/// tree into `NSMenuItem`s is the AppKit layer's job. Keeping the tree
/// build here (not in `main.swift`) means it is host-testable without an
/// `NSMenu`.
@MainActor
public final class MenuContributionRegistry {

    /// One contributed menu item. `invoke` is the action bound to the
    /// menu item; it runs on the main actor when the user selects the
    /// item. For a Tier A (noop) contribution `invoke` is `nil` and the
    /// AppKit layer renders the item disabled.
    public struct Entry {
        public let pluginID: String
        public let itemID: String
        public let title: String
        /// Optional submenu name. `nil` ⇒ the item sits at the top level
        /// of the Plugins menu; non-nil ⇒ it nests under a submenu of
        /// that name.
        public let submenu: String?
        public let order: Int
        /// Selected-the-item handler. `nil` for Tier A (noop) items — the
        /// menu item is then rendered disabled (present but inert).
        public let invoke: (@MainActor () -> Void)?

        public init(
            pluginID: String,
            itemID: String,
            title: String,
            submenu: String?,
            order: Int,
            invoke: (@MainActor () -> Void)?
        ) {
            self.pluginID = pluginID
            self.itemID = itemID
            self.title = title
            self.submenu = submenu
            self.order = order
            self.invoke = invoke
        }
    }

    /// A flat, ordered list item the AppKit layer renders directly.
    /// `enabled` is false for Tier A (noop) contributions.
    public struct Item: Sendable, Equatable {
        public let pluginID: String
        public let itemID: String
        public let title: String
        public let enabled: Bool
        public init(pluginID: String, itemID: String, title: String, enabled: Bool) {
            self.pluginID = pluginID
            self.itemID = itemID
            self.title = title
            self.enabled = enabled
        }
    }

    /// One submenu node — a named submenu plus its ordered items.
    public struct Submenu: Sendable, Equatable {
        public let title: String
        public let items: [Item]
        public init(title: String, items: [Item]) {
            self.title = title
            self.items = items
        }
    }

    /// The ordered tree the AppKit layer materialises. Top-level items
    /// (no submenu) come first, then named submenus. Both are ordered by
    /// the contributions' `order` ascending, ties broken by plugin id +
    /// item id (stable, matching the sidebar's tie-break convention).
    public struct MenuModel: Sendable, Equatable {
        public let topLevel: [Item]
        public let submenus: [Submenu]
        public init(topLevel: [Item], submenus: [Submenu]) {
            self.topLevel = topLevel
            self.submenus = submenus
        }
        /// Whether there is anything to show — the AppKit layer skips
        /// adding the Plugins top-level menu entirely when this is true.
        public var isEmpty: Bool { topLevel.isEmpty && submenus.isEmpty }
    }

    private var entries: [Entry] = []

    public init() {}

    public func register(_ entry: Entry) {
        entries.append(entry)
    }

    public func dropAll(forPlugin id: String) {
        entries.removeAll { $0.pluginID == id }
    }

    /// The currently-registered entries contributed by one plugin. Used
    /// by `PluginRegistry.setEnabled` to stash a bundled plugin's items
    /// before dropping them (matching the sidebar's dormant-entry path).
    public func entries(forPlugin id: String) -> [Entry] {
        entries.filter { $0.pluginID == id }
    }

    /// All entries, in render order. Exposed for tests / introspection.
    public var all: [Entry] {
        entries.sorted(by: Self.entryOrder)
    }

    /// Build the ordered top-level/submenu tree the AppKit layer renders.
    /// Pure function of the registered entries — host-testable.
    public func menuModel() -> MenuModel {
        let sorted = entries.sorted(by: Self.entryOrder)

        var topLevel: [Item] = []
        // Preserve first-seen submenu order (by the sorted entry order),
        // then accumulate each submenu's items in that same order.
        var submenuOrder: [String] = []
        var submenuItems: [String: [Item]] = [:]

        for e in sorted {
            let item = Item(
                pluginID: e.pluginID,
                itemID: e.itemID,
                title: e.title,
                enabled: e.invoke != nil
            )
            if let sub = e.submenu, !sub.isEmpty {
                if submenuItems[sub] == nil {
                    submenuItems[sub] = []
                    submenuOrder.append(sub)
                }
                submenuItems[sub]?.append(item)
            } else {
                topLevel.append(item)
            }
        }

        let submenus = submenuOrder.map { Submenu(title: $0, items: submenuItems[$0] ?? []) }
        return MenuModel(topLevel: topLevel, submenus: submenus)
    }

    /// Stable ordering: declared `order` ascending; ties broken by
    /// plugin id then item id. Matches the sidebar registry's contract
    /// ("order is a hint; ties broken deterministically").
    private static func entryOrder(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.order != rhs.order { return lhs.order < rhs.order }
        if lhs.pluginID != rhs.pluginID { return lhs.pluginID < rhs.pluginID }
        return lhs.itemID < rhs.itemID
    }
}
