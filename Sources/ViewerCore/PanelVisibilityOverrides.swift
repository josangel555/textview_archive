import Foundation

/// Sparse per-panel explicit-visibility override map.
///
/// One comma-joined `UserDefaults` key holding `kind:state` tokens
/// (e.g. `"bookmarks:hidden,git:shown"`). An *absent* panel resolves to
/// `.auto`, so a fresh install (empty map) defers entirely to the
/// data-presence heuristic — today's behavior, byte-for-byte.
///
/// This SUPERSEDES `SidebarPanelVisibility` for the rails feature, but
/// does NOT replace or migrate it: the legacy `hiddenPanels` key + its
/// pinned format are left untouched (still pin-tested). v1 ships with
/// overrides empty, so the legacy set is simply unused going forward.
///
/// Mirrors the `SidebarPanelVisibility` persistence idiom: sorted-stable
/// encode, unknown-token drop on decode, load/save round-trip on any
/// `UserDefaults` handle. Pure-logic, host-testable.
public struct PanelVisibilityOverrides: Sendable, Equatable {
    /// Single `UserDefaults` key. Pinned by test.
    public static let storageKey = "MarkdownViewer.sidebar.panelOverrides"

    /// Only panels the user has explicitly touched carry an entry.
    /// Setting `.auto` removes the entry (keeps the encoded string
    /// minimal + canonical — two equal maps encode identically).
    private var map: [SidebarPanelKind: PanelOverride]

    public init(map: [SidebarPanelKind: PanelOverride] = [:]) {
        // Normalize: `.auto` is the default and must not be stored.
        self.map = map.filter { $0.value != .auto }
    }

    /// Resolved override for `kind`. Absent ⇒ `.auto`.
    public func state(_ k: SidebarPanelKind) -> PanelOverride {
        map[k] ?? .auto
    }

    /// Set the explicit override. `.auto` removes the entry.
    public mutating func set(_ k: SidebarPanelKind, _ s: PanelOverride) {
        if s == .auto {
            map.removeValue(forKey: k)
        } else {
            map[k] = s
        }
    }

    /// Rail-button toggle: flip what the user currently sees. From a
    /// visible panel → `.hidden`; from a hidden panel (whether
    /// `.auto`-hidden because no data, or already `.hidden`) → `.shown`.
    /// This is the intuitive 2-way "toggle the thing in front of me"
    /// contract; `.auto` is never written back via the rail.
    public mutating func toggle(_ k: SidebarPanelKind, currentlyVisible: Bool) {
        set(k, currentlyVisible ? .hidden : .shown)
    }

    // MARK: persistence

    /// Serialise to a comma-joined `kind:state` string. Sorted by token
    /// so the written value is stable + diff-friendly. `.auto` entries
    /// never appear (they're not stored).
    public func encoded() -> String {
        map
            .map { "\($0.key.rawValue):\($0.value.rawValue)" }
            .sorted()
            .joined(separator: ",")
    }

    /// Inverse of `encoded()`. Tokens with an unknown kind OR an
    /// unknown state are dropped. Malformed tokens are skipped.
    public static func decoded(_ string: String) -> PanelVisibilityOverrides {
        var out: [SidebarPanelKind: PanelOverride] = [:]
        for token in string.split(separator: ",", omittingEmptySubsequences: true) {
            let parts = token.split(separator: ":", omittingEmptySubsequences: true)
            guard parts.count == 2,
                  let kind = SidebarPanelKind(rawValue: String(parts[0])),
                  let state = PanelOverride(rawValue: String(parts[1])) else {
                continue
            }
            out[kind] = state
        }
        return PanelVisibilityOverrides(map: out)
    }

    public static func load(from defaults: UserDefaults) -> PanelVisibilityOverrides {
        guard let raw = defaults.string(forKey: storageKey) else {
            return PanelVisibilityOverrides()
        }
        return decoded(raw)
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(encoded(), forKey: PanelVisibilityOverrides.storageKey)
    }
}
