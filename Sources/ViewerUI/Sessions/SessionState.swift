import Foundation
import ViewerCore
import ViewerKit

// MARK: - SessionState
//
// Session façade over a single `DocumentModel`. Decision G
// (2026-05-25): the legacy `WorkspaceStore` migration bridge that used
// to live in this file was retired with the rest of the `Workspace*`
// surface; hydration now reads `SessionSnapshot` directly.

/// Phase-1 façade variant of `SessionState`. Wraps a single
/// `DocumentModel` instance and exposes the lifecycle hooks
/// (`mount` / `detach`) that drive the file watcher's
/// pause/resume.
///
/// The deeper Phase-2 refactor extracts per-cluster child models
/// (`FindModel`, `GitPanelModel`, …) onto this type. Until then,
/// `SessionState` is a thin wrapper whose only job is:
///
///   1. Hold a `DocumentModel` per session.
///   2. Carry the session identity / displayName / timestamps.
///   3. Translate coordinator-driven mount/detach into
///      `DocumentModel.pauseFileWatcher()` / `resumeFileWatcher()`.
///   4. Serialize `DocumentModel` state into a `SessionSnapshot`
///      so the value-level coordinator can persist it.
///
/// `@MainActor` because everything it touches is.
@MainActor
public final class SessionState: ObservableObject {

    public let id: UUID
    @Published public var rootURL: URL
    @Published public var displayName: String
    /// TSK-1016: `true` once the user MANUALLY renamed this session (inline tab
    /// editor or "Rename Session…"). A manual rename wins and is never
    /// clobbered by a later root change. When `false`, `makeSnapshot()`
    /// auto-relabels the tab to the current root folder name on a root change.
    /// Persisted via `SessionSnapshot.displayNameIsUserSet` so the manual name
    /// survives a session switch / relaunch; restored on `hydrate`.
    @Published public var displayNameIsUserSet: Bool
    public let createdAt: Date
    @Published public var lastActiveAt: Date

    /// Phase-1: one `DocumentModel` per session. Phase-2 will split
    /// this into child models hung directly off `SessionState`.
    public let model: DocumentModel

    /// True iff this session is currently the active one (i.e. its
    /// view subtree is mounted and the file watcher is live). Owned
    /// by the coordinator-facing bridge; read by SwiftUI views that
    /// want to gray out an inactive session's strip cell.
    @Published public private(set) var isMounted: Bool = false

    /// What kind of session this is (project / code review / CI-CD /
    /// metrics). Drives the SEED-ONCE per-kind default panel layout on
    /// creation — it is NOT a live override (changing it later does not
    /// re-impose a layout; the user's subsequent layout edits win). `nil`
    /// = the plain "project" default for legacy / unseeded sessions.
    /// Persisted additively-optionally as `sessionType` in the snapshot.
    public var sessionType: SessionKind?

    public init(id: UUID = UUID(),
                rootURL: URL,
                displayName: String? = nil,
                displayNameIsUserSet: Bool = false,
                createdAt: Date = Date(),
                lastActiveAt: Date = Date(),
                sessionType: SessionKind? = nil,
                model: DocumentModel = DocumentModel()) {
        self.id = id
        self.rootURL = rootURL
        self.displayName = displayName ?? Self.defaultDisplayName(for: rootURL)
        self.displayNameIsUserSet = displayNameIsUserSet
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
        self.sessionType = sessionType
        self.model = model
    }

    // NOTE (REPUB-1, 2026-05-30): we deliberately do NOT forward
    // `model.objectWillChange` into `SessionState.objectWillChange`.
    // That child→parent republish was the exact anti-pattern LESSONS.md
    // ("SwiftUI republish forwarding amplifies every tick") was written
    // to kill: every DocumentModel tick (keystroke, FS event, git poll,
    // highlight-ready) would republish the whole SessionState graph.
    //
    // It's also dead weight here: the session strip (`SessionTabBar`)
    // observes the value-level `SessionsCoordinator.sessions` snapshots,
    // and `ContentView` observes the `DocumentModel` directly — nothing
    // binds `@ObservedObject` to a `SessionState`. `SessionState`'s own
    // identity/lifecycle fields (`displayName`, `rootURL`,
    // `lastActiveAt`, `isMounted`) are already `@Published`, so a view
    // that *does* observe SessionState in the future re-renders on those
    // without dragging in the full model. If a future strip cell needs a
    // specific DocumentModel-derived field, expose a narrow `@Published`
    // mirror with an equality guard rather than re-wiring this forward.

    /// Detach the session: stop the file watcher so background
    /// reloads don't fire for a session the user isn't looking at.
    /// Caches and `@Published` state remain warm, so re-mount is
    /// instant. Idempotent.
    public func detach() {
        guard isMounted else { return }
        model.pauseFileWatcher()
        isMounted = false
    }

    /// Mount the session: re-attach the file watcher to the
    /// currently-focused tab. Idempotent.
    public func mount() {
        guard !isMounted else { return }
        model.resumeFileWatcher()
        isMounted = true
        lastActiveAt = Date()
    }

    /// Serialize the live `DocumentModel` state into a
    /// `SessionSnapshot`. The coordinator persists the result.
    ///
    /// SESSION-INDEPENDENCE (#184): the per-session surface now includes
    /// the sidebar expansion set, the include-hidden toggle, the split
    /// pane URL, and the shoulder-rail panel layout — all of which used
    /// to be hard-coded `nil` here (and `panelLayout` lived in the GLOBAL
    /// UserDefaults), so switching/relaunching a session silently reset
    /// them. They're now captured per-session.
    ///
    /// GLOBAL (owner LOCKED, #184): `zoom`, `wordWrap`, `themeOverride`
    /// are app-wide, NOT per-session. We deliberately write `nil` for
    /// them so a session switch / relaunch never imposes one project's
    /// zoom/wrap/theme on the app. `zoom`/`wordWrap` already persist to
    /// the global `PreferencesStore`; `themeOverride` is an app-wide
    /// in-memory toggle. The snapshot fields remain in the schema purely
    /// for downgrade-safe decoding of pre-#184 files (additive-optional,
    /// never re-written).
    public func makeSnapshot() -> SessionSnapshot {
        // Dedup defensively on the WRITE side too (matches the restore read
        // side). Once `appendLazyTab` is idempotent the live list can't carry
        // dupes — but serializing through the dedup makes a snapshot that
        // ALREADY grew huge on a pre-fix build heal to its unique set on the
        // next write instead of being re-persisted at full bloat. This is the
        // path that shrinks the owner's 317 KB / 1951-tab file back to ~35
        // entries. We remap `selectedTabIndex` onto the deduped list so the
        // persisted index stays consistent with the persisted `openTabs`
        // (restore re-resolves selection by path anyway, but a coherent index
        // avoids a one-launch off-by selection while the file heals).
        let (openTabs, selectedIndex) = SessionState.dedupedSnapshotTabs(
            from: model.tabs.tabs,
            selectedIndex: model.tabs.selectedIndex
        )
        // Sort the expanded paths so the persisted blob is stable across
        // writes (Set iteration order is unspecified) — otherwise the
        // autosave equality guard would see a "change" on every tick.
        let expandedPaths = model.sidebar.expanded
            .map { $0.path }
            .sorted()
        // TSK-1016: the session tab name tracks the CURRENT root folder. The
        // live root can change after init (`DocumentModel.openFolder` /
        // `revealInSidebar` re-root the shared sidebar; the `$rootURL`
        // publisher then triggers this snapshot via the autosave). Re-derive
        // the title from the live root UNLESS the user manually renamed the
        // session. We mutate the @Published `displayName` / `rootURL` here so
        // the SessionTabBar (which observes the value-level snapshot list, fed
        // by this very `makeSnapshot`) relabels live, and so a subsequent
        // `makeSnapshot` sees the already-updated current name.
        let liveRoot = model.sidebar.rootURL ?? rootURL
        if liveRoot != rootURL { rootURL = liveRoot }
        if let relabeled = SessionRename.relabelForRootChange(
            newRoot: liveRoot,
            currentDisplayName: displayName,
            displayNameIsUserSet: displayNameIsUserSet
        ) {
            displayName = relabeled
        }
        return SessionSnapshot(
            schemaVersion: SessionSnapshot.currentSchema,
            savedAt: Date(),
            id: id,
            displayName: displayName,
            createdAt: createdAt,
            lastActiveAt: lastActiveAt,
            sidebarRootPath: model.sidebar.rootURL?.path
                ?? rootURL.path,
            openTabs: openTabs,
            selectedTabIndex: selectedIndex,
            sidebarExpandedPaths: expandedPaths.isEmpty ? nil : expandedPaths,
            // TSK-363: no longer persisted (hidden files are always shown);
            // the Codable field survives only to decode pre-removal JSON.
            sidebarIncludeHidden: nil,
            splitURL: model.tabCoordinator.splitURL?.path,
            sessionType: sessionType?.rawValue,
            panelLayout: model.panelLayout.snapshot(),
            // TSK-1016: persist the user-set flag so a manual rename survives a
            // switch / relaunch. `nil` (omitted) when folder-derived keeps a
            // fresh snapshot byte-identical to pre-TSK-1016 files.
            displayNameIsUserSet: displayNameIsUserSet ? true : nil,
            // GLOBAL (LOCKED): never persisted per-session — see doc above.
            zoom: nil,
            wordWrap: nil,
            themeOverride: nil,
            // I-21 S4b: the editor-pane layout, by path (nil un-split).
            paneLayout: model.tabCoordinator.paneLayoutSnapshot()
        )
    }

    /// Serialize the live tab list into `[TabSnapshot]`, collapsing duplicate
    /// file paths (normalized via `TabsState.dedupKey`, first occurrence wins)
    /// and remapping the live `selectedIndex` onto the resulting compacted
    /// list. Tabs with no URL are dropped (they can't be persisted). Pure /
    /// `nonisolated` so the heavy lifting is testable; the only reason it
    /// lives on `SessionState` is the `@MainActor` `model` accessor in the
    /// caller. Returns the deduped tab snapshots plus the remapped selection.
    nonisolated static func dedupedSnapshotTabs(
        from tabs: [Tab],
        selectedIndex: Int?
    ) -> (tabs: [TabSnapshot], selectedIndex: Int?) {
        var seen = Set<String>()
        var out: [TabSnapshot] = []
        // Map a LIVE tab index → its index in the compacted output, so we can
        // translate `selectedIndex`. A live index that dedups away (a dup of
        // an earlier survivor) maps to that survivor's output slot.
        var liveToOut: [Int: Int] = [:]
        for (liveIdx, t) in tabs.enumerated() {
            guard let url = t.url else { continue }
            let key = TabsState.dedupKey(url).path
            if let firstOut = lastIndexForKey(seen: seen, out: out, key: key) {
                liveToOut[liveIdx] = firstOut
                continue
            }
            seen.insert(key)
            liveToOut[liveIdx] = out.count
            out.append(TabSnapshot(
                path: url.path,
                viewMode: t.viewMode.rawValue,
                // WAVE 2b item 6: persist the per-tab "Open As…" override
                // so the chosen viewer survives a restart. nil → key
                // omitted by the encoder (additive-optional).
                categoryOverride: t.categoryOverride?.rawValue,
                // UX-K (#231): persist the per-file scroll position. Stamped
                // onto the live tab by `DocumentModel.captureScroll` at
                // focus-loss / close boundaries. nil → key omitted.
                scrollTopLine: t.scrollTopLine,
                // TSK-1041: persist the rendered-markdown WebView scroll offset
                // (the third scroll channel). Stamped onto the live tab by the
                // same `captureScroll`; nil → key omitted (additive-optional).
                renderedScrollY: t.renderedScrollY,
                // TSK-718 hot exit: persist unsaved buffer text. Stamped onto
                // the live tab by `captureUnsavedTextForAllTabs` at the
                // snapshot boundary; nil when clean → key omitted.
                unsavedText: t.unsavedText,
                // TSK-1025: persist the (mtime,size) baseline alongside the text.
                unsavedBaseMTime: t.unsavedBaseMTime,
                unsavedBaseSize: t.unsavedBaseSize,
                // TSK-1303: persist the per-image-tab edit state. Stamped onto the
                // live tab by `captureImageEditStateForAllTabs` at the session-switch
                // boundary; nil for a non-image / unedited tab → key omitted.
                imageEditState: t.imageEditState,
                // Hex hot-exit (2026-08-01): stamped by
                // `captureUnsavedHexForAllTabs` at the same boundary.
                unsavedHexBase64: t.unsavedHexBase64,
                // I-19: per-tab split-editing layout survives the switch.
                splitEditing: t.isSplitEditing ? true : nil))
        }
        let remapped: Int? = selectedIndex.flatMap { liveToOut[$0] }
        return (out, remapped)
    }

    /// Helper for `dedupedSnapshotTabs`: find the output slot a previously
    /// seen `key` was written to. Linear scan — `out` is bounded by the unique
    /// file count (tens), so this stays cheap even for a pre-fix bloated input.
    private nonisolated static func lastIndexForKey(
        seen: Set<String>, out: [TabSnapshot], key: String
    ) -> Int? {
        guard seen.contains(key) else { return nil }
        return out.firstIndex { TabsState.dedupKey(URL(fileURLWithPath: $0.path)).path == key }
    }

    /// Hydrate the wrapped `DocumentModel` from a `SessionSnapshot`.
    /// Drives sidebar root + the lazy tab restore (so 15 tabs from
    /// yesterday don't read 15 files at launch — only the focused one) +
    /// the per-session sidebar expansion / include-hidden / split-pane /
    /// shoulder-rail panel layout.
    ///
    /// GLOBAL (owner LOCKED, #184): zoom / wordWrap / themeOverride are
    /// app-wide and are deliberately NOT applied here — restoring a
    /// session must not yank the app's zoom/wrap/theme to whatever that
    /// project last had. They live on `PreferencesStore` (zoom/wrap) and
    /// the app-wide in-memory `themeOverride`.
    public func hydrate(from snapshot: SessionSnapshot) {
        // Restore the session type first so a seed-once decision (which
        // only fires on *creation*, not hydrate) is consistent with the
        // persisted kind.
        if let raw = snapshot.sessionType {
            sessionType = SessionKind(rawValue: raw)
        }
        // TSK-1016: restore the manual-rename flag so a persisted user-chosen
        // name is never auto-relabeled on the next root change. A pre-TSK-1016
        // file (nil) decodes to false = folder-derived (auto-relabel allowed).
        displayNameIsUserSet = snapshot.displayNameIsUserSet ?? false
        // Adopt the persisted display name so the relabel decision compares
        // against the name actually shown for this session (mountSession seeds
        // it from the snapshot too, but switchSessionFaçade rebuilds the state).
        displayName = snapshot.displayName
        // Set sidebar root first so any subsequent tab open doesn't
        // implicitly reset it.
        if let rootPath = snapshot.sidebarRootPath {
            let url = URL(fileURLWithPath: rootPath)
            if FileManager.default.fileExists(atPath: url.path) {
                model.sidebar.setRoot(url)
            }
        }
        // TSK-363: hidden files are ALWAYS shown — the eye toggle is gone,
        // so a persisted `sidebarIncludeHidden: false` from a pre-removal
        // session MUST NOT be honored (there is no button left to undo
        // it). Force-true on hydrate, ignoring the snapshot field; the
        // Codable field survives only for old-JSON decode compat.
        if !model.sidebar.includeHidden {
            model.sidebar.includeHidden = true
        }
        // Restore the per-session shoulder-rail panel layout.
        //
        // FAÇADE LEAK GUARD: Phase-1 shares ONE `DocumentModel` (hence one
        // `PanelLayoutStore`) across all sessions, so switching A→B must
        // RESET the layout, not merely skip when B has none — otherwise
        // A's rails leak into B. We therefore ALWAYS apply: a persisted
        // layout when present, else the kind's default (so an unseeded
        // session lands on its kind template), else the empty/default
        // layout (plain `.project` / legacy). `apply` is equality-guarded,
        // so applying the layout already in place is a no-op republish.
        if let layout = snapshot.panelLayout {
            model.panelLayout.apply(layout)
        } else if let kind = sessionType, kind != .project {
            model.panelLayout.apply(kind.defaultPanelLayout)
        } else {
            // Plain `.project` / legacy session with no persisted layout: open
            // Files-only (owner request 2026-06-20) — a fresh session starts
            // clean, all other tool windows closed. Once the user opens panels,
            // the snapshot persists and takes the branch above on next activation.
            model.panelLayout.apply(.filesOnly)
        }
        // PERSIST-01: `selectedTabIndex` indexes into the *persisted*
        // `openTabs` array, but we skip tabs whose file no longer exists
        // below. Applying the raw index against the compacted live list
        // would select the wrong tab (or none) whenever an earlier tab's
        // file went missing. Resolve the intended target's path up front,
        // then re-find it by path after building the surviving list.
        //
        // Match `appendLazyTab`'s normalization (standardized +
        // symlinks resolved) so the comparison holds even when the
        // session root lives under a symlinked dir (e.g. /tmp, the
        // macOS /var/folders scratch space) — otherwise the live tab's
        // resolved path would never equal the raw persisted path.
        let targetPath: String? = {
            guard let i = snapshot.selectedTabIndex,
                  snapshot.openTabs.indices.contains(i) else { return nil }
            return URL(fileURLWithPath: snapshot.openTabs[i].path)
                .standardizedFileURL.resolvingSymlinksInPath().path
        }()
        // PERSIST-12 (launch-memory fix): collapse duplicate persisted tabs
        // (normalized by path) and clamp to `TabsState.maxRestoredTabs` BEFORE
        // appending. Restore + `makeSnapshot` formed a one-way ratchet that
        // grew an active session to ~2000 tabs / ~35 unique files and pushed
        // launch footprint to ~1 GB. `appendLazyTab` is now idempotent too, so
        // this is belt-and-suspenders — but doing it here also bounds the
        // count (the per-tab guard alone wouldn't cap a list of 2000 *unique*
        // files). Resolving the selected target by PATH (above) stays correct:
        // the cap keeps the tail of the list, which is where the last-focused
        // tab lives. The persisted file on disk is healed on the next clean
        // `makeSnapshot()` write, which now serializes the deduped live list.
        let restoreTabs = TabsState.dedupedRestoreTabs(
            snapshot.openTabs.map { (path: $0.path, viewMode: $0.viewMode) }
        )
        // Path → persisted "Open As…" override (WAVE 2b item 6). An
        // unknown raw string (a future category this build doesn't know)
        // maps back to nil = auto-detect — the downgrade-safe default.
        let overrideByPath: [String: FileCategory] = Dictionary(
            snapshot.openTabs.compactMap { snap -> (String, FileCategory)? in
                guard let raw = snap.categoryOverride,
                      let cat = FileCategory(rawValue: raw) else { return nil }
                return (snap.path, cat)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // UX-K (#231): path → persisted scroll position. Same shape as the
        // override map above. A non-positive / absent value is dropped here
        // (→ nil on append = "restore to top of file").
        let scrollByPath: [String: Int] = Dictionary(
            snapshot.openTabs.compactMap { snap -> (String, Int)? in
                guard let line = snap.scrollTopLine, line > 0 else { return nil }
                return (snap.path, line)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // TSK-1041: path → persisted RENDERED-markdown scroll offset. Same shape
        // as the source-scroll map above. A non-positive / absent value is
        // dropped here (→ nil on append = "render at top").
        let renderedScrollByPath: [String: Double] = Dictionary(
            snapshot.openTabs.compactMap { snap -> (String, Double)? in
                guard let y = snap.renderedScrollY, y > 0 else { return nil }
                return (snap.path, y)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // TSK-718 hot exit: path → persisted unsaved buffer text. Same shape as
        // the maps above. An empty string is dropped (no edits to restore).
        let unsavedByPath: [String: String] = Dictionary(
            snapshot.openTabs.compactMap { snap -> (String, String)? in
                guard let text = snap.unsavedText, !text.isEmpty else { return nil }
                return (snap.path, text)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // TSK-1025: path → the (mtime,size) baseline the unsaved edits were made
        // FROM, so restore seeds the buffer fingerprint + detects an external
        // change. Only meaningful alongside unsavedText.
        let unsavedBaseMTimeByPath: [String: Date] = Dictionary(
            snapshot.openTabs.compactMap { snap -> (String, Date)? in
                guard let m = snap.unsavedBaseMTime else { return nil }
                return (snap.path, m)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let unsavedBaseSizeByPath: [String: Int] = Dictionary(
            snapshot.openTabs.compactMap { snap -> (String, Int)? in
                guard let s = snap.unsavedBaseSize else { return nil }
                return (snap.path, s)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // TSK-1303: path → persisted image-editor edit state, so image edits
        // restore on session switch-back. nil / absent → nothing to restore.
        let imageEditStateByPath: [String: ImageEditState] = Dictionary(
            snapshot.openTabs.compactMap { snap -> (String, ImageEditState)? in
                guard let s = snap.imageEditState else { return nil }
                return (snap.path, s)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // Hex hot-exit (2026-08-01): path → persisted unsaved hex bytes.
        let unsavedHexByPath: [String: String] = Dictionary(
            snapshot.openTabs.compactMap { snap -> (String, String)? in
                guard let b = snap.unsavedHexBase64, !b.isEmpty else { return nil }
                return (snap.path, b)
            },
            uniquingKeysWith: { first, _ in first }
        )
        // I-19: path → the per-tab split-editing layout flag.
        let splitEditingByPath: [String: Bool] = Dictionary(
            snapshot.openTabs.compactMap { snap -> (String, Bool)? in
                guard snap.splitEditing == true else { return nil }
                return (snap.path, true)
            },
            uniquingKeysWith: { first, _ in first }
        )
        for t in restoreTabs {
            let url = URL(fileURLWithPath: t.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            let override = overrideByPath[t.path]
            let mode = ViewMode(rawValue: t.viewMode)
                ?? ViewModeOptions.defaultMode(for: url, forcedCategory: override)
            model.appendLazyTab(url: url, viewMode: mode,
                                categoryOverride: override,
                                scrollTopLine: scrollByPath[t.path],
                                renderedScrollY: renderedScrollByPath[t.path],
                                unsavedText: unsavedByPath[t.path],
                                unsavedBaseMTime: unsavedBaseMTimeByPath[t.path],
                                unsavedBaseSize: unsavedBaseSizeByPath[t.path],
                                imageEditState: imageEditStateByPath[t.path],
                                unsavedHexBase64: unsavedHexByPath[t.path],
                                isSplitEditing: splitEditingByPath[t.path] ?? false)
        }
        // Restore the per-session sidebar expansion AFTER `setRoot`
        // (which wipes `expanded` down to just the root). We expand the
        // ancestors the user had open last time so the tree comes back to
        // the same shape. `toggleExpansion` lazily loads each dir's
        // children, matching the user clicking the disclosure triangle.
        // Skip any persisted path that no longer exists on disk.
        if let expandedPaths = snapshot.sidebarExpandedPaths {
            // Perf P1 (TSK-1040): bound the per-dir readdir storm so the VM
            // trace can size it (each `toggleExpansion` lazily reads a dir on
            // the main thread; scales with how many dirs the user had open).
            let expandToken = PerfSignpost.begin(.interact, "switch.hydrate.expand")
            for p in expandedPaths {
                let url = URL(fileURLWithPath: p)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                if !model.sidebar.isExpanded(url) {
                    model.sidebar.toggleExpansion(url)
                }
            }
            PerfSignpost.end(expandToken)
        }
        // Restore the split pane (per-session). Only if the file still
        // exists — a dangling split URL would render an error pane.
        //
        // FAÇADE LEAK GUARD: explicitly close the split when this session
        // has none, so a switch from a split session to a non-split one
        // doesn't leak the prior split through the shared model.
        if let splitPath = snapshot.splitURL,
           FileManager.default.fileExists(atPath: splitPath) {
            model.openInSplit(URL(fileURLWithPath: splitPath))
        } else if model.splitURL != nil {
            model.closeSplit()
        }
        // GLOBAL (owner LOCKED, #184): zoom / wordWrap / themeOverride are
        // app-wide; intentionally NOT applied from the snapshot. See the
        // `hydrate` doc comment.
        // Distinguish nil (deliberate "no selection persisted") from 0
        // (first tab). Previously nil collapsed to 0 and restoring a
        // session with an explicit empty selection refocused tab 0
        // anyway. The actual focused-tab select (matching by resolved path,
        // never the stale persisted index) is `selectFocusedTabOnSessionSwitch`.
        if let targetPath {
            selectFocusedTabOnSessionSwitch(targetPath: targetPath)
        }
        // I-21 S4b: restore the editor-pane layout LAST — persisted paths
        // resolve to the freshly-minted tab ids, and the focused pane's
        // remembered tab wins the final selection ("split, close, reopen,
        // still see splits").
        if let paneLayout = snapshot.paneLayout {
            model.tabCoordinator.applyPaneLayout(paneLayout)
        }
    }

    /// Focus the surviving tab matching `targetPath` as the FINAL step of a
    /// session activation, marking the switch in-flight around the select.
    ///
    /// Select by matching the resolved path against the surviving (compacted) tab
    /// list — never by the stale persisted index. No-op when the target's own
    /// file went missing (`appendLazyTab` already left the first survivor
    /// selected, the sensible fallback).
    ///
    /// TSK-1047: `model.isSessionSwitchInFlight` is set around the `selectTab` so
    /// the scroll-restore it triggers SKIPS the live-CM6 push — on this path the
    /// editor pane is REBUILT (dismantle→make), so the warm-editor reattach /
    /// once-per-mount seed already restore scroll; a live push would double-apply.
    /// A plain TAB switch never sets this flag (the pane stays mounted, so the
    /// live push is the ONLY thing that re-applies the restored scroll). The flag
    /// is cleared in a `defer` so an early-return / throw can't leave it stuck.
    func selectFocusedTabOnSessionSwitch(targetPath: String) {
        guard let liveIndex = model.tabs.tabs.firstIndex(
            where: { $0.url?.path == targetPath }) else { return }
        // Perf P1 (TSK-1040): bound the focused-tab select path — this is where
        // the incoming tab materializes + (pre-P1) rebuilt its WebView. After the
        // warm-cache fix this re-attaches with no reload.
        let selectToken = PerfSignpost.begin(.interact, "switch.select")
        model.isSessionSwitchInFlight = true
        defer { model.isSessionSwitchInFlight = false }
        model.selectTab(at: liveIndex)
        PerfSignpost.end(selectToken)
    }

    #if DEBUG
    /// Test seam (TSK-1047): drive the exact session-switch focused-tab select
    /// (with its `isSessionSwitchInFlight` lifecycle) so a host test can prove the
    /// gate is set around the select and cleared after — without running the full
    /// `hydrate`.
    func _test_selectFocusedTab(targetPath: String) {
        selectFocusedTabOnSessionSwitch(targetPath: targetPath)
    }
    #endif

    /// SEED-ONCE (#184 scope item 3): if this session was created with a
    /// non-`.project` kind and has NOT yet had its panel layout seeded,
    /// install the kind's default shoulder-rail layout into the live
    /// model. Returns `true` iff it seeded (so the caller can persist the
    /// now-non-nil layout, making the seed stick across relaunch).
    ///
    /// Caller contract: pass `alreadyHasPersistedLayout = snapshot
    /// .panelLayout != nil`. A session whose snapshot already carries a
    /// `panelLayout` was seeded (or hand-edited) on a prior run — we must
    /// NOT re-seed it (that would clobber the user's edits with the kind
    /// default, defeating "seed-once, not a live override").
    ///
    /// `.project` (or nil kind) seeds nothing — its default layout is the
    /// identity (empty overrides), so there's nothing to install and we
    /// keep fresh `.project` snapshots minimal.
    @discardableResult
    public func seedPanelLayoutIfNeeded(alreadyHasPersistedLayout: Bool) -> Bool {
        guard let kind = sessionType, kind != .project,
              !alreadyHasPersistedLayout else { return false }
        let layout = kind.defaultPanelLayout
        guard !layout.isDefault else { return false }
        model.panelLayout.apply(layout)
        return true
    }

    /// Best-effort display name from a folder URL. Delegates to the single
    /// shared derivation in `SessionRename` (TSK-1016) so the new-session title,
    /// the value-level `SessionsCoordinator.openFolder`, and a later
    /// root-change relabel can never diverge. Falls back to "Untitled" for the
    /// root (`/`) or empty URL.
    public static func defaultDisplayName(for url: URL) -> String {
        SessionRename.defaultDisplayName(forRoot: url)
    }
}
