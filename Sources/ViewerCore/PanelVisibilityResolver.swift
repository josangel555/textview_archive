import Foundation

/// Per-panel explicit-visibility intent, layered on top of the
/// data-presence heuristic.
///
/// THREE states rather than a boolean so a rail button can do all
/// three jobs the product needs:
///   - `.auto`   — defer to the data-presence heuristic (today's exact
///                 behavior). The default for every panel on a fresh
///                 install, so v1 visibility === data-presence,
///                 byte-for-byte unchanged at upgrade time.
///   - `.shown`  — user forced the panel on even when it has no data
///                 (e.g. open the Git panel in a non-repo folder to see
///                 the "not a repo" placeholder). A two-state boolean
///                 can't express this — it would be a dead button.
///   - `.hidden` — user forced the panel off even when data is present.
///
/// `.auto` is write-once-out: it's only ever the INITIAL state. The
/// rail toggle is "flip what I currently see", so once the user touches
/// a panel it becomes explicit `.shown` / `.hidden` and stays there.
/// This deliberately avoids snapshotting the heuristic into stored
/// state on first toggle (the "opened a non-repo folder once, now Git
/// never auto-appears" freeze bug).
public enum PanelOverride: String, Sendable, CaseIterable, Codable {
    case auto
    case shown
    case hidden
}

/// Pure truth table mapping (override, data-presence) → on-screen
/// visibility. No state, no SwiftUI — host-testable in isolation.
public enum PanelVisibilityResolver {
    public static func isVisible(
        _ kind: SidebarPanelKind,
        override: PanelOverride,
        dataPresent: Bool
    ) -> Bool {
        switch override {
        case .auto:   return dataPresent   // heuristic stays LIVE
        case .shown:  return true          // user forced on
        case .hidden: return false         // user forced off
        }
    }
}
