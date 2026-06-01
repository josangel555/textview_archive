import Foundation
import Combine
import ViewerCore

/// Observable runtime owner of the shoulder-rail layout: per-panel edge
/// assignment + per-panel explicit-visibility override.
///
/// OBSERVATION DISCIPLINE (load-bearing — see PERF #1 + the
/// `setCurrentViewMode` republish fix on this branch): this store is
/// observed DIRECTLY by the views that consume it (`ShoulderRailView`,
/// `SidebarView`, `ContentView`) via `@ObservedObject`. It does NOT
/// forward its `objectWillChange` into `DocumentModel.objectWillChange`.
///
///   - Forwarding into `DocumentModel` would republish the whole
///     content tree on every rail toggle (PERF #1 republish storm).
///   - Putting this state on a coordinator that no view observes is the
///     `setCurrentViewMode` dead-toggle bug (the view never re-bodies).
///
/// Direct observation is the textbook narrow pattern — the same shape
/// as `FindCoordinator` / `SidebarModel`. The
/// `PanelLayoutRepublishInvariantTests` suite pins this invariant.
///
/// Persistence rides the existing comma-joined `UserDefaults` value-type
/// idiom (`PanelEdgeAssignment` / `PanelVisibilityOverrides`), NOT
/// `PreferencesStore` — each value type owns its own key + round-trip
/// tests. Toggles write through synchronously (user-paced clicks, no
/// debounce needed).
@MainActor
public final class PanelLayoutStore: ObservableObject {
    /// Per-panel edge assignment. Mutating this fires
    /// `objectWillChange` for the rails (button placement) — independent
    /// of visibility.
    @Published public private(set) var edges: PanelEdgeAssignment

    /// Per-panel explicit-visibility override. Mutating this fires
    /// `objectWillChange` for the rails (button filled-state) + the
    /// sidebar (accordion presence).
    @Published public private(set) var overrides: PanelVisibilityOverrides

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.edges = PanelEdgeAssignment.load(from: defaults)
        self.overrides = PanelVisibilityOverrides.load(from: defaults)
    }

    // MARK: reads

    public func edge(of k: SidebarPanelKind) -> PanelEdge {
        edges.edge(k)
    }

    public func override(for k: SidebarPanelKind) -> PanelOverride {
        overrides.state(k)
    }

    /// Resolved on-screen visibility = explicit override applied on top
    /// of data-presence. `dataPresent` is supplied by the caller (the
    /// rail / sidebar compute it from `SidebarDataPresence`) because the
    /// store deliberately knows nothing about roots / repos / LSP.
    public func isVisible(_ k: SidebarPanelKind, dataPresent: Bool) -> Bool {
        PanelVisibilityResolver.isVisible(
            k, override: overrides.state(k), dataPresent: dataPresent
        )
    }

    /// All panels assigned to `edge`, in render order. Drives the rail
    /// BUTTONS — independent of visibility (a rail shows a button for
    /// every panel docked to it, filled or not).
    public func railPanels(on edge: PanelEdge) -> [SidebarPanelKind] {
        edges.panels(on: edge)
    }

    // MARK: writes (write-through persistence)

    /// Rail-button click. Flips the panel's resolved visibility:
    /// currently-visible → `.hidden`, currently-hidden → `.shown`.
    /// Persists synchronously. Fires `objectWillChange` (via the
    /// `@Published overrides` mutation) for the directly-observing
    /// rails + sidebar.
    public func toggle(_ k: SidebarPanelKind, dataPresent: Bool) {
        let visible = isVisible(k, dataPresent: dataPresent)
        overrides.toggle(k, currentlyVisible: visible)
        overrides.save(to: defaults)
    }

    /// Set an explicit override directly (e.g. a future context-menu
    /// "Auto / Show / Hide" affordance). Persists synchronously.
    public func setOverride(_ k: SidebarPanelKind, _ state: PanelOverride) {
        overrides.set(k, state)
        overrides.save(to: defaults)
    }

    /// Reassign a panel to a different rail (deferred panel-moving;
    /// exposed now so the value type stays the single mutation point).
    /// Persists synchronously.
    public func setEdge(_ k: SidebarPanelKind, _ edge: PanelEdge) {
        edges.setEdge(k, edge)
        edges.save(to: defaults)
    }

    // MARK: - Per-session snapshot (#184)
    //
    // The shoulder-rail layout moved from the GLOBAL `UserDefaults` to a
    // per-session blob. `snapshot()` captures the live in-memory state;
    // `apply(_:)` installs a session's persisted state on mount/hydrate.
    //
    // OBSERVATION + PERSISTENCE DISCIPLINE: `apply` mutates the
    // `@Published` edges/overrides (so the directly-observing rails /
    // sidebar re-body — the same narrow path a user toggle takes) but
    // does NOT write through to `UserDefaults`. Otherwise activating a
    // session would clobber the global default with that one session's
    // layout, and the GLOBAL key would no longer mean "the app-wide
    // fallback". The session's authoritative copy lives in its
    // `SessionSnapshot`; the store's UserDefaults keys remain the
    // app-wide default used for a brand-new (unseeded) session.

    /// Capture the live layout as a downgrade-safe per-session snapshot.
    public func snapshot() -> PanelLayoutSnapshot {
        PanelLayoutSnapshot(edges: edges.encoded(), overrides: overrides.encoded())
    }

    /// Install a session's persisted layout. Mutates the `@Published`
    /// edges/overrides (fires `objectWillChange` for the directly-
    /// observing rails + sidebar) WITHOUT writing to `UserDefaults` —
    /// per-session layout must not clobber the global default. Idempotent
    /// and equality-guarded: applying the layout it already holds is a
    /// no-op (no spurious republish).
    public func apply(_ snapshot: PanelLayoutSnapshot) {
        let newEdges = PanelEdgeAssignment.decoded(snapshot.edges)
        let newOverrides = PanelVisibilityOverrides.decoded(snapshot.overrides)
        if newEdges != edges { edges = newEdges }
        if newOverrides != overrides { overrides = newOverrides }
    }
}
