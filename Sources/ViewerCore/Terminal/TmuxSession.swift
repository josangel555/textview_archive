import Foundation

/// One tmux **window** (`@N`) — the unit that maps to a native app tab.
///
/// A window owns a pane *layout tree* (the canonical typed `PaneNode`, parsed
/// from the tmux layout string by `TmuxLayoutParser`) and tracks which pane is
/// active (a `TmuxPaneID`, never a bare int). It carries **topology + names +
/// active selection only** — NOT the live `TerminalScreen`/`ANSIParser`
/// instances, which the controller (the VM-tail slice) owns and keys by pane
/// id. See `docs/TMUX_CC_DESIGN_2026-06-18.md` §2-§3.
public struct TmuxWindow: Equatable, Sendable, Identifiable {
    /// tmux window id (the `@N` sigil's integer). Stable across renames.
    public let id: Int
    /// Display name (the tab title). Updated by `%window-renamed`.
    public var name: String
    /// Pane layout tree from the most recent `%layout-change`, or `nil`
    /// until the first layout arrives.
    public var layout: PaneNode?
    /// tmux pane id of the active pane within this window, or `nil` until a
    /// `%window-pane-changed` (or a layout with a single pane) sets it.
    public var activePaneID: TmuxPaneID?

    public init(id: Int, name: String = "", layout: PaneNode? = nil, activePaneID: TmuxPaneID? = nil) {
        self.id = id
        self.name = name
        self.layout = layout
        self.activePaneID = activePaneID
    }

    /// Flatten this window's layout tree to its pane ids, in document order
    /// (left-to-right / top-to-bottom as laid out). Empty when no layout has
    /// arrived yet. The controller uses this to know which per-pane
    /// `ANSIParser`/`TerminalScreen` instances to allocate or reap. Delegates
    /// to the canonical `TerminalPaneTree.paneIDs` so there is ONE flatten.
    public var paneIDs: [TmuxPaneID] {
        guard let layout else { return [] }
        return TerminalPaneTree.paneIDs(in: layout)
    }
}

/// Pure topology model for a tmux control-mode (`tmux -CC`) attachment.
///
/// Holds the ordered list of windows (→ the native tab strip), the active
/// window, and the attached session identity. It is a **deterministic state
/// machine**: feed it the typed `ControlModeEvent`s produced by
/// `TmuxControlParser` via `apply(_:)` and it mutates topology to match. It
/// owns NO I/O, NO AppKit, and NO `TerminalScreen` — those live in the
/// controller (the VM-tail slice). This separation keeps the correctness-
/// critical topology fully host-testable.
///
/// `ControlModeEvent` carries pane/window ids as bare `Int` (the wire form);
/// this model wraps pane ids into `TmuxPaneID` at its boundary so the rest of
/// the model — and the canonical `PaneNode` tree — never traffics bare ints.
///
/// Design (`docs/TMUX_CC_DESIGN_2026-06-18.md` §2-§3):
/// - `%window-add` → append a window (new tab).
/// - `%window-close` → remove it; reselect a neighbor like the app's
///   `closeTab` does (the tab to the LEFT if any, else the new first).
/// - `%window-renamed` → retitle.
/// - `%layout-change` → parse the layout string into a `PaneNode` tree and
///   store it on the window; if the window has no active pane yet, default it
///   to the layout's first pane so the controller always has a focus target.
/// - `%window-pane-changed` → update that window's `activePaneID`.
/// - `%session-changed` → update the attached session identity.
///
/// Reply-framing events (`%begin`/`%end`/`%error`/`replyLine`), `%output`,
/// and every other event are **inert** here — `%output` is demuxed to pane
/// screens by the controller, and replies are correlated there too. `apply`
/// returns whether it changed topology, so an observable wrapper can decide
/// to publish.
public struct TmuxSession: Equatable, Sendable {
    /// Ordered windows — index order IS the tab-strip order.
    public private(set) var windows: [TmuxWindow] = []
    /// The active window's id, or `nil` when there are no windows.
    public private(set) var activeWindowId: Int?
    /// tmux session id (`$N`), or `nil` before the first `%session-changed`.
    public private(set) var sessionId: Int?
    /// tmux session name, or `nil` before the first `%session-changed`.
    public private(set) var sessionName: String?

    public init() {}

    // MARK: - Lookup

    /// The active window, or `nil` when empty / unset.
    public var activeWindow: TmuxWindow? {
        guard let id = activeWindowId else { return nil }
        return window(id: id)
    }

    /// Index of the window with `id`, or `nil`.
    public func index(ofWindow id: Int) -> Int? {
        windows.firstIndex { $0.id == id }
    }

    /// The window with `id`, or `nil`.
    public func window(id: Int) -> TmuxWindow? {
        guard let i = index(ofWindow: id) else { return nil }
        return windows[i]
    }

    /// The active pane id of a given window, or `nil` if the window or its
    /// active pane is unknown.
    public func activePaneID(inWindow id: Int) -> TmuxPaneID? {
        window(id: id)?.activePaneID
    }

    /// Flattened pane-id set of a window, in document order. Empty if the
    /// window is unknown or has no layout yet. Mirrors `TmuxWindow.paneIDs`.
    public func paneIDs(inWindow id: Int) -> [TmuxPaneID] {
        window(id: id)?.paneIDs ?? []
    }

    /// Every pane id across every window, in window-then-document order.
    /// The controller's universe of live pane screens.
    public var allPaneIDs: [TmuxPaneID] {
        windows.flatMap(\.paneIDs)
    }

    // MARK: - Event application

    /// Apply one control-mode event, mutating topology. Returns `true` when
    /// the model changed (a window/active selection/name/layout/session
    /// changed), `false` for inert events (`%output`, reply framing, and the
    /// notifications this model doesn't track). Idempotent for redundant
    /// events (e.g. re-adding an existing window, renaming to the same name).
    @discardableResult
    public mutating func apply(_ event: ControlModeEvent) -> Bool {
        switch event {
        case .windowAdd(let win):
            return addWindow(id: win)

        case .windowClose(let win):
            return closeWindow(id: win)

        case .windowRenamed(let win, let name):
            return renameWindow(id: win, to: name)

        case .layoutChange(let win, let layout):
            return applyLayout(window: win, layoutString: layout)

        case .windowPaneChanged(let win, let pane):
            return setActivePane(window: win, pane: TmuxPaneID(pane))

        case .sessionChanged(let sess, let name):
            return setSession(id: sess, name: name)

        // Inert here: pane output is demuxed by the controller; reply
        // framing is correlated by the controller; the remaining
        // notifications carry no topology this model tracks.
        case .output,
             .beginReply, .replyLine, .endReply, .errorReply,
             .clientSessionChanged, .sessionsChanged,
             .paneModeChanged, .exit, .unknown:
            return false
        }
    }

    /// Apply a batch of events in order; returns whether ANY changed topology.
    @discardableResult
    public mutating func apply(_ events: [ControlModeEvent]) -> Bool {
        var changed = false
        for event in events {
            // Note: `||` short-circuits, so call `apply` FIRST to avoid
            // skipping the mutation once `changed` is true.
            let didChange = apply(event)
            changed = changed || didChange
        }
        return changed
    }

    // MARK: - Mutations

    /// Append a new window. The first window added becomes active. Re-adding
    /// an existing id is a no-op (tmux can re-announce on reattach).
    private mutating func addWindow(id: Int) -> Bool {
        guard index(ofWindow: id) == nil else { return false }
        windows.append(TmuxWindow(id: id))
        if activeWindowId == nil {
            activeWindowId = id
        }
        return true
    }

    /// Remove a window and reselect a neighbor when the closed one was
    /// active — the tab to its LEFT if any, else the new first window, else
    /// `nil` (last window closed). Mirrors the app's `closeTab` reselect.
    private mutating func closeWindow(id: Int) -> Bool {
        guard let i = index(ofWindow: id) else { return false }
        let wasActive = (activeWindowId == id)
        windows.remove(at: i)

        if wasActive {
            if windows.isEmpty {
                activeWindowId = nil
            } else {
                // Prefer the left neighbor (index i-1); when we closed index
                // 0 that clamps to the new first window.
                let neighbor = max(0, i - 1)
                activeWindowId = windows[neighbor].id
            }
        }
        return true
    }

    /// Retitle a window. No-op if the window is unknown or the name is equal.
    private mutating func renameWindow(id: Int, to name: String) -> Bool {
        guard let i = index(ofWindow: id), windows[i].name != name else { return false }
        windows[i].name = name
        return true
    }

    /// Parse a layout string and store the resulting tree on the window.
    /// An unparseable layout is ignored (no mutation, returns `false`) so a
    /// malformed line never corrupts topology. When the window has no active
    /// pane yet, default it to the layout's first pane in document order so
    /// the controller always has a focus target.
    private mutating func applyLayout(window id: Int, layoutString: String) -> Bool {
        guard let i = index(ofWindow: id) else { return false }
        guard let tree = TmuxLayoutParser.parse(layoutString) else { return false }
        let panes = TerminalPaneTree.paneIDs(in: tree)

        var changed = false
        if windows[i].layout != tree {
            windows[i].layout = tree
            changed = true
        }
        // Seed an active pane if none is set, OR if the current one vanished
        // from the new layout (e.g. its pane was killed).
        let current = windows[i].activePaneID
        let needsActive = current == nil || (current.map { !panes.contains($0) } ?? true)
        if needsActive, let first = panes.first, windows[i].activePaneID != first {
            windows[i].activePaneID = first
            changed = true
        }
        return changed
    }

    /// Update a window's active pane. No-op if the window is unknown or the
    /// pane is already active. (We trust tmux that the pane belongs to the
    /// window — `%window-pane-changed` carries both ids.)
    private mutating func setActivePane(window id: Int, pane: TmuxPaneID) -> Bool {
        guard let i = index(ofWindow: id), windows[i].activePaneID != pane else { return false }
        windows[i].activePaneID = pane
        return true
    }

    /// Update the attached session identity. No-op if both id and name match.
    private mutating func setSession(id: Int, name: String) -> Bool {
        guard sessionId != id || sessionName != name else { return false }
        sessionId = id
        sessionName = name
        return true
    }

    // MARK: - Window-selection (driven by our UI, not by tmux events)

    /// Select a window by id (e.g. the user clicked its tab). No-op if the
    /// window is unknown or already active. Returns whether it changed.
    @discardableResult
    public mutating func selectWindow(id: Int) -> Bool {
        guard index(ofWindow: id) != nil, activeWindowId != id else { return false }
        activeWindowId = id
        return true
    }
}
