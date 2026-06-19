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
    /// Single `UserDefaults` key for the per-panel override map. Pinned
    /// by test.
    public static let storageKey = "MarkdownViewer.sidebar.panelEdges"

    /// `UserDefaults` key for the GLOBAL default edge (the shoulder a
    /// panel lands on when it has no per-panel override). Pinned by test.
    /// Separate key so the two pieces of state — the default and the
    /// sparse override map — persist independently.
    public static let defaultEdgeStorageKey = "MarkdownViewer.sidebar.panelDefaultEdge"

    /// The GLOBAL default edge: where a panel without a per-panel
    /// override resolves. Ships as `.left` (the classic activity-bar
    /// column), so an empty override map + the shipping default === the
    /// v1 product state. A user / future setting can flip this so, say,
    /// every untouched panel defaults to the right inspector rail without
    /// touching the per-panel map.
    public private(set) var defaultEdge: PanelEdge

    /// Only panels that DEVIATE from `defaultEdge` carry an entry; an
    /// entry equal to `defaultEdge` is normalized away so the encoded
    /// string stays minimal + canonical and two semantically-equal
    /// assignments compare equal.
    private var overrides: [SidebarPanelKind: PanelEdge]

    public init(
        overrides: [SidebarPanelKind: PanelEdge] = [:],
        defaultEdge: PanelEdge = .default
    ) {
        self.defaultEdge = defaultEdge
        // Normalize: an entry equal to the default must not be stored.
        self.overrides = overrides.filter { $0.value != defaultEdge }
    }

    /// Resolved edge for `kind` — the global setting + per-panel
    /// override resolution: an explicit override wins, else the global
    /// `defaultEdge`. This is also where a TOGGLE BUTTON looks up which
    /// shoulder rail it belongs on (the button follows the panel).
    public func edge(_ k: SidebarPanelKind) -> PanelEdge {
        overrides[k] ?? defaultEdge
    }

    /// Assign `kind` to `edge`. Setting it to the current `defaultEdge`
    /// removes the override so the encoded form stays minimal.
    ///
    /// NOTE: this is the LOW-LEVEL setter with no legality check — it
    /// will happily pin a non-dockable panel to a non-left edge. Callers
    /// that take untrusted input (drag-drop, a redock menu) must route
    /// through `PanelPlacement.move(_:to:in:)`, which validates first.
    public mutating func setEdge(_ k: SidebarPanelKind, _ e: PanelEdge) {
        if e == defaultEdge {
            overrides.removeValue(forKey: k)
        } else {
            overrides[k] = e
        }
    }

    /// Change the global default edge, re-normalizing the override map so
    /// no stored entry equals the new default. Panels that were only on
    /// the OLD default by absence move to the NEW default automatically;
    /// panels with an explicit override are unaffected (their override
    /// still wins). Pure — used by a future "default dock side" setting.
    public mutating func setDefaultEdge(_ e: PanelEdge) {
        guard e != defaultEdge else { return }
        defaultEdge = e
        overrides = overrides.filter { $0.value != e }
    }

    /// Panels assigned to `edge`, in `order` (default render order),
    /// with non-matching panels filtered out. Order is preserved.
    ///
    /// With an empty override map + the `.left` default this returns the
    /// full `order` for `.left` and `[]` for `.right` / `.bottom` — the
    /// v1 state.
    public func panels(
        on edge: PanelEdge,
        order: [SidebarPanelKind] = SidebarPanelRegistry.defaultOrder
    ) -> [SidebarPanelKind] {
        order.filter { self.edge($0) == edge }
    }

    // MARK: persistence
    //
    // The OVERRIDE MAP and the GLOBAL DEFAULT persist independently:
    //   * `encoded()` / `decoded(_:)` cover ONLY the override map (also
    //     reused verbatim by the per-session `PanelLayoutSnapshot`, so
    //     their wire format must not change), with an optional
    //     `defaultEdge` argument so a decode can re-anchor to a known
    //     default.
    //   * `load` / `save` additionally round-trip `defaultEdge` under its
    //     own `defaultEdgeStorageKey`.

    /// Serialise the OVERRIDE MAP to a comma-joined `kind:edge` string,
    /// e.g. `"bookmarks:bottom,git:right"`. Sorted by `kind.rawValue` so
    /// the written value is stable + diff-friendly. Entries equal to
    /// `defaultEdge` never appear (they're not stored).
    public func encoded() -> String {
        overrides
            .map { "\($0.key.rawValue):\($0.value.rawValue)" }
            .sorted()
            .joined(separator: ",")
    }

    /// Inverse of `encoded()` for the override map. Tokens with an
    /// unknown kind OR an unknown edge are dropped — a renamed/removed
    /// case in a future build must not crash older settings. Malformed
    /// tokens (no `:`, extra `:`) are skipped. `defaultEdge` re-anchors
    /// the resulting assignment (default `.left`, the shipping value).
    public static func decoded(
        _ string: String, defaultEdge: PanelEdge = .default
    ) -> PanelEdgeAssignment {
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
        return PanelEdgeAssignment(overrides: map, defaultEdge: defaultEdge)
    }

    public static func load(from defaults: UserDefaults) -> PanelEdgeAssignment {
        // An unknown / absent default-edge token falls back to `.left`
        // (the shipping value) — never crashes older settings.
        let resolvedDefault = defaults.string(forKey: defaultEdgeStorageKey)
            .flatMap { PanelEdge(rawValue: $0) } ?? .default
        guard let raw = defaults.string(forKey: storageKey) else {
            return PanelEdgeAssignment(defaultEdge: resolvedDefault)
        }
        return decoded(raw, defaultEdge: resolvedDefault)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(encoded(), forKey: PanelEdgeAssignment.storageKey)
        defaults.set(defaultEdge.rawValue, forKey: PanelEdgeAssignment.defaultEdgeStorageKey)
    }
}
