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
    private let initialRoot: URL?
    private var lifecycleBridge: LifecycleBridge?

    /// One-shot gate: armed when a brand-new session is spawned via
    /// `openFolder(forceNew: true)`; consumed by the view layer on
    /// next paint to auto-present the Go-to-path prompt. See
    /// `FirstPaintGoToGate` for the pure-logic semantics + tests.
    ///
    /// Published as a token (`UUID`) bumped on each arm so SwiftUI
    /// views observing `@Published` get a re-render signal — a plain
    /// `isArmed` bool wouldn't trigger a re-fire if armed twice in
    /// succession after a take.
    @Published public private(set) var firstPaintGoToToken: UUID? = nil
    private var firstPaintGate = FirstPaintGoToGate()

    public init(model: DocumentModel,
                store: SessionStore = SessionStore(),
                initialRoot: URL? = nil) {
        self.model = model
        self.store = store
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
    ///   3. Otherwise (fresh user) seed from `initialRoot` if it
    ///      points at an existing folder.
    ///
    /// Note: the legacy `Workspaces/_last.json` migration path was
    /// retired in decision G (2026-05-25) — `SessionStore` is the
    /// only on-disk shape.
    public func bootstrap() {
        let bridge = LifecycleBridge(owner: self)
        lifecycleBridge = bridge
        core.setLifecycle(bridge)

        // 1. Try the v2 session store.
        core.restore()
        if let activeSnap = core.active {
            mountSession(from: activeSnap, hydrate: .fromSession(activeSnap))
            store.emptyTrashOlderThan(30)
            return
        }

        // 2. Fresh user. If we have an initialRoot from prefs, seed
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
    /// else create a new session. When `forceNew` is true, also arms
    /// the first-paint Go-to-path gate so the view layer can present
    /// the prompt as the empty-session entry point.
    public func openFolder(_ url: URL, forceNew: Bool = false) {
        firstPaintGate.recordOpenFolder(forceNew: forceNew)
        if forceNew, firstPaintGate.isArmed {
            firstPaintGoToToken = UUID()
        }
        core.openFolder(url, forceNew: forceNew)
    }

    public func activate(id: UUID) {
        firstPaintGate.recordActivate(id: id)
        core.activate(id: id)
    }
    public func activate(index n: Int) { core.activate(index: n) }
    public func nextSession()     { core.nextSession() }
    public func previousSession() { core.previousSession() }

    /// Arm the first-paint Go-to-path gate without yet creating a
    /// session. Called by the SessionTabBar `+` button so the empty-
    /// session entry point is the prompt itself (in which the user
    /// types a path or clicks "Open System Dialog…"). The new session
    /// is created downstream when the user picks a folder.
    public func requestNewSessionViaGoTo() {
        firstPaintGate = FirstPaintGoToGate(isArmed: true)
        firstPaintGoToToken = UUID()
    }

    /// Consume the gate (read+clear). Returns `true` exactly once
    /// after each arm. Exposed for the view layer's `onChange` hook.
    public func consumeFirstPaintGoTo() -> Bool {
        firstPaintGate.take()
    }

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
    /// disk. The legacy `_last.json` bridge writeback was retired in
    /// decision G (2026-05-25).
    public func flushForTermination() {
        if let active {
            let snap = active.makeSnapshot()
            core.replaceSnapshot(id: active.id, with: snap)
        }
        core.flushPersistenceSync()
    }

    // MARK: - private

    private enum HydrateSource {
        case fromSession(SessionSnapshot)
        case skip
    }

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
        // Drop old tabs so the incoming hydrate starts from a clean
        // slate; otherwise the outgoing session's tabs would survive
        // when the incoming snapshot has fewer (or none).
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
        // Hydrate BEFORE mount so the file watcher resumes against the
        // restored selected tab. Hydrate handles sidebar root, tab list,
        // selected index, zoom, word-wrap, theme — all the per-session
        // surface the user can change.
        state.hydrate(from: snap)
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
            // Persist the outgoing session's *live* state (tab list,
            // sidebar root, zoom, etc.) before pausing the watcher.
            // Without this, the persisted snapshot stays frozen at
            // bootstrap, so coming back to this session via activate(id:)
            // hydrates from a stale empty-tabs snapshot — the user
            // experiences this as "my tabs disappeared on switch".
            let snap = active.makeSnapshot()
            owner.core.replaceSnapshot(id: active.id, with: snap)
            active.detach()
        }
    }
}
