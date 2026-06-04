import Foundation

/// Which shoulder rail a sidebar panel is docked to.
///
/// v1 ships with every panel on `.left` (the classic activity-bar
/// column); `.right` / `.bottom` exist so the (deferred) panel-moving
/// feature is a one-struct change with no persistence migration.
///
/// `.top` is intentionally omitted — the product direction specifies
/// three rails (left / right / bottom). Adding an unused case would
/// invite dead code paths in the rail views.
public enum PanelEdge: String, CaseIterable, Sendable, Codable {
    case left
    case right
    case bottom

    /// Every panel starts on `.left` in v1.
    public static let `default`: PanelEdge = .left

    /// Human-readable dock name for the drag-to-redock menu / snap-zone
    /// affordances (UX-E / #227).
    public var displayName: String {
        switch self {
        case .left:   return "Left"
        case .right:  return "Right"
        case .bottom: return "Bottom"
        }
    }

    /// SF Symbol cue for the dock in the redock menu — matches the
    /// macOS "sidebar"/"inspector"/"bottom pane" iconography.
    public var systemImage: String {
        switch self {
        case .left:   return "sidebar.left"
        case .right:  return "sidebar.right"
        case .bottom: return "rectangle.bottomthird.inset.filled"
        }
    }
}

/// Sparse per-panel edge assignment.
///
/// Mirrors `SidebarPanelVisibility`'s persistence idiom exactly: one
/// comma-joined `UserDefaults` key, `kind:edge` tokens, unknown tokens
/// dropped on decode, sorted-stable encode. An *absent* panel resolves
/// to `PanelEdge.default` (`.left`) — so an empty map is precisely the
/// v1 product state (all buttons on the left rail, right/bottom empty).
///
/// Pure-logic, host-testable. No SwiftUI, no UserDefaults coupling
/// beyond the load/save round-trip helpers (which accept any handle so
/// tests can pass a throwaway suite).
public struct PanelEdgeAssignment: Sendable, Equatable {
    /// Single `UserDefaults` key. Pinned by test.
    public static let storageKey = "MarkdownViewer.sidebar.panelEdges"

    /// Only panels that deviate from `.left` carry an entry. Setting a
    /// panel back to `.left` removes its override (keeps the encoded
    /// string minimal + canonical).
    private var overrides: [SidebarPanelKind: PanelEdge]

    public init(overrides: [SidebarPanelKind: PanelEdge] = [:]) {
        // Normalize: a `.left` entry is the default and must not be
        // stored — otherwise two semantically-equal assignments could
        // compare unequal and encode differently.
        self.overrides = overrides.filter { $0.value != .default }
    }

    /// Resolved edge for `kind`. Absent ⇒ `.default` (`.left`).
    public func edge(_ k: SidebarPanelKind) -> PanelEdge {
        overrides[k] ?? .default
    }

    /// Assign `kind` to `edge`. Setting `.left` (the default) removes
    /// the override so the encoded form stays minimal.
    public mutating func setEdge(_ k: SidebarPanelKind, _ e: PanelEdge) {
        if e == .default {
            overrides.removeValue(forKey: k)
        } else {
            overrides[k] = e
        }
    }

    /// Panels assigned to `edge`, in `order` (default render order),
    /// with non-matching panels filtered out. Order is preserved.
    ///
    /// With an empty override map this returns the full `order` for
    /// `.left` and `[]` for `.right` / `.bottom` — the v1 state.
    public func panels(
        on edge: PanelEdge,
        order: [SidebarPanelKind] = SidebarPanelRegistry.defaultOrder
    ) -> [SidebarPanelKind] {
        order.filter { self.edge($0) == edge }
    }

    // MARK: persistence

    /// Serialise to a comma-joined `kind:edge` string, e.g.
    /// `"bookmarks:bottom,git:right"`. Sorted by `kind.rawValue` so the
    /// written value is stable + diff-friendly. `.left` entries never
    /// appear (they're not stored).
    public func encoded() -> String {
        overrides
            .map { "\($0.key.rawValue):\($0.value.rawValue)" }
            .sorted()
            .joined(separator: ",")
    }

    /// Inverse of `encoded()`. Tokens with an unknown kind OR an
    /// unknown edge are dropped — a renamed/removed case in a future
    /// build must not crash older settings. Malformed tokens (no `:`,
    /// extra `:`) are skipped.
    public static func decoded(_ string: String) -> PanelEdgeAssignment {
        var map: [SidebarPanelKind: PanelEdge] = [:]
        for token in string.split(separator: ",", omittingEmptySubsequences: true) {
            let parts = token.split(separator: ":", omittingEmptySubsequences: true)
            guard parts.count == 2,
                  let kind = SidebarPanelKind(rawValue: String(parts[0])),
                  let edge = PanelEdge(rawValue: String(parts[1])) else {
                continue
            }
            map[kind] = edge
        }
        return PanelEdgeAssignment(overrides: map)
    }

    public static func load(from defaults: UserDefaults) -> PanelEdgeAssignment {
        guard let raw = defaults.string(forKey: storageKey) else {
            return PanelEdgeAssignment()
        }
        return decoded(raw)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(encoded(), forKey: PanelEdgeAssignment.storageKey)
    }
}
