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

    /// Per-panel docked-tool-window SIZE (UX-E / #227). Mutating fires
    /// `objectWillChange` for the docked-panel containers (the right /
    /// bottom tool windows) so a resize-drag re-bodies them — same narrow
    /// channel as `edges` / `overrides`, never forwarded into
    /// `DocumentModel`. `.left` panels live in the accordion and ignore
    /// this entirely; only `.right` / `.bottom` docks consume it.
    @Published public private(set) var dockSizes: PanelDockLayout

    /// Selected tab of the TABBED bottom dock (owner rework 2026-08-09 —
    /// one panel visible at a time). The stored value is the user's last
    /// explicit choice; `BottomDockTabs.resolve` maps it onto the current
    /// visible set (fallback to first when the choice is hidden). Same
    /// narrow observation channel as `edges` / `overrides`.
    @Published public private(set) var bottomSelection: SidebarPanelKind?

    /// The SHARED height of the tabbed bottom dock's band (strip + body).
    /// One height for the whole dock — panels no longer size the band
    /// individually (the per-panel `dockSizes` bottom entries are dead
    /// for the band; `.right` widths still ride `dockSizes`).
    @Published public private(set) var bottomBandHeight: CGFloat

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var edges = PanelEdgeAssignment.load(from: defaults)
        var overrides = PanelVisibilityOverrides.load(from: defaults)
        // One-shot legacy-terminal migration (2026-08-09): a user who had
        // the old special-cased pane open keeps it open in the same dock.
        if let m = TerminalPanelMigration.pendingMigration(in: defaults) {
            edges.setEdge(.terminal, m.edge)
            if m.shown { overrides.set(.terminal, .shown) }
            edges.save(to: defaults)
            overrides.save(to: defaults)
            TerminalPanelMigration.markMigrated(in: defaults)
        }
        self.edges = edges
        self.overrides = overrides
        self.dockSizes = PanelDockLayout.load(from: defaults)
        self.bottomSelection = defaults.string(forKey: BottomDockTabs.selectionKey)
            .flatMap(SidebarPanelKind.init(rawValue:))
        if defaults.object(forKey: BottomDockTabs.bandHeightKey) != nil {
            self.bottomBandHeight = PanelDockLayout.clamp(
                CGFloat(defaults.double(forKey: BottomDockTabs.bandHeightKey)))
        } else {
            self.bottomBandHeight = PanelDockLayout.defaultBottomHeight
        }
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

    /// Fixed tool-window size for `kind` docked at `edge` (UX-E / #227).
    /// Width for a `.right` dock, height for a `.bottom` dock. Absent ⇒
    /// the per-edge default; never tiny, never content-driven.
    public func dockSize(_ kind: SidebarPanelKind, on edge: PanelEdge) -> CGFloat {
        dockSizes.size(kind, on: edge)
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
        // REVEAL (TSK-609): flipping a panel ON must also EXPAND its
        // section. Git/Claude keep their own disclosure state, so a
        // rail click used to mount only a collapsed header — visually
        // indistinguishable from "the button does nothing". Sections
        // read this key via @AppStorage, so an already-mounted collapsed
        // section expands live and a fresh mount starts expanded.
        if !visible {
            defaults.set(true, forKey: k.expandedStateKey)
        }
    }

    /// Set an explicit override directly (e.g. a future context-menu
    /// "Auto / Show / Hide" affordance). Persists synchronously.
    public func setOverride(_ k: SidebarPanelKind, _ state: PanelOverride) {
        overrides.set(k, state)
        overrides.save(to: defaults)
    }

    /// TSK-1116 — replace the WHOLE visibility snapshot at once (a focus mode's
    /// `FocusWorkMode.panelOverrides()`), persisting synchronously. Used by
    /// View ▸ Focus Mode to pin the sidebar to an activity's panel set.
    /// Equality-guarded so re-applying the same mode doesn't republish.
    public func applyOverrides(_ next: PanelVisibilityOverrides) {
        guard next != overrides else { return }
        overrides = next
        overrides.save(to: defaults)
    }

    /// Reassign a panel to a different rail. Rejects illegal placements
    /// (a non-dockable panel — e.g. FILES — on a non-`.left` edge) via
    /// the pure `PanelPlacement` validator, so a programmatic caller can't
    /// pin an undockable panel to a dock it has no form for. Persists
    /// synchronously. Equality-guarded: an illegal/no-op move doesn't
    /// republish.
    public func setEdge(_ k: SidebarPanelKind, _ edge: PanelEdge) {
        let next = PanelPlacement.move(k, to: edge, in: edges)
        guard next != edges else { return }
        edges = next
        edges.save(to: defaults)
    }

    /// Change the GLOBAL default dock edge (the shoulder a panel without a
    /// per-panel override lands on). Pure re-anchor in the value type;
    /// persisted synchronously. Equality-guarded.
    public func setDefaultEdge(_ edge: PanelEdge) {
        guard edge != edges.defaultEdge else { return }
        var next = edges
        next.setDefaultEdge(edge)
        edges = next
        edges.save(to: defaults)
    }

    /// Drag-to-redock entry point (UX-E / #227). Move a tool window's
    /// panel to a different dock and, when the user lands it on a
    /// brand-new edge it has never been sized on, force it `.shown` so it
    /// actually appears in the destination dock (a panel dragged out of
    /// the accordion onto an empty right rail must materialize there, not
    /// silently vanish behind an `.auto`-resolves-hidden heuristic).
    ///
    /// Equality-guarded: a no-op redrop (dropped back on the same edge)
    /// doesn't republish. Persists synchronously.
    ///
    /// `forceShown` defaults true (the drag-drop contract); pass false for
    /// a programmatic reassignment that should leave the visibility
    /// override untouched.
    public func move(_ k: SidebarPanelKind, to edge: PanelEdge, forceShown: Bool = true) {
        // VALIDATE via the pure placement engine: an illegal placement
        // (a non-dockable panel onto a non-`.left` dock) is rejected here,
        // not silently stored and dropped at render time. A no-op redrop
        // (already on `edge`) likewise produces an equal assignment.
        let next = PanelPlacement.move(k, to: edge, in: edges)
        guard next != edges else { return }
        edges = next
        edges.save(to: defaults)
        // Moving OFF the left accordion onto a free-standing dock: ensure
        // the panel is actually shown there. We only flip an `.auto` (the
        // never-touched default) to `.shown`; an explicit user `.hidden`
        // is left alone so a redock doesn't override an intentional hide.
        if forceShown, edge != .left, overrides.state(k) == .auto {
            overrides.set(k, .shown)
            overrides.save(to: defaults)
        }
    }

    /// Select a tab of the tabbed bottom dock. Persists synchronously;
    /// equality-guarded so re-clicking the active tab doesn't republish.
    public func selectBottomPanel(_ k: SidebarPanelKind) {
        guard k != bottomSelection else { return }
        bottomSelection = k
        defaults.set(k.rawValue, forKey: BottomDockTabs.selectionKey)
    }

    /// Resize the tabbed bottom dock's shared band (gutter drag). Clamped
    /// to the dock floor + corruption ceiling (the live window edge is the
    /// practical bound, enforced by the container). Equality-guarded;
    /// persists synchronously (user-paced).
    public func setBottomBandHeight(_ h: CGFloat) {
        let clamped = PanelDockLayout.clamp(h)
        guard clamped != bottomBandHeight else { return }
        bottomBandHeight = clamped
        defaults.set(Double(clamped), forKey: BottomDockTabs.bandHeightKey)
    }

    /// Resize a docked tool window (UX-E / #227). Sets the panel's fixed
    /// size on `edge` (width for `.right`, height for `.bottom`), clamped
    /// to the floor + the corruption ceiling (NO UX maximum — the live
    /// window edge is the only practical bound). Equality-guarded so a
    /// no-op drag frame doesn't republish. Persists synchronously
    /// (user-paced; no debounce needed).
    public func setDockSize(_ size: CGFloat, for k: SidebarPanelKind, on edge: PanelEdge) {
        let clamped = PanelDockLayout.clamp(size)
        guard clamped != dockSizes.size(k, on: edge) else { return }
        dockSizes.setSize(clamped, for: k, on: edge)
        dockSizes.save(to: defaults)
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
    /// overrides (fires `objectWillChange` for the directly-observing
    /// rails + sidebar) WITHOUT writing to `UserDefaults` — per-session
    /// state must not clobber the global default. Idempotent and
    /// equality-guarded: applying the layout it already holds is a no-op
    /// (no spurious republish).
    ///
    /// DOCK PLACEMENT IS APP-GLOBAL (owner 2026-08-09: "I thought I moved
    /// outline to the right shoulder, but it's back on the left" — session
    /// activation replayed a stale per-session edge map over the user's
    /// move). Sessions apply ONLY the visibility overrides (which panels
    /// are open — the per-session working set); WHERE a panel docks is a
    /// global preference that survives session switches and relaunches.
    /// `snapshot()` still CAPTURES the edges for downgrade compatibility;
    /// they are simply not applied. (Every `SessionKind.defaultPanelLayout`
    /// ships empty edges, so kind seeds are unaffected.)
    public func apply(_ snapshot: PanelLayoutSnapshot) {
        let newOverrides = PanelVisibilityOverrides.decoded(snapshot.overrides)
        if newOverrides != overrides { overrides = newOverrides }
    }
}
