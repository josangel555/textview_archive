import Foundation
import Combine
import ViewerCore

/// Observable owner of the bottom terminal pane: open/closed state, pane
/// height, and the lazily-spawned `TerminalModel` (the live shell).
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
/// One terminal tab — a live shell session plus a stable id + display
/// number. Multiple tabs each fork their own PTY (like iTerm tabs).
public struct TerminalTab: Identifiable {
    public let id = UUID()
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

    /// Open terminal tabs (each its own shell), in display order.
    @Published public private(set) var tabs: [TerminalTab] = []
    /// The selected tab's id, or nil when the pane has no tabs.
    @Published public private(set) var selectedTabID: UUID?

    private var nextNumber = 1

    /// The selected tab's live terminal — created on first open so the app
    /// pays no PTY cost until the user actually wants a shell.
    public var terminal: TerminalModel? {
        tabs.first { $0.id == selectedTabID }?.model
    }

    private let defaults: UserDefaults
    private var layout: TerminalPaneLayout

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loaded = TerminalPaneLayout.load(from: defaults)
        self.layout = loaded
        self.height = loaded.height
        // Restore "open" intent, but DON'T spawn the shell here — the
        // shell spawns when the view first mounts (the terminal getter is
        // exercised by ContentView only while `isOpen`).
        self.isOpen = loaded.isOpen
        if loaded.isOpen { ensureTerminal() }
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
        layout.save(to: defaults)
    }

    // MARK: - Height

    /// Set the pane height (drag-resize). Clamped + persisted. Equality-
    /// guarded so a no-op drag frame doesn't republish.
    public func setHeight(_ h: CGFloat) {
        let clamped = TerminalPaneLayout.clampHeight(h)
        guard clamped != height else { return }
        height = clamped
        layout.setHeight(clamped)
        layout.save(to: defaults)
    }

    // MARK: - Tabs

    /// Add a new shell tab and select it. The model spawns its shell when
    /// the representable mounts.
    public func addTab() {
        let tab = TerminalTab(number: nextNumber, model: TerminalModel())
        nextNumber += 1
        tabs.append(tab)
        selectedTabID = tab.id
    }

    /// Select an existing tab by id (no-op for an unknown id).
    public func selectTab(_ id: UUID) {
        guard selectedTabID != id, tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
    }

    /// Close a tab, reaping its shell. Closing the last tab closes the
    /// whole pane; closing the selected tab selects a neighbor.
    public func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: idx)
        tab.model.stop()
        if tabs.isEmpty {
            selectedTabID = nil
            nextNumber = 1            // fresh numbering next time it opens
            setOpen(false)            // last tab closed → close the pane
            return
        }
        if selectedTabID == id {
            selectedTabID = tabs[min(idx, tabs.count - 1)].id
        }
    }

    // MARK: - Shell lifecycle

    /// Ensure the pane has at least one tab (called on open). The model
    /// spawns the shell itself when the representable mounts.
    private func ensureTerminal() {
        if tabs.isEmpty { addTab() }
    }

    /// Reap every shell on app teardown. Idempotent.
    public func shutdown() {
        for tab in tabs { tab.model.stop() }
    }
}
