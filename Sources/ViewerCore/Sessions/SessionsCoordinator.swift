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

    /// True when the on-disk `index.json` was written by a newer
    /// schema than this build understands (downgrade scenario). While
    /// set, `persist()` skips the index write so we never truncate the
    /// newer build's fields (PERSIST-04). Per-session snapshot writes
    /// are independently gated by `SessionStore.load`'s own
    /// forward-compat guard, so they remain safe to issue.
    public private(set) var indexWriteBlocked: Bool = false

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
        // Reset the downgrade guard each restore — a fresh probe decides.
        indexWriteBlocked = false
        let idx: SessionIndex
        switch store.loadIndexResult() {
        case .loaded(let loaded):
            idx = loaded
        case .absent:
            // Fresh install / no index — OR the index was clobbered/deleted
            // while session snapshots survived (TSK-438). Try to self-heal
            // from orphaned snapshots before falling back to empty.
            if adoptRecoveredSnapshotsIfAny() { return }
            sessions = []
            activeID = nil
            return
        case .corrupt:
            // Unparseable bytes: try snapshot recovery first; else start empty.
            // Re-persisting can only improve matters, so writes stay unblocked.
            if adoptRecoveredSnapshotsIfAny() { return }
            sessions = []
            activeID = nil
            lastError = "Session index was unreadable; starting with no sessions."
            return
        case .newerSchema(let found):
            // Downgrade: a newer build wrote this index. Do NOT clobber
            // it. Present a non-destructive banner and leave the live
            // list empty for this older build. (PERSIST-04)
            indexWriteBlocked = true
            sessions = []
            activeID = nil
            lastError = "This app version is older than your saved sessions "
                + "(index schema v\(found) > v\(SessionIndex.currentSchema)). "
                + "Sessions are preserved on disk; update the app to restore them."
            return
        }
        var loaded: [SessionSnapshot] = []
        var skipped: [UUID] = []
        var missingFolder: [UUID] = []
        for entry in idx.sessions {
            guard let snap = store.load(id: entry.id) else {
                skipped.append(entry.id)
                continue
            }
            // PERSIST-10: a session whose sidebar root is empty/nil must
            // NOT be loaded. The UI layer's mount path falls back to
            // `NSHomeDirectory()` for an empty/nil root (see
            // `SessionsAppCoordinator.mountSession`), which silently
            // re-roots the whole session at $HOME — surprising and
            // potentially exposing the user's home folder. Drop it from
            // the live list (the snapshot file stays on disk, so this is
            // non-destructive and recoverable) and flag it.
            //
            // A *non-empty but currently-missing* path (e.g. a deleted
            // project dir on an external drive) is left alone here: it
            // does NOT trigger the $HOME re-root, and `hydrate` already
            // guards `sidebar.setRoot` behind a `fileExists` check, so
            // the session restores harmlessly and recovers if the folder
            // reappears.
            guard let root = snap.sidebarRootPath, !root.isEmpty else {
                missingFolder.append(entry.id)
                continue
            }
            loaded.append(snap)
        }
        // TSK-438 self-heal: a valid-but-EMPTY index (the clobber outcome) while
        // substantial snapshots still live on disk → recover from them.
        if loaded.isEmpty, adoptRecoveredSnapshotsIfAny() { return }
        sessions = loaded
        if let last = idx.lastActiveID, loaded.contains(where: { $0.id == last }) {
            activeID = last
        } else {
            activeID = loaded
                .sorted(by: { $0.lastActiveAt > $1.lastActiveAt })
                .first?.id
        }
        var notes: [String] = []
        if !skipped.isEmpty {
            notes.append("Skipped \(skipped.count) unreadable session snapshot(s).")
        }
        if !missingFolder.isEmpty {
            notes.append("Skipped \(missingFolder.count) session(s) whose folder is missing.")
        }
        if !notes.isEmpty {
            lastError = notes.joined(separator: " ")
        }
        if let id = activeID, let s = sessions.first(where: { $0.id == id }) {
            lifecycle?.mount(s)
        }
    }

    /// TSK-438 self-heal. When the index yields no sessions but substantial
    /// orphaned snapshots survive on disk (sessions lost to an index clobber —
    /// NOT intentionally closed, since `close()` trashes the snapshot first),
    /// rebuild the live list + a fresh index from them and mount the newest.
    /// Returns true if it adopted a recovered set. Callers must NOT invoke this
    /// under the `.newerSchema` downgrade guard (it would overwrite a newer
    /// build's index). Snapshot files are never modified — only re-indexed.
    private func adoptRecoveredSnapshotsIfAny() -> Bool {
        let recovered = store.recoverableSnapshots()
        guard !recovered.isEmpty else { return false }
        sessions = recovered                 // already deduped + newest-first
        activeID = recovered.first?.id
        let entries = recovered.map {
            SessionIndex.Entry(id: $0.id,
                               rootPath: $0.sidebarRootPath ?? "",
                               displayName: $0.displayName,
                               lastActiveAt: $0.lastActiveAt)
        }
        store.saveIndexSync(SessionIndex(sessions: entries, lastActiveID: activeID))
        lastError = "Recovered \(recovered.count) session(s) from disk after the "
            + "saved index was lost."
        if let id = activeID, let s = sessions.first(where: { $0.id == id }) {
            lifecycle?.mount(s)
        }
        return true
    }

    /// Create-or-reveal: matches design's "open folder picks an
    /// existing session for the same physical path, else creates a
    /// new one" rule. `forceNew` bypasses the match for worktrees /
    /// symlink chains the user genuinely wants distinct.
    ///
    /// `kind` (#184) records the session type on a NEWLY created session.
    /// It is a SEED-ONCE template — the UI layer applies the kind's
    /// default panel layout once on first mount, then never re-imposes
    /// it. Revealing an *existing* session ignores `kind` (the existing
    /// session keeps whatever type it was created with).
    @discardableResult
    public func openFolder(_ url: URL,
                           forceNew: Bool = false,
                           kind: SessionKind? = nil) -> SessionSnapshot {
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
        // TSK-1016: derive the title from the folder name via the single shared
        // helper so the new-session title and a later root-change relabel can
        // never diverge. `displayNameIsUserSet` stays nil (folder-derived).
        let displayName = SessionRename.defaultDisplayName(forRoot: resolved)
        let snap = SessionSnapshot(
            id: UUID(),
            displayName: displayName,
            createdAt: now,
            lastActiveAt: now,
            sidebarRootPath: resolvedPath,
            // Record the kind so the UI seed-once fires for it. Default
            // `.project` is left as nil (== plain project) to keep a
            // fresh-session snapshot minimal + byte-identical to today.
            sessionType: (kind != nil && kind != .project) ? kind?.rawValue : nil
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
        // own id + createdAt even if `snap` differs; everything else
        // (incl. the new sessionType / panelLayout) comes from `snap`.
        let merged = snap.with(
            id: sessions[idx].id,
            createdAt: sessions[idx].createdAt
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

    /// One queued write in the crash-safe persist order (TSK-1029).
    enum PersistOp {
        case snapshot(SessionSnapshot)
        case index(SessionIndex)
    }

    /// Build the persist plan: every per-session SNAPSHOT first, THEN the index.
    ///
    /// Snapshots-before-index is the crash-safety invariant (TSK-1029): both
    /// writes go through one FIFO queue, so on a crash mid-flush the index (which
    /// references snapshots) must never be a generation AHEAD of the snapshots on
    /// disk — that would dangle-reference a not-yet-written snapshot (data loss).
    /// The reverse (a snapshot with a stale index) is harmless: an orphan
    /// snapshot, recovered on the next clean persist.
    ///
    /// PERSIST-04: when the on-disk index was written by a NEWER schema
    /// (downgrade), the index write is skipped so we don't truncate the newer
    /// build's fields — snapshots still go out (each carries its own
    /// schemaVersion + the newer reader's forward-compat guard). Pure +
    /// host-testable.
    static func persistPlan(
        sessions: [SessionSnapshot], activeID: UUID?, indexWriteBlocked: Bool, saveTime: Date
    ) -> [PersistOp] {
        // Stamp `savedAt` on the disk copy without disturbing the in-memory
        // value (which uses `lastActiveAt` for LRU).
        var ops: [PersistOp] = sessions.map { .snapshot($0.with(savedAt: saveTime)) }
        if !indexWriteBlocked {
            let entries = sessions.map { s in
                SessionIndex.Entry(
                    id: s.id,
                    rootPath: s.sidebarRootPath ?? "",
                    displayName: s.displayName,
                    lastActiveAt: s.lastActiveAt
                )
            }
            ops.append(.index(SessionIndex(sessions: entries, lastActiveID: activeID)))
        }
        return ops
    }

    /// Write every per-session snapshot then the index through the coalescing
    /// write queue, in the crash-safe order (see `persistPlan`). Returns
    /// immediately.
    private func persist() {
        for op in Self.persistPlan(
            sessions: sessions, activeID: activeID,
            indexWriteBlocked: indexWriteBlocked, saveTime: Date()
        ) {
            switch op {
            case .snapshot(let s): store.enqueueSave(s)
            case .index(let idx): store.enqueueSaveIndex(idx)
            }
        }
    }

    private func touched(_ s: SessionSnapshot, at when: Date = Date()) -> SessionSnapshot {
        s.with(lastActiveAt: when)
    }
}
