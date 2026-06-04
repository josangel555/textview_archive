import Foundation
import CoreGraphics

/// Persisted per-panel tool-window SIZE for docked tool windows (UX-E /
/// #227).
///
/// A docked tool window is a panel that has been moved off the classic
/// LEFT accordion onto the RIGHT or BOTTOM rail (see `PanelEdgeAssignment`)
/// and now renders as its own free-standing pane with a FIXED size the
/// user controls. The size is one scalar per panel:
///
///   * a panel docked `.right`  → a fixed WIDTH (the pane spans the band's
///     full height; width is what the user drags).
///   * a panel docked `.bottom` → a fixed HEIGHT (the pane spans the band's
///     full width; height is what the user drags).
///
/// One panel therefore needs at most one stored scalar per dock edge it
/// has ever been sized on. We persist a sparse `kind:edge:size` map under
/// a single comma-joined `UserDefaults` key — the exact same value-type
/// idiom as `PanelEdgeAssignment` / `PanelVisibilityOverrides` /
/// `TerminalPaneLayout`: sorted-stable encode, unknown-token drop on
/// decode, load/save round-trip on any handle. Pure-logic, host-testable;
/// no SwiftUI, no AppKit.
///
/// FIXED-HEIGHT (P1, brief item 1): the stored size is authoritative and
/// content-independent. A panel opens at `defaultSize(for:)` (a sensible,
/// not-tiny default), keeps that size regardless of how much content it
/// holds, and only changes when the user drags the resize handle.
///
/// NO RIGHT-EDGE LIMIT (P1, brief item 2): `clamp` enforces a MINIMUM
/// floor (so a panel can't be dragged to nothing) and a generous finite
/// hard CEILING that exists only to neutralise a corrupted / hostile
/// stored value — it is NOT a UX maximum. The hard ceiling is far larger
/// than any real window, so for all practical resizes the user hits the
/// window edge (enforced live by the view's available-space clamp), never
/// this constant. NaN falls back to the per-edge default; ±infinity
/// clamps to the bounds.
public struct PanelDockLayout: Sendable, Equatable {
    /// Single `UserDefaults` key. Pinned by test.
    public static let storageKey = "MarkdownViewer.sidebar.panelDockSizes"

    /// Minimum size on the resize axis. A docked tool window can't be
    /// dragged below this — below it the pane is unusable and the user
    /// should just close it.
    public static let minSize: CGFloat = 120

    /// Hard ceiling — a corruption / hostility guard, NOT a UX maximum
    /// (brief: "the right-side resize must have NO maximum limit"). Far
    /// larger than any real display so a legitimate resize is always
    /// bounded by the live window edge, never by this constant.
    public static let maxSize: CGFloat = 100_000

    /// Default WIDTH for a freshly right-docked tool window. Wide enough
    /// to be useful on first open (matches a comfortable secondary
    /// sidebar), not tiny.
    public static let defaultRightWidth: CGFloat = 300

    /// Default HEIGHT for a freshly bottom-docked tool window. Matches the
    /// terminal pane's default so the two bottom panes read consistently.
    public static let defaultBottomHeight: CGFloat = 240

    /// Only panels the user has explicitly sized carry an entry, keyed by
    /// `(kind, edge)`. An absent entry resolves to `defaultSize(for:)`.
    private var sizes: [Key: CGFloat]

    /// Composite key: a panel's size is stored PER edge, so moving a panel
    /// right then bottom then back to right restores its remembered right
    /// width (rather than collapsing both docks onto one scalar).
    public struct Key: Hashable, Sendable {
        public let kind: SidebarPanelKind
        public let edge: PanelEdge
        public init(_ kind: SidebarPanelKind, _ edge: PanelEdge) {
            self.kind = kind
            self.edge = edge
        }
    }

    public init(sizes: [Key: CGFloat] = [:]) {
        // Normalize on construction so a hand-edited / corrupted store
        // never yields out-of-range live values, and so two semantically
        // equal layouts compare + encode identically.
        self.sizes = sizes.mapValues { PanelDockLayout.clamp($0) }
    }

    // MARK: - Defaults

    /// The default tool-window size for a panel newly docked to `edge`.
    /// `.left` panels live in the accordion (per-panel `@AppStorage`
    /// height, not this type) so they fall back to the right-width default
    /// here only defensively; the live UI never asks for a `.left` size.
    public static func defaultSize(for edge: PanelEdge) -> CGFloat {
        switch edge {
        case .right:  return defaultRightWidth
        case .bottom: return defaultBottomHeight
        case .left:   return defaultRightWidth
        }
    }

    // MARK: - Clamp

    /// Clamp a size into `[minSize, maxSize]`. NaN → the right-width
    /// default (a safe non-tiny value); ±infinity clamps to the bounds.
    public static func clamp(_ s: CGFloat) -> CGFloat {
        guard !s.isNaN else { return defaultRightWidth }
        return min(max(s, minSize), maxSize)
    }

    // MARK: - Reads

    /// Resolved size for `kind` docked at `edge`. Absent ⇒ the per-edge
    /// default. Always returns a clamped value.
    public func size(_ kind: SidebarPanelKind, on edge: PanelEdge) -> CGFloat {
        if let stored = sizes[Key(kind, edge)] {
            return PanelDockLayout.clamp(stored)
        }
        return PanelDockLayout.defaultSize(for: edge)
    }

    // MARK: - Writes

    /// Set the fixed size for `kind` on `edge`. Clamped before store.
    public mutating func setSize(_ s: CGFloat, for kind: SidebarPanelKind, on edge: PanelEdge) {
        sizes[Key(kind, edge)] = PanelDockLayout.clamp(s)
    }

    // MARK: - Persistence
    //
    // Wire format: comma-joined `kind:edge:size` tokens, e.g.
    // `"git:right:340,lspProblems:bottom:200"`. Sorted by token so the
    // written value is stable + diff-friendly. Sizes are emitted as
    // integers (sub-point precision is meaningless for a pane width).

    public func encoded() -> String {
        sizes
            .map { "\($0.key.kind.rawValue):\($0.key.edge.rawValue):\(Int($0.value.rounded()))" }
            .sorted()
            .joined(separator: ",")
    }

    /// Inverse of `encoded()`. Tokens with an unknown kind / edge, a
    /// non-numeric size, or the wrong part count are dropped — a
    /// renamed/removed case (or a hand-mangled plist) must not crash a
    /// newer build's settings.
    public static func decoded(_ string: String) -> PanelDockLayout {
        var out: [Key: CGFloat] = [:]
        for token in string.split(separator: ",", omittingEmptySubsequences: true) {
            let parts = token.split(separator: ":", omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let kind = SidebarPanelKind(rawValue: String(parts[0])),
                  let edge = PanelEdge(rawValue: String(parts[1])),
                  let raw = Double(parts[2]) else {
                continue
            }
            out[Key(kind, edge)] = clamp(CGFloat(raw))
        }
        return PanelDockLayout(sizes: out)
    }

    public static func load(from defaults: UserDefaults) -> PanelDockLayout {
        guard let raw = defaults.string(forKey: storageKey) else {
            return PanelDockLayout()
        }
        return decoded(raw)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(encoded(), forKey: PanelDockLayout.storageKey)
    }
}
