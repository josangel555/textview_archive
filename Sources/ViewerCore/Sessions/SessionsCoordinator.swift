import Combine
import Foundation

/// Phase-1 `SessionsCoordinator`. Owns the in-memory list of session
/// snapshots plus the "currently active" pointer; drives persistence
/// through a `SessionStore`.
///
/// **Layering**: this type lives in `ViewerCore` and is *value*-based:
/// each session is a mutable `SessionSnapshot` value, not a reference.
/// The `ViewerUI` layer adds a thin `@MainActor` `SessionState` that
/// holds a real `DocumentModel` instance per session and wires the
/// lifecycle hooks below. Splitting this way keeps ViewerCore free of
/// UI-layer dependencies (DocumentModel, FileWatcher, SwiftUI), which
/// `ViewerCore` cannot import.
///
/// **Lifecycle ordering (design-doc gap #2, fixed)**: every active
/// transition is *detach-then-mount*, always, including the initial
/// `restore()` — if a previous coordinator state somehow left a
/// session mounted, we detach it first. This invariant is enforced
/// here and re-documented in §6.2.
///
/// **forceNew semantics (design-doc gap #3, fixed)**: we standardize
/// `url` via `standardizedFileURL.resolvingSymlinksInPath()` and use
/// the *resolved* path as the matching key. Distinct symlinks to the
/// same physical directory collapse into a single session by default;
/// callers who genuinely want two sessions over the same realpath
/// (worktrees, namespaced clones) must pass `forceNew: true`. The
/// session snapshot stores the resolved path so the choice is
/// reversible — a future feature can preserve the original URL too
/// if needed.
@MainActor
public final class SessionsCoordinator: ObservableObject {

    /// Side-effect hook for the mount/detach lifecycle. The default
    /// `nil` is a no-op (used in pure-logic tests); the app wires a
    /// real implementation that pauses/resumes the file watcher on a
    /// `DocumentModel`.
    @MainActor
    public protocol Lifecycle: AnyObject {
        func mount(_ session: SessionSnapshot)
        func detach(_ session: SessionSnapshot)
    }

    @Published public private(set) var sessions: [SessionSnapshot] = []
    @Published public private(set) var activeID: UUID?

    /// Surfaces non-fatal persistence failures to the UI for
    /// diagnostics. The coordinator never throws — all IO is best-
    /// effort, matching the rest of the persistence layer.
    @Published public private(set) var lastError: String?

    private let store: SessionStore
    private weak var lifecycle: (any Lifecycle)?

    public init(store: SessionStore = SessionStore(),
                lifecycle: (any Lifecycle)? = nil) {
        self.store = store
        self.lifecycle = lifecycle
    }

    public var active: SessionSnapshot? {
        guard let id = activeID else { return nil }
        return sessions.first { $0.id == id }
    }

    /// Late wiring of the lifecycle hook. Used by the app's bootstrap
    /// path which constructs the coordinator before the SessionState
    /// machinery is ready. After this assignment, subsequent mount/
    /// detach calls are delivered.
    public func setLifecycle(_ lifecycle: any Lifecycle) {
        self.lifecycle = lifecycle
    }

    // MARK: Lifecycle ------------------------------------------------

    /// Build the in-memory session list from `index.json`. Sessions
    /// whose snapshot file is missing or corrupt are skipped (logged
    /// to `lastError`); design's "graceful skip + log" contract.
    public func restore() {
        // Detach-before-mount invariant: defensive guard for the rare
        // case where `restore()` is called twice (e.g. test reset).
        if let prev = active { lifecycle?.detach(prev) }
        guard let idx = store.loadIndex() else {
            sessions = []
            activeID = nil
            return
        }
        var loaded: [SessionSnapshot] = []
        var skipped: [UUID] = []
        for entry in idx.sessions {
            if let snap = store.load(id: entry.id) {
                loaded.append(snap)
            } else {
                skipped.append(entry.id)
            }
        }
        sessions = loaded
        if let last = idx.lastActiveID, loaded.contains(where: { $0.id == last }) {
            activeID = last
        } else {
            activeID = loaded
                .sorted(by: { $0.lastActiveAt > $1.lastActiveAt })
                .first?.id
        }
        if !skipped.isEmpty {
            lastError = "Skipped \(skipped.count) unreadable session snapshot(s)."
        }
        if let id = activeID, let s = sessions.first(where: { $0.id == id }) {
            lifecycle?.mount(s)
        }
    }

    /// Create-or-reveal: matches design's "open folder picks an
    /// existing session for the same physical path, else creates a
    /// new one" rule. `forceNew` bypasses the match for worktrees /
    /// symlink chains the user genuinely wants distinct.
    @discardableResult
    public func openFolder(_ url: URL, forceNew: Bool = false) -> SessionSnapshot {
        // Standardize so `/x/proj` and `/x/proj/` collapse; resolve
        // symlinks so two paths pointing at the same realpath
        // (worktree foo → /a/b/main; foo-link → /a/b/main) collapse
        // into one session unless forceNew.
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedPath = resolved.path

        if !forceNew, let existing = sessions.first(where: {
            $0.sidebarRootPath == resolvedPath
        }) {
            activate(id: existing.id)
            return existing
        }

        let now = Date()
        let displayName: String = {
            let last = resolved.lastPathComponent
            return last.isEmpty ? "Untitled" : last
        }()
        let snap = SessionSnapshot(
            id: UUID(),
            displayName: displayName,
            createdAt: now,
            lastActiveAt: now,
            sidebarRootPath: resolvedPath
        )
        // Detach the outgoing session before mounting the new one.
        if let prev = active { lifecycle?.detach(prev) }
        sessions.append(snap)
        activeID = snap.id
        lifecycle?.mount(snap)
        persist()
        return snap
    }

    /// Switch the active session. No-op if already active. Drives the
    /// detach-then-mount lifecycle on `Lifecycle`.
    public func activate(id: UUID) {
        guard activeID != id else { return }
        guard sessions.contains(where: { $0.id == id }) else { return }
        if let prev = active { lifecycle?.detach(prev) }
        // Bump lastActiveAt on BOTH the outgoing and incoming sessions
        // so LRU reflects most-recently-used. Previously only the
        // outgoing was bumped, so after A → B → A, closing A would
        // re-activate B even though the user just re-engaged with A.
        // Use distinct timestamps (incoming strictly after outgoing)
        // so the incoming wins ties in the LRU sort even when Date()
        // returns the same value twice in quick succession.
        if let prevID = activeID,
           let idx = sessions.firstIndex(where: { $0.id == prevID }) {
            sessions[idx] = touched(sessions[idx])
        }
        if let idx = sessions.firstIndex(where: { $0.id == id }) {
            // +1µs ensures strict ordering against the outgoing bump.
            sessions[idx] = touched(
                sessions[idx],
                at: Date().addingTimeInterval(0.000_001)
            )
        }
        activeID = id
        if let nowActive = active { lifecycle?.mount(nowActive) }
        persist()
    }

    /// Close a session. Stages its snapshot to trash for the 30-day
    /// recovery window, then drops it from the live list. If it was
    /// the active session, activates the next most-recently-used
    /// (LRU); if it was the last, clears `activeID`.
    public func close(id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let removed = sessions[idx]
        let wasActive = (activeID == id)
        if wasActive { lifecycle?.detach(removed) }
        // Sync save before trash move so the trashed file contains
        // the latest in-memory state, not whatever the last coalesced
        // write left on disk.
        store.saveSync(removed)
        store.moveToTrash(id: removed.id)
        sessions.remove(at: idx)
        if wasActive {
            activeID = sessions
                .sorted(by: { $0.lastActiveAt > $1.lastActiveAt })
                .first?.id
            if let nowActive = active { lifecycle?.mount(nowActive) }
        }
        persist()
    }

    /// Close every session except `id`. Used by the session-tab
    /// context menu's "Close Other Sessions" action. Each closure
    /// routes through `close(id:)` so the per-session lifecycle
    /// (trash + persist + LRU re-activation) runs exactly once per
    /// removed session; the caller doesn't need to coordinate.
    ///
    /// No-op if `id` is not a known session, so callers can safely
    /// pass the right-clicked session id without re-checking.
    public func closeOthers(except id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        // Snapshot the ids up front: `close(id:)` mutates `sessions`,
        // so iterating the live array would skip neighbours.
        let victims = sessions.map(\.id).filter { $0 != id }
        for victim in victims { close(id: victim) }
    }

    // MARK: Navigation -----------------------------------------------

    public func nextSession() {
        guard !sessions.isEmpty,
              let id = activeID,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        activate(id: sessions[(idx + 1) % sessions.count].id)
    }

    public func previousSession() {
        guard !sessions.isEmpty,
              let id = activeID,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let prev = (idx - 1 + sessions.count) % sessions.count
        activate(id: sessions[prev].id)
    }

    public func activate(index n: Int) {
        guard sessions.indices.contains(n) else { return }
        activate(id: sessions[n].id)
    }

    // MARK: Mutation surface for in-memory sessions ------------------

    /// Update a session in place. Used by tests and any future code
    /// path that mutates session-scoped state (rename, snapshot
    /// writeback). Persists the change through the coalescer.
    public func updateSession(id: UUID,
                              transform: (inout SessionSnapshot) -> Void) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        var s = sessions[idx]
        transform(&s)
        sessions[idx] = s
        persist()
    }

    /// Replace a session's full snapshot. Used when the
    /// UI-layer `SessionState` produces a freshly serialized
    /// `SessionSnapshot` from the live `DocumentModel`.
    public func replaceSnapshot(id: UUID, with snap: SessionSnapshot) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        // Defend against id-mismatch (caller bug): keep the session's
        // own id even if `snap.id` differs.
        let merged = SessionSnapshot(
            schemaVersion: snap.schemaVersion,
            savedAt: snap.savedAt,
            id: sessions[idx].id,
            displayName: snap.displayName,
            createdAt: sessions[idx].createdAt,
            lastActiveAt: snap.lastActiveAt,
            sidebarRootPath: snap.sidebarRootPath,
            openTabs: snap.openTabs,
            selectedTabIndex: snap.selectedTabIndex,
            sidebarExpandedPaths: snap.sidebarExpandedPaths,
            sidebarIncludeHidden: snap.sidebarIncludeHidden,
            splitURL: snap.splitURL,
            zoom: snap.zoom,
            wordWrap: snap.wordWrap,
            themeOverride: snap.themeOverride
        )
        sessions[idx] = merged
        persist()
    }

    /// Block until the persistence write queue is drained. Call from
    /// `applicationWillTerminate`. Implemented by SessionStore's
    /// `flushSync()`; surfaced here so callers don't need a reference
    /// to the underlying store.
    public func flushPersistenceSync() {
        store.flushSync()
    }

    // MARK: - private

    /// Write the index + every per-session snapshot through the
    /// coalescing write queue. Returns immediately.
    private func persist() {
        let entries = sessions.map { s in
            SessionIndex.Entry(
                id: s.id,
                rootPath: s.sidebarRootPath ?? "",
                displayName: s.displayName,
                lastActiveAt: s.lastActiveAt
            )
        }
        let idx = SessionIndex(sessions: entries, lastActiveID: activeID)
        store.enqueueSaveIndex(idx)
        let saveTime = Date()
        for s in sessions {
            // Stamp `savedAt` on the disk copy without disturbing the
            // in-memory value (which uses `lastActiveAt` for LRU).
            let stamped = SessionSnapshot(
                schemaVersion: s.schemaVersion,
                savedAt: saveTime,
                id: s.id,
                displayName: s.displayName,
                createdAt: s.createdAt,
                lastActiveAt: s.lastActiveAt,
                sidebarRootPath: s.sidebarRootPath,
                openTabs: s.openTabs,
                selectedTabIndex: s.selectedTabIndex,
                sidebarExpandedPaths: s.sidebarExpandedPaths,
                sidebarIncludeHidden: s.sidebarIncludeHidden,
                splitURL: s.splitURL,
                zoom: s.zoom,
                wordWrap: s.wordWrap,
                themeOverride: s.themeOverride
            )
            store.enqueueSave(stamped)
        }
    }

    private func touched(_ s: SessionSnapshot, at when: Date = Date()) -> SessionSnapshot {
        SessionSnapshot(
            schemaVersion: s.schemaVersion,
            savedAt: s.savedAt,
            id: s.id,
            displayName: s.displayName,
            createdAt: s.createdAt,
            lastActiveAt: when,
            sidebarRootPath: s.sidebarRootPath,
            openTabs: s.openTabs,
            selectedTabIndex: s.selectedTabIndex,
            sidebarExpandedPaths: s.sidebarExpandedPaths,
            sidebarIncludeHidden: s.sidebarIncludeHidden,
            splitURL: s.splitURL,
            zoom: s.zoom,
            wordWrap: s.wordWrap,
            themeOverride: s.themeOverride
        )
    }
}
