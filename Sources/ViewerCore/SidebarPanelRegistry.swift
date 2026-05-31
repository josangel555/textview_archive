import Foundation

/// Ordered set of sidebar panels + persisted visibility.
///
/// Today the accordion `SidebarView` reads `defaultOrder` and renders
/// each panel that's `isVisible(_:)`. Tomorrow's activity-bar UI will
/// read the same two surfaces to render an icon column + pick which
/// single panel is on-screen — no duplicated truth.
///
/// Pure-logic, host-testable. Visibility persistence is parameterised
/// on a `UserDefaults` so the tests can use a throwaway suite.
public enum SidebarPanelRegistry {
    /// Canonical render order, top → bottom.
    ///
    /// `files` leads. Previously FILES sat at the bottom of the
    /// sidebar; the new ordering matches the convention users expect
    /// from VSCode / Xcode / IntelliJ (file tree on top), and means
    /// the panel users open most often is the closest to the sidebar
    /// header.
    public static let defaultOrder: [SidebarPanelKind] = [
        .files,
        .bookmarks,
        .searchAnywhere,
        .git,
        .claudeTimeline,
        .lspOutline,
        .lspNavigation,
        .lspProblems,
        .recentlyOpened,
        .pluginSections,
    ]

    /// Sanity check: every enum case appears in `defaultOrder`. Pinned
    /// with a test so a new panel can't be added to the enum but
    /// forgotten in the registry.
    public static var coversAllCases: Bool {
        let ordered = Set(defaultOrder)
        return ordered == Set(SidebarPanelKind.allCases)
    }
}

/// Persisted per-panel visibility flag. Default = visible. Encoded as a
/// single comma-joined string under one `UserDefaults` key so adding a
/// new panel doesn't trigger a defaults migration — unknown cases on
/// read are ignored, missing cases default to visible.
public struct SidebarPanelVisibility: Sendable, Equatable {
    /// The single `@AppStorage` key. Pinned by test.
    public static let storageKey = "MarkdownViewer.sidebar.hiddenPanels"

    /// Set of panels the user has explicitly hidden. Anything not in
    /// this set is visible (so a fresh install — empty set — shows
    /// every panel, which is what we want).
    public private(set) var hidden: Set<SidebarPanelKind>

    public init(hidden: Set<SidebarPanelKind> = []) {
        self.hidden = hidden
    }

    public func isVisible(_ kind: SidebarPanelKind) -> Bool {
        !hidden.contains(kind)
    }

    public mutating func setVisible(_ kind: SidebarPanelKind, _ visible: Bool) {
        if visible { hidden.remove(kind) } else { hidden.insert(kind) }
    }

    public mutating func toggle(_ kind: SidebarPanelKind) {
        if hidden.contains(kind) { hidden.remove(kind) }
        else { hidden.insert(kind) }
    }

    // MARK: persistence

    /// Serialise to a comma-joined raw-value string for storage in
    /// `UserDefaults`. Sorted so the written value is stable (and
    /// diff-friendly when users export their defaults).
    public func encoded() -> String {
        hidden.map(\.rawValue).sorted().joined(separator: ",")
    }

    /// Inverse of `encoded()`. Unknown / empty tokens are dropped —
    /// a renamed-or-removed case in a future build shouldn't crash
    /// older settings.
    public static func decoded(_ string: String) -> SidebarPanelVisibility {
        let parts = string
            .split(separator: ",", omittingEmptySubsequences: true)
            .map(String.init)
        let kinds = parts.compactMap { SidebarPanelKind(rawValue: $0) }
        return SidebarPanelVisibility(hidden: Set(kinds))
    }

    /// Round-trip helper used by both runtime callers and tests.
    public static func load(from defaults: UserDefaults) -> SidebarPanelVisibility {
        guard let raw = defaults.string(forKey: storageKey) else {
            return SidebarPanelVisibility()
        }
        return decoded(raw)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(encoded(), forKey: SidebarPanelVisibility.storageKey)
    }
}
