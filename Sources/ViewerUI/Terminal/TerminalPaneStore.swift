import Foundation
import Combine
import ViewerCore

/// Observable owner of the bottom terminal pane: open/closed state, pane
/// height, and the lazily-spawned `TerminalModel`s (the live shells).
///
/// OBSERVATION DISCIPLINE (load-bearing — same narrow pattern as
/// `PanelLayoutStore`): observed DIRECTLY by `ContentView` + the
/// left-rail terminal toggle via `@ObservedObject`. It does NOT forward
/// `objectWillChange` into `DocumentModel.objectWillChange` — toggling the
/// terminal must not republish the whole content tree (PERF #1). The
/// live `TerminalModel` is a SEPARATE `ObservableObject` observed only by
/// the terminal view, so per-frame output bumps never reach `ContentView`.
///
/// Persistence rides `TerminalPaneLayout` (its own `UserDefaults` keys),
/// not `PreferencesStore`. Toggles + drag-resizes write through
/// synchronously (user-paced; no debounce needed). The shell process is
/// spawned LAZILY on first open and reaped on `shutdown()` — an app that
/// never opens the terminal never forks a shell.
///
/// TAB MODEL (TSK-368): the ordered tab collection + active-tab tracking +
/// new/close/select/reorder/rename + cwd-derived default titles all live in
/// the pure, host-testable `TerminalTabSet` (ViewerCore). This store delegates
/// every ordering/selection/naming decision to it and keeps a parallel
/// id→`TerminalModel` map of the LIVE shells (the part that can't be a value
/// type because it owns a PTY). The tab set (count + names + cwds + active id)
/// is persisted per tool-window; live shells don't survive relaunch, so a
/// restored set re-spawns fresh shells with the persisted names/cwds.

/// One terminal tab — the live shell session plus the descriptor that names it.
/// `id`/`number`/`title` mirror the `TerminalTabSet.Tab` it shadows so existing
/// view code (`tab.id`, `tab.number`) keeps working unchanged.
public struct TerminalTab: Identifiable {
    public let id: UUID
    public let number: Int
    public let model: TerminalModel
}

@MainActor
public final class TerminalPaneStore: ObservableObject {
    /// Whether the pane is showing. Mutating fires `objectWillChange` for
    /// the directly-observing `ContentView` + rail toggle.
    @Published public private(set) var isOpen: Bool
    /// Pane height in points. Mutating fires `objectWillChange`. Clamped
    /// to `[minHeight, maxHeight]`.
    @Published public private(set) var height: CGFloat

    /// Where the tab strip sits relative to the terminal surface (TSK-488).
    /// Default `.left`; persisted in `TerminalPaneLayout`.
    @Published public private(set) var tabPosition: TerminalTabPosition

    /// Which window edge the pane docks to (TSK-491). Default `.bottom`;
    /// persisted in `TerminalPaneLayout`. Distinct from `tabPosition`.
    @Published public private(set) var paneEdge: TerminalPaneEdge

    /// Side-column width when `paneEdge` is `.left`/`.right` (TSK-491).
    /// Clamped + persisted. (`height` still drives the bottom band.)
    @Published public private(set) var sideWidth: CGFloat

    /// The pure tab-collection model (ordering/selection/naming). Published so
    /// the strip re-renders on any tab mutation. The store keeps the live
    /// shells in `models`, keyed by `TerminalTabSet.Tab.id`.
    @Published public private(set) var tabSet: TerminalTabSet

    /// Live shells, keyed by tab id. A 1:1 shadow of `tabSet.tabs`.
    private var models: [UUID: TerminalModel] = [:]

    /// Open terminal tabs (each its own shell), in display order. Derived from
    /// `tabSet` + `models`, so the existing `ForEach(store.tabs)` UI keeps
    /// working unchanged.
    public var tabs: [TerminalTab] {
        tabSet.tabs.compactMap { tab in
            guard let model = models[tab.id] else { return nil }
            return TerminalTab(id: tab.id, number: tab.number, model: model)
        }
    }

    /// The active tab's id, or nil when the pane has no tabs.
    public var selectedTabID: UUID? { tabSet.activeID }

    /// Per-tab user-chosen names (compat accessor). Backed by `tabSet`'s
    /// `customName`; the entry is absent for a default-named tab.
    public var customNames: [UUID: String] {
        var out: [UUID: String] = [:]
        for tab in tabSet.tabs where tab.customName != nil {
            out[tab.id] = tab.customName
        }
        return out
    }

    /// The selected tab's live terminal — created on first open so the app
    /// pays no PTY cost until the user actually wants a shell.
    public var terminal: TerminalModel? {
        guard let id = tabSet.activeID else { return nil }
        return models[id]
    }

    private let defaults: UserDefaults
    private var layout: TerminalPaneLayout

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = TerminalPaneLayout.load(from: defaults)
        self.layout = loaded
        self.height = loaded.height
        self.tabPosition = loaded.tabPosition
        self.paneEdge = loaded.paneEdge
        self.sideWidth = loaded.sideWidth
        // Restore the persisted tab set (names/cwds/active id) — but NOT the
        // shells: a relaunch re-spawns fresh shells lazily when the view
        // mounts. An empty restored set is fine; `ensureTerminal()` seeds one.
        self.tabSet = loaded.tabSet
        // Restore "open" intent, but DON'T spawn the shell here — the
        // shell spawns when the view first mounts (the terminal getter is
        // exercised by ContentView only while `isOpen`).
        self.isOpen = loaded.isOpen
        // Re-materialize live models for every restored tab descriptor so the
        // pane shows them again (with their persisted name + spawn cwd).
        for tab in self.tabSet.tabs {
            let model = TerminalModel()
            model.initialWorkingDirectory = tab.cwd
            models[tab.id] = model
        }
        // Wire the live-cwd → persist bridge for every restored model (TSK-341).
        // `init` can't reference `self` in a closure until fully initialized,
        // so this runs after all stored properties are set.
        for (id, model) in models { wireCwdPersistence(id, model) }
        if loaded.isOpen { ensureTerminal() }
        syncForeground()
    }

    public var minHeight: CGFloat { TerminalPaneLayout.minHeight }
    public var maxHeight: CGFloat { TerminalPaneLayout.maxHeight }

    // MARK: - Toggle / open / close

    /// The left-rail bottom toggle. Flips open/closed; spawns the shell on
    /// first open and persists the new state.
    public func toggle() {
        setOpen(!isOpen)
    }

    public func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        layout.isOpen = open
        if open { ensureTerminal() }
        syncForeground()
        persist()
    }

    // MARK: - Height

    /// Set the pane height (drag-resize). Clamped + persisted. Equality-
    /// guarded so a no-op drag frame doesn't republish.
    public func setHeight(_ h: CGFloat) {
        let clamped = TerminalPaneLayout.clampHeight(h)
        guard clamped != height else { return }
        height = clamped
        layout.setHeight(clamped)
        persist()
    }

    // MARK: - Tab-strip position (TSK-488)

    /// Set where the tab strip sits (left/top/right). Persisted; equality-
    /// guarded so re-selecting the current position doesn't republish.
    public func setTabPosition(_ pos: TerminalTabPosition) {
        guard pos != tabPosition else { return }
        tabPosition = pos
        layout.tabPosition = pos
        persist()
    }

    // MARK: - Pane dock edge (TSK-491)

    /// Dock the pane to a window edge (bottom/left/right). Persisted;
    /// equality-guarded so re-selecting the current edge doesn't republish.
    public func setPaneEdge(_ edge: TerminalPaneEdge) {
        guard edge != paneEdge else { return }
        paneEdge = edge
        layout.paneEdge = edge
        persist()
    }

    public var minWidth: CGFloat { TerminalPaneLayout.minWidth }
    public var maxWidth: CGFloat { TerminalPaneLayout.maxWidth }

    /// Set the side-column width (drag-resize when docked left/right).
    /// Clamped + persisted; equality-guarded against no-op drag frames.
    public func setWidth(_ w: CGFloat) {
        let clamped = TerminalPaneLayout.clampWidth(w)
        guard clamped != sideWidth else { return }
        sideWidth = clamped
        layout.setWidth(clamped)
        persist()
    }

    // MARK: - Tabs

    /// Add a new shell tab and select it. The model spawns its shell when
    /// the representable mounts; `workingDirectory` (TSK-769) seeds that first
    /// spawn's cwd (nil → the shell's default home) AND the tab's cwd-derived
    /// default title (TSK-368).
    public func addTab(workingDirectory: URL? = nil) {
        let id = tabSet.addTab(cwd: workingDirectory)
        let model = TerminalModel()
        model.initialWorkingDirectory = workingDirectory
        models[id] = model
        wireCwdPersistence(id, model)
        syncForeground()
        persist()
    }

    /// Bridge a tab's live shell cwd (OSC 7, TSK-341) to the persisted tab
    /// descriptor: when the shell reports a new directory, write it through to
    /// `tabSet` and persist, so a restored tab re-spawns where the user LEFT
    /// OFF, not in the original spawn directory. Guarded against the unknown-id
    /// race (a closed tab's late callback) and no-op cwd changes.
    private func wireCwdPersistence(_ id: UUID, _ model: TerminalModel) {
        model.onWorkingDirectoryChange = { [weak self] cwd in
            guard let self else { return }
            // Tab may have been closed before this late callback; setCwd no-ops
            // on an unknown id, and we only persist when it actually changed.
            let before = self.tabSet.tab(id)?.cwd
            guard before != cwd else { return }
            self.tabSet.setCwd(id, to: cwd)
            self.persist()
        }
    }

    /// Rename a tab (TSK-771). A whitespace-only / empty name CLEARS the
    /// custom name (reverting to the default title). No-op for an unknown id
    /// or when the value is unchanged (so the strip doesn't republish).
    public func renameTab(_ id: UUID, to name: String) {
        guard tabSet.rename(id, to: name) else { return }
        persist()
    }

    /// The short chip label: the custom name if set, else the cwd folder name,
    /// else the bare tab number (TSK-368 cwd-derived titles).
    public func tabLabel(for tab: TerminalTab) -> String {
        guard let descriptor = tabSet.tab(tab.id) else { return "\(tab.number)" }
        return tabSet.label(for: descriptor)
    }

    /// The full title (tooltip / accessibility): the custom name if set, else
    /// "Terminal N — <folder>" when a cwd is known, else "Terminal N".
    public func tabTitle(for tab: TerminalTab) -> String {
        guard let descriptor = tabSet.tab(tab.id) else { return "Terminal \(tab.number)" }
        return tabSet.title(for: descriptor)
    }

    /// Select an existing tab by id (no-op for an unknown id).
    public func selectTab(_ id: UUID) {
        guard tabSet.select(id) else { return }
        syncForeground()
        persist()
    }

    /// Cycle to the next (`forward`) or previous tab, wrapping around.
    /// No-op with fewer than two tabs. Drives ⌃Tab / ⌃⇧Tab.
    public func cycleTab(forward: Bool) {
        let before = tabSet.activeID
        _ = tabSet.cycle(forward: forward)
        guard tabSet.activeID != before else { return }
        syncForeground()
        persist()
    }

    /// Reorder a tab (drag in the strip): move the tab at `from` to land at
    /// `to` in the post-removal list. The active tab stays active. Persisted.
    public func moveTab(from: Int, to: Int) {
        let before = tabSet.tabs.map(\.id)
        tabSet.move(from: from, to: to)
        guard tabSet.tabs.map(\.id) != before else { return }
        persist()
    }

    /// Close a tab, reaping its shell. Closing the last tab closes the
    /// whole pane; closing the selected tab selects a neighbor.
    public func closeTab(_ id: UUID) {
        guard tabSet.tab(id) != nil else { return }
        let model = models[id]
        guard tabSet.close(id) else { return }
        model?.stop()
        models[id] = nil
        if tabSet.isEmpty {
            setOpen(false)            // last tab closed → close the pane
            return
        }
        syncForeground()
        persist()
    }

    // MARK: - Shell lifecycle

    /// Ensure the pane has at least one tab (called on open). The model
    /// spawns the shell itself when the representable mounts.
    private func ensureTerminal() {
        if tabSet.isEmpty { addTab() }
    }

    /// Mark exactly the visible shell foreground (pane open AND selected)
    /// and every other tab background, so deselected/closed-pane shells stop
    /// scheduling UI bumps no view observes (TSK-459). Cheap + idempotent
    /// (each model's `setForeground` early-returns on no change).
    private func syncForeground() {
        let active = tabSet.activeID
        for (id, model) in models {
            model.setForeground(isOpen && id == active)
        }
    }

    /// Persist the layout + tab set so the pane (and its named/cwd'd tabs +
    /// active selection) survive relaunch. User-paced — no debounce needed.
    private func persist() {
        layout.tabSet = tabSet
        layout.save(to: defaults)
    }

    /// Reap every shell on app teardown. Idempotent.
    public func shutdown() {
        for model in models.values { model.stop() }
    }
}
