import Combine
import Foundation
import ViewerCore
import ViewerKit

/// Phase-1 app-level coordinator. Sits in `ViewerUI` and owns:
///
///   - The value-level `SessionsCoordinator` from `ViewerCore`, which
///     holds the canonical session list + activeID + persistence.
///   - The single `SessionState` instance for the active session
///     (Phase 1 has at most one mounted SessionState at any time;
///     Phase 2 will hold a dictionary keyed by session UUID).
///
/// **Phase-1 façade trick (§3.5)**: every `SessionState` wraps the
/// *same* singleton `DocumentModel`. There's only one mounted session
/// at a time and the UI's `ContentView` is bound to that singleton at
/// app launch. Opening a different folder is implemented as
/// `model.openFolder(newURL)` against the existing DocumentModel,
/// plus a coordinator-side session swap. The DocumentModel reference
/// never changes — SwiftUI views never need a re-mount.
///
/// Phase 2 will replace this with a per-session DocumentModel
/// dictionary; the `Lifecycle` seam is already in place.
@MainActor
public final class SessionsAppCoordinator: ObservableObject {

    /// The shared `DocumentModel` (Phase 1: one for the whole app).
    public let model: DocumentModel

    /// The value-level coordinator (canonical session list +
    /// persistence). Exposed for UI binding (`@ObservedObject`).
    public let core: SessionsCoordinator

    /// The currently-mounted session state. Phase 1: nil only when
    /// the user has zero sessions (fresh install, never opened a
    /// folder).
    @Published public private(set) var active: SessionState?

    private let store: SessionStore
    private let workspace: WorkspaceStore
    private let initialRoot: URL?
    private var lifecycleBridge: LifecycleBridge?

    public init(model: DocumentModel,
                store: SessionStore = SessionStore(),
                workspace: WorkspaceStore = WorkspaceStore(),
                initialRoot: URL? = nil) {
        self.model = model
        self.store = store
        self.workspace = workspace
        self.core = SessionsCoordinator(store: store)
        self.initialRoot = initialRoot
    }

    /// Boot the coordinator. Call exactly once from
    /// `applicationDidFinishLaunching`, before the SwiftUI hosting
    /// controller is shown.
    ///
    /// Order:
    ///   1. Wire the lifecycle bridge so subsequent mount/detach
    ///      calls reach our SessionState.
    ///   2. Try restoring from `Sessions/index.json`. If present,
    ///      mount the active session.
    ///   3. Otherwise migrate from legacy `Workspaces/_last.json`
    ///      → create a "Default" session.
    ///   4. Otherwise (fresh user) seed from `initialRoot` if it
    ///      points at an existing folder.
    public func bootstrap() {
        let bridge = LifecycleBridge(owner: self)
        lifecycleBridge = bridge
        core.setLifecycle(bridge)

        // 1. Try the v2 session store first.
        core.restore()
        if let activeSnap = core.active {
            mountSession(from: activeSnap, hydrate: .fromSession(activeSnap))
            store.emptyTrashOlderThan(30)
            return
        }

        // 2. No v2 state. Try migrating legacy _last.json.
        if let legacy = workspace.loadAutoSlot() {
            let migrated = SessionSnapshot.fromLegacy(legacy)
            store.saveSync(migrated)
            store.saveIndexSync(SessionIndex(
                sessions: [
                    .init(id: migrated.id,
                          rootPath: migrated.sidebarRootPath ?? "",
                          displayName: migrated.displayName,
                          lastActiveAt: migrated.lastActiveAt)
                ],
                lastActiveID: migrated.id
            ))
            // Replay restore so coordinator state + lifecycle fire.
            // The lifecycle bridge picks up the mount and would build
            // a SessionState; we suppress that during the replay so
            // we can hydrate explicitly from the legacy snapshot.
            suppressNextMount = true
            core.restore()
            suppressNextMount = false
            if let snap = core.active {
                mountSession(from: snap, hydrate: .fromLegacy(legacy))
            }
            store.emptyTrashOlderThan(30)
            return
        }

        // 3. Fresh user. If we have an initialRoot from prefs, seed
        //    a session. Otherwise leave the strip empty.
        if let root = initialRoot,
           FileManager.default.fileExists(atPath: root.path),
           !DocumentModel.isUnderTCCProtectedRoot(root) {
            // openFolder fires the lifecycle bridge which builds the
            // SessionState. The wrapped DocumentModel calls openFolder
            // through the mount step.
            core.openFolder(root)
        }
        store.emptyTrashOlderThan(30)
    }

    /// Open a folder as a session — reveal existing if path matches,
    /// else create a new session.
    public func openFolder(_ url: URL, forceNew: Bool = false) {
        core.openFolder(url, forceNew: forceNew)
    }

    public func activate(id: UUID) { core.activate(id: id) }
    public func activate(index n: Int) { core.activate(index: n) }
    public func nextSession()     { core.nextSession() }
    public func previousSession() { core.previousSession() }

    /// Close a session by id (no-op if unknown). Routes through the
    /// core coordinator so the trash + persist + LRU re-activation
    /// pipeline runs as for any other close.
    public func close(id: UUID) { core.close(id: id) }

    /// Close every session except `id`. Surface for the session-tab
    /// context menu's "Close Other Sessions" item.
    public func closeOthers(except id: UUID) { core.closeOthers(except: id) }

    /// Rename a session. Trims whitespace and ignores no-op or empty
    /// updates so a stray Enter on the inline editor doesn't clobber
    /// the existing name. Persists through the coalescing write queue.
    public func rename(id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        core.updateSession(id: id) { snap in
            guard snap.displayName != trimmed else { return }
            snap = SessionSnapshot(
                schemaVersion: snap.schemaVersion,
                savedAt: snap.savedAt,
                id: snap.id,
                displayName: trimmed,
                createdAt: snap.createdAt,
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
        }
    }

    /// Close the currently-active session. Phase 1: if it was the
    /// only session, the strip drops to its empty state (no
    /// SessionState; `model` is left as-is but stale-looking).
    public func closeActive() {
        guard let id = core.activeID else { return }
        core.close(id: id)
    }

    /// Force a synchronous write of the active session's state and
    /// drain the persistence queue. Call from
    /// `applicationWillTerminate` so we exit with everything on
    /// disk. Also writes a legacy `_last.json` bridge for one
    /// release so a downgrade keeps user state (design §8.3).
    public func flushForTermination() {
        if let active {
            let snap = active.makeSnapshot()
            core.replaceSnapshot(id: active.id, with: snap)
            let legacy = snap.toLegacyWorkspaceSnapshot()
            workspace.saveAutoSlot(legacy)
        }
        core.flushPersistenceSync()
    }

    // MARK: - private

    private enum HydrateSource {
        case fromSession(SessionSnapshot)
        case fromLegacy(WorkspaceSnapshot)
        case skip
    }

    /// If true, the *next* mount call from the bridge is dropped on
    /// the floor. Used by the migration path so a restore-replay
    /// doesn't double-hydrate the DocumentModel.
    private var suppressNextMount: Bool = false

    /// Build a fresh `SessionState` for `snap` against the shared
    /// `model`, hydrate the model if requested, and mount.
    private func mountSession(from snap: SessionSnapshot,
                              hydrate source: HydrateSource) {
        // Phase 1: detach the outgoing session (if any) first —
        // this enforces design-doc gap #2 (detach-before-mount).
        active?.detach()
        let rootURL: URL = {
            if let p = snap.sidebarRootPath, !p.isEmpty {
                return URL(fileURLWithPath: p)
            }
            return URL(fileURLWithPath: NSHomeDirectory())
        }()
        let state = SessionState(
            id: snap.id,
            rootURL: rootURL,
            displayName: snap.displayName,
            createdAt: snap.createdAt,
            lastActiveAt: snap.lastActiveAt,
            model: model
        )
        switch source {
        case .fromSession(let s):
            state.hydrate(from: s)
        case .fromLegacy(let l):
            state.hydrate(from: SessionSnapshot.fromLegacy(l))
        case .skip:
            // No hydration: caller (e.g. openFolder for a fresh
            // folder) will populate the model directly.
            break
        }
        state.mount()
        active = state
    }

    /// Switch the active SessionState to point at `snap` without
    /// replacing the shared `DocumentModel`. Used when the
    /// coordinator opens a new folder: we re-run `openFolder` on the
    /// existing DocumentModel and just update the session-identity
    /// wrapper.
    ///
    /// Phase 1 simplification: this drops any in-memory tabs from
    /// the previous session (the DocumentModel's tab list is the
    /// new session's, not the old one's). That matches the
    /// "one-slot" Phase-1 acceptance criterion. Phase 2 will replace
    /// the singleton DocumentModel with a per-session one.
    private func switchSessionFaçade(to snap: SessionSnapshot) {
        active?.detach()
        // Open the new folder on the shared DocumentModel so the
        // sidebar/tabs reflect the new session. This is the
        // "façade trick" — the model never changes identity.
        if let p = snap.sidebarRootPath, !p.isEmpty {
            let url = URL(fileURLWithPath: p)
            if FileManager.default.fileExists(atPath: url.path),
               !DocumentModel.isUnderTCCProtectedRoot(url) {
                model.openFolder(url)
            }
        }
        // Drop old tabs so the user doesn't see leftover state from
        // the previous session. (Phase 2 will isolate tabs per
        // session.)
        while !model.tabs.tabs.isEmpty {
            model.closeTab(at: 0)
        }
        let rootURL: URL = {
            if let p = snap.sidebarRootPath, !p.isEmpty {
                return URL(fileURLWithPath: p)
            }
            return URL(fileURLWithPath: NSHomeDirectory())
        }()
        let state = SessionState(
            id: snap.id,
            rootURL: rootURL,
            displayName: snap.displayName,
            createdAt: snap.createdAt,
            lastActiveAt: snap.lastActiveAt,
            model: model
        )
        state.mount()
        active = state
    }

    // MARK: Lifecycle bridge -----------------------------------------

    @MainActor
    private final class LifecycleBridge: SessionsCoordinator.Lifecycle {
        weak var owner: SessionsAppCoordinator?
        init(owner: SessionsAppCoordinator) { self.owner = owner }

        func mount(_ session: SessionSnapshot) {
            guard let owner else { return }
            if owner.suppressNextMount {
                owner.suppressNextMount = false
                return
            }
            // If we already track this exact session, just remount it
            // (re-enable the file watcher).
            if let active = owner.active, active.id == session.id {
                active.mount()
                return
            }
            // Phase 1: there is at most one slot. New session →
            // façade-swap onto the shared DocumentModel.
            //
            // Hydrate path: if a v2 snapshot file exists for this
            // session (restore case), hydrate from it. Otherwise the
            // caller is openFolder for a fresh URL and the model is
            // already openFolder'd via switchSessionFaçade.
            if owner.active == nil {
                owner.mountSession(from: session, hydrate: .fromSession(session))
            } else {
                owner.switchSessionFaçade(to: session)
            }
        }

        func detach(_ session: SessionSnapshot) {
            guard let owner, let active = owner.active,
                  active.id == session.id else { return }
            active.detach()
        }
    }
}
