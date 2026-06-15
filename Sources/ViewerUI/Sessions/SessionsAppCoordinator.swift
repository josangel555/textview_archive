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

    // MARK: Incremental / debounced autosave (crash recovery, §5.4) -----
    //
    // The only writers of live tab/sidebar/zoom state used to be the
    // session-switch (`detach`) and clean-quit (`flushForTermination`)
    // edges — so a crash / SIGKILL / force-quit between them lost
    // everything since the last switch or quit. This drives the existing
    // coalescing `enqueueSave` (via `replaceSnapshot`) off a NARROW set of
    // `@Published` streams so a crash recovers the last ~500 ms of state.
    //
    // REPUB-1 discipline: we subscribe to the SPECIFIC publishers that
    // change persisted fields (`tabCoordinator.$tabs`, `sidebar.$rootURL`,
    // `$zoom`/`$sourceWordWrap`/`$themeOverride`) — never `model`'s whole
    // `objectWillChange` firehose (which fires per keystroke / FS event /
    // git poll / highlight-ready). Each tick reschedules a single debounce
    // timer; on fire we make a snapshot and persist ONLY if its persisted
    // content actually changed (equality guard), so a no-op re-publish or a
    // typing storm collapses to at most one write per window.
    private var autosaveCancellables: Set<AnyCancellable> = []
    /// Monotonic token identifying the latest scheduled debounce. A deferred
    /// fire only runs if its token still matches — so a later reschedule (or
    /// an explicit flush) cleanly supersedes an in-flight timer without
    /// relying on DispatchWorkItem cancel semantics.
    private var autosaveToken: UInt64 = 0
    /// True while a debounce is pending — drives the test flush hook.
    private var autosavePending: Bool = false
    /// Session the autosave subscriptions are currently bound to, so a
    /// stale subscription can't snapshot the wrong session into the wrong
    /// file after a switch (Phase-2 per-session-model safety).
    private var autosaveBoundSessionID: UUID?
    /// Last persisted snapshot per session — the equality-guard baseline.
    private var lastPersistedContent: [UUID: SessionSnapshot] = [:]
    /// Debounce window. Injectable so tests can drive it to ~0.
    private let autosaveDebounce: TimeInterval
    /// Periodic safety-net flush (TSK-607). The publisher-driven autosave
    /// above only fires when a SUBSCRIBED field changes — scroll position
    /// deliberately rides the high-frequency `SourceViewChannel` (REPUB-1)
    /// and never ticks it, so "scroll for a while, then crash" lost the
    /// position. This timer runs the SAME equality-guarded `fireAutosave`
    /// every interval, so scroll-only drift reaches disk within one period
    /// while an idle app costs one no-op snapshot+compare per tick.
    /// `<= 0` disables the timer (tests drive `periodicFlushTick()` directly).
    private let periodicFlushInterval: TimeInterval
    private var periodicFlushTimer: Timer?

    public init(model: DocumentModel,
                store: SessionStore = SessionStore(),
                initialRoot: URL? = nil,
                autosaveDebounce: TimeInterval = 0.5,
                periodicFlushInterval: TimeInterval = 30) {
        self.model = model
        self.store = store
        self.core = SessionsCoordinator(store: store)
        self.initialRoot = initialRoot
        self.autosaveDebounce = autosaveDebounce
        self.periodicFlushInterval = periodicFlushInterval
    }

    /// Wire the lifecycle bridge so the value-level coordinator's
    /// mount/detach hooks reach our `SessionState` (which is what
    /// actually re-roots the live sidebar + restores tabs on the shared
    /// `DocumentModel`). Idempotent: re-arming just replaces the bridge.
    ///
    /// Split out of `bootstrap()` (SFB-10) because the bridge is a hard
    /// prerequisite for ANY later session operation — `openFolder`,
    /// `activate`, `close` all fan out through `core`'s `lifecycle?`.
    /// `bootstrap()` itself is gated off under `MDV_SKIP_WORKSPACE_RESTORE=1`
    /// (we don't want test/automation launches to rehydrate the user's
    /// last session), but that flag must NOT also disable the bridge —
    /// otherwise `core.openFolder(forceNew:)`'s `lifecycle?.mount(snap)`
    /// is a nil no-op and the new session never re-roots the sidebar. The
    /// app's `applicationDidFinishLaunching` therefore calls this
    /// unconditionally and only `bootstrap()` behind the flag.
    public func wireLifecycle() {
        let bridge = LifecycleBridge(owner: self)
        lifecycleBridge = bridge
        core.setLifecycle(bridge)
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
        // Idempotent: `wireLifecycle()` is already called unconditionally
        // by the app launch path, but re-wiring here keeps `bootstrap()`
        // self-contained for any direct caller (tests, future entry points).
        wireLifecycle()

        // P3c: trash GC has ZERO first-frame relevance — a directory
        // enumeration + per-file stat + deletes. Defer it OFF the launch
        // critical path to a low-priority detached task so it can't stall
        // first paint. SessionStore is Sendable; the 30-day TTL is in
        // wall-clock days, so running it a beat after launch is identical.
        let store = self.store
        Task.detached(priority: .background) {
            store.emptyTrashOlderThan(30)
        }

        // 1. Try the v2 session store.
        core.restore()
        if let activeSnap = core.active {
            mountSession(from: activeSnap, hydrate: .fromSession(activeSnap))
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
    }

    /// Open a folder as a session — reveal existing if path matches,
    /// else create a new session.
    ///
    /// Every caller of `openFolder(forceNew:)` already supplies a
    /// concrete folder URL ("Open in New Session" passes the right-clicked
    /// node's URL; bootstrap passes the prefs root). The empty-session
    /// entry point that *wants* the Go-to-path prompt uses the dedicated
    /// `requestNewSessionViaGoTo()` instead — it never routes through here.
    /// So arming the first-paint gate on `forceNew` had no legitimate
    /// caller and only produced a spurious GoTo prompt stacked on top of
    /// the just-opened session (bug2). Removed.
    ///
    /// TCC-protected roots (`~/Documents`, `~/Desktop`, `~/Downloads`,
    /// `~/Pictures`, iCloud Drive) ARE allowed here (TSK-599). Every call
    /// into this method is an explicit user gesture — sidebar/bookmark
    /// context menu, the open panel, a script verb, Go-to-path — so a TCC
    /// prompt, if one fires at all, is user-attributable and one-time (the
    /// bundle is signed with a stable identity, so the grant sticks).
    /// The 2026-06-03 blanket guard (SESS-01 harvest) silently swallowed
    /// every open under these roots, which made "Open in New Session" a
    /// total no-op for any workspace under `~/Documents` — no session, no
    /// feedback. The `isUnderTCCProtectedRoot` guard now applies only to
    /// IMPLICIT launch-time touches, where prompting without a gesture is
    /// hostile: the `bootstrap()` prefs seed (guarded above) and
    /// `DocumentModel.restorePreviousFolderIfAvailable`. A session the
    /// user explicitly created under a TCC root persists and restores
    /// like any other — that is the user's standing opt-in.
    public func openFolder(_ url: URL,
                           forceNew: Bool = false,
                           kind: SessionKind? = nil) {
        core.openFolder(url, forceNew: forceNew, kind: kind)
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

    /// TSK-313: double-clicking the empty session-tab-strip area opens a
    /// new session ROOTED AT THE USER'S HOME immediately — the browser
    /// "double-click the strip = new tab" idiom, with ~ as the neutral
    /// starting root (no GoTo prompt; the `+` button keeps the prompt
    /// flow for users who want to type a path). Explicit user gesture,
    /// so the TSK-599 explicit-open TCC contract applies.
    public func openHomeSession() {
        openFolder(FileManager.default.homeDirectoryForCurrentUser, forceNew: true)
    }

    /// TSK-315: tab context menu "Open in New Session" / "Move to New
    /// Session". Creates a NEW session rooted at the file's parent folder
    /// and opens the file in it. With `removingFromCurrent`, the file's
    /// tab is closed in the CURRENT session FIRST, so the outgoing
    /// session's detach-time snapshot no longer contains it — a true
    /// move; the default leaves the source session untouched (a copy-
    /// like open). Explicit user gesture, so the TSK-599 explicit-open
    /// TCC contract applies.
    public func openFileInNewSession(_ fileURL: URL,
                                     removingFromCurrent: Bool = false) {
        if removingFromCurrent,
           let idx = model.tabs.tabs.firstIndex(where: { $0.url == fileURL }) {
            model.closeTab(at: idx)
        }
        _ = core.openFolder(fileURL.deletingLastPathComponent(), forceNew: true)
        model.openPath(fileURL)
    }

    /// TSK-274: drag a document tab onto a session pill — MOVE the file
    /// into that EXISTING session. Resolves the dragged tab id at DROP
    /// time (ids survive reorders; a tab closed mid-drag is a clean
    /// no-op, as is a same-session drop or an untitled tab with no url).
    /// Order matters: close the source tab BEFORE the session swap so
    /// the outgoing session's detach-time snapshot omits it.
    public func moveTab(withID tabID: UUID, toSessionID target: UUID) {
        guard target != core.activeID,
              core.sessions.contains(where: { $0.id == target }),
              let idx = model.tabs.tabs.firstIndex(where: { $0.id == tabID }),
              let url = model.tabs.tabs[idx].url else { return }
        model.closeTab(at: idx)
        activate(id: target)
        model.openPath(url)
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
        // Cheap early-out for the common empty/stray-Enter case; the full
        // trim + no-op rule lives in the host-tested `SessionRename.sanitize`.
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        core.updateSession(id: id) { snap in
            guard let name = SessionRename.sanitize(newName, current: snap.displayName) else { return }
            snap = snap.with(displayName: name)
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
        // Cancel any pending debounce; the explicit snapshot below is the
        // final, authoritative write (don't let a half-window timer race it).
        autosaveToken &+= 1
        autosavePending = false
        if let active {
            // UX-K (#231): final scroll capture before the authoritative quit
            // write so the user's last position is on disk.
            active.model.captureScrollForActiveTab()
            // TSK-718 hot exit: capture unsaved buffers so a quit restores
            // in-flight edits on relaunch.
            active.model.captureUnsavedTextForAllTabs()
            let snap = active.makeSnapshot()
            lastPersistedContent[active.id] = snap
            core.replaceSnapshot(id: active.id, with: snap)
        }
        core.flushPersistenceSync()
    }

    // MARK: - Autosave wiring

    /// Bind the debounced autosave to `state`'s wrapped model. Tears down
    /// any prior binding first so exactly one session is observed at a time
    /// (the Phase-1 façade shares one DocumentModel, but keying the baseline
    /// + bound-id on the session makes this correct once Phase-2 splits into
    /// per-session models). Seeds the equality-guard baseline from the
    /// session's current snapshot so the first idle tick doesn't write a
    /// no-op.
    private func armAutosave(for state: SessionState) {
        disarmAutosave()
        autosaveBoundSessionID = state.id
        // Seed baseline so an immediate re-publish that changes nothing is a
        // no-op. The session was just hydrated/created; its current snapshot
        // matches what `replaceSnapshot` already holds.
        lastPersistedContent[state.id] = state.makeSnapshot()

        let m = state.model
        // Merge the narrow persisted-field publishers. `map { _ in () }`
        // erases the heterogeneous element types into a uniform tick.
        let tabs = m.tabCoordinator.$tabs.map { _ in () }
        let root = m.sidebar.$rootURL.map { _ in () }
        let zoom = m.$zoom.map { _ in () }
        let wrap = m.$sourceWordWrap.map { _ in () }
        let theme = m.$themeOverride.map { _ in () }
        Publishers.MergeMany([
            tabs.eraseToAnyPublisher(),
            root.eraseToAnyPublisher(),
            zoom.eraseToAnyPublisher(),
            wrap.eraseToAnyPublisher(),
            theme.eraseToAnyPublisher(),
        ])
        // Each `@Published` emits its current value on subscribe, so arming
        // produces an initial volley of ticks. We DON'T `dropFirst` them —
        // relying on a publisher-count magic number is brittle. Instead the
        // equality guard in `fireAutosave` makes that initial volley a no-op
        // (the snapshot equals the freshly-seeded baseline), which is the
        // same protection that suppresses any later equal-value re-publish.
        .sink { [weak self] _ in self?.scheduleAutosave() }
        .store(in: &autosaveCancellables)

        // TSK-607: periodic safety-net flush for state that never ticks a
        // subscribed publisher (scroll position rides SourceViewChannel).
        // Same equality-guarded fire — an idle period costs one snapshot
        // compare and zero writes.
        periodicFlushTimer?.invalidate()
        if periodicFlushInterval > 0 {
            let timer = Timer.scheduledTimer(
                withTimeInterval: periodicFlushInterval, repeats: true
            ) { [weak self] _ in
                Task { @MainActor in self?.periodicFlushTick() }
            }
            // .common so it fires while menus / drags are active (same
            // rationale as GitPanelModel's refresh timer).
            RunLoop.main.add(timer, forMode: .common)
            periodicFlushTimer = timer
        }
    }

    /// One periodic safety-net fire (TSK-607). Split from the timer so
    /// tests can drive it without wall-clock waits. Routes through the
    /// SAME `fireAutosave` (scroll sample + equality guard + the single
    /// coalescing write queue) — no parallel writer.
    func periodicFlushTick() {
        fireAutosave()
    }

    /// Cancel the debounce + drop subscriptions. Called on detach / switch.
    private func disarmAutosave() {
        autosaveToken &+= 1   // supersede any in-flight deferred fire
        autosavePending = false
        autosaveCancellables.removeAll()
        autosaveBoundSessionID = nil
        periodicFlushTimer?.invalidate()
        periodicFlushTimer = nil
    }

    /// (Re)schedule the single debounce timer. Coalesces a burst of ticks
    /// into one fire by bumping the token: only the latest deferred block
    /// matches and runs.
    private func scheduleAutosave() {
        autosaveToken &+= 1
        autosavePending = true
        let scheduled = autosaveToken
        DispatchQueue.main.asyncAfter(deadline: .now() + autosaveDebounce) { [weak self] in
            guard let self, self.autosaveToken == scheduled else { return }
            self.autosavePending = false
            self.fireAutosave()
        }
    }

    /// Snapshot the bound session and persist ONLY if its persisted content
    /// changed since the last write (equality guard). Exposed for tests via
    /// `flushAutosaveNow()`.
    private func fireAutosave() {
        guard let id = autosaveBoundSessionID,
              let active, active.id == id else { return }
        // UX-K (#231): sample the active tab's live scroll position into its
        // `Tab` before snapshotting. This runs on the DEBOUNCED autosave fire
        // (and termination / detach below) — never per scroll tick — so the
        // hot path stays clean while a crash still recovers the last position.
        active.model.captureScrollForActiveTab()
        // TSK-718 hot exit: capture unsaved buffer text so an autosave write
        // (which includes the crash-recovery path) persists in-flight edits.
        active.model.captureUnsavedTextForAllTabs()
        let snap = active.makeSnapshot()
        if let prev = lastPersistedContent[id],
           prev.hasSamePersistedContent(as: snap) {
            return  // no persisted change — don't spam the write queue
        }
        lastPersistedContent[id] = snap
        core.replaceSnapshot(id: id, with: snap)
    }

    /// Test hook: run the pending debounced autosave immediately (skipping
    /// the wall-clock wait) so tests can assert the equality-guarded write
    /// without sleeping. No-op if nothing is pending. Bumps the token so the
    /// still-scheduled deferred block becomes a no-op.
    func flushAutosaveNow() {
        guard autosavePending else { return }
        autosaveToken &+= 1
        autosavePending = false
        fireAutosave()
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
            seedSessionType(state, from: s)
        case .skip:
            // No hydration: caller (e.g. openFolder for a fresh
            // folder) will populate the model directly.
            break
        }
        state.mount()
        active = state
        armAutosave(for: state)
    }

    /// SEED-ONCE (#184): apply the session kind's default panel layout on
    /// first mount, then persist the now-non-nil layout so the seed
    /// sticks and never re-fires. Re-seeding is gated on the snapshot
    /// having no persisted `panelLayout` (see `seedPanelLayoutIfNeeded`),
    /// so a subsequent mount — which DOES carry a panelLayout — is a
    /// no-op and the user's later layout edits win.
    private func seedSessionType(_ state: SessionState, from snap: SessionSnapshot) {
        guard state.seedPanelLayoutIfNeeded(
            alreadyHasPersistedLayout: snap.panelLayout != nil
        ) else { return }
        // Persist immediately so the seeded layout survives a crash
        // before the next debounced autosave. The fresh snapshot now
        // carries the non-nil panelLayout, closing the seed gate.
        let seeded = state.makeSnapshot()
        lastPersistedContent[state.id] = seeded
        core.replaceSnapshot(id: state.id, with: seeded)
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
        // selected index, sidebar expansion / include-hidden, the split
        // pane, and the per-session panel layout — all the per-session
        // surface the user can change. (zoom/wrap/theme are GLOBAL, #184.)
        state.hydrate(from: snap)
        seedSessionType(state, from: snap)
        state.mount()
        active = state
        armAutosave(for: state)
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
            // Stop the debounced autosave for the outgoing session before
            // its final detach-time snapshot so a stale timer can't fire a
            // write after we've handed off. The explicit snapshot below is
            // the authoritative final write for this session.
            owner.disarmAutosave()
            // UX-K (#231): capture the active tab's scroll before the outgoing
            // session's authoritative detach-time snapshot, so switching back
            // restores where the user left off.
            active.model.captureScrollForActiveTab()
            // TSK-718 hot exit: capture unsaved buffers on detach so switching
            // sessions (and back) preserves in-flight edits.
            active.model.captureUnsavedTextForAllTabs()
            let snap = active.makeSnapshot()
            owner.lastPersistedContent[active.id] = snap
            owner.core.replaceSnapshot(id: active.id, with: snap)
            active.detach()
        }
    }
}
