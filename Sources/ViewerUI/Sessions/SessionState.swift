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

    public init(id: UUID = UUID(),
                rootURL: URL,
                displayName: String? = nil,
                createdAt: Date = Date(),
                lastActiveAt: Date = Date(),
                model: DocumentModel = DocumentModel()) {
        self.id = id
        self.rootURL = rootURL
        self.displayName = displayName ?? Self.defaultDisplayName(for: rootURL)
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
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
    /// `SessionSnapshot`. The coordinator persists the result. New
    /// session-scoped fields (sidebar expansion, split URL) land
    /// over Phase 1.5 / Phase 2 as `DocumentModel` exposes the
    /// underlying state.
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
            sidebarExpandedPaths: nil,
            sidebarIncludeHidden: nil,
            splitURL: nil,
            zoom: model.zoom,
            wordWrap: model.sourceWordWrap,
            themeOverride: model.themeOverride?.rawValue
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
                categoryOverride: t.categoryOverride?.rawValue))
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
    /// yesterday don't read 15 files at launch — only the focused
    /// one) + zoom / wrap / theme overrides.
    public func hydrate(from snapshot: SessionSnapshot) {
        // Set sidebar root first so any subsequent tab open doesn't
        // implicitly reset it.
        if let rootPath = snapshot.sidebarRootPath {
            let url = URL(fileURLWithPath: rootPath)
            if FileManager.default.fileExists(atPath: url.path) {
                model.sidebar.setRoot(url)
            }
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
        for t in restoreTabs {
            let url = URL(fileURLWithPath: t.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            let override = overrideByPath[t.path]
            let mode = ViewMode(rawValue: t.viewMode)
                ?? ViewModeOptions.defaultMode(for: url, forcedCategory: override)
            model.appendLazyTab(url: url, viewMode: mode, categoryOverride: override)
        }
        if let zoom = snapshot.zoom { model.zoom = zoom }
        if let wrap = snapshot.wordWrap { model.sourceWordWrap = wrap }
        if let theme = snapshot.themeOverride {
            model.themeOverride = SyntaxTheme.Name(rawValue: theme)
        }
        // Distinguish nil (deliberate "no selection persisted") from 0
        // (first tab). Previously nil collapsed to 0 and restoring a
        // session with an explicit empty selection refocused tab 0
        // anyway.
        //
        // Select by matching the resolved path against the surviving
        // (compacted) tab list — never by the stale persisted index.
        // If the target tab's own file was the one that went missing,
        // there's nothing to re-focus; `appendLazyTab` already left the
        // first surviving tab selected, which is the sensible fallback.
        if let targetPath,
           let liveIndex = model.tabs.tabs.firstIndex(
               where: { $0.url?.path == targetPath }) {
            model.selectTab(at: liveIndex)
        }
    }

    /// Best-effort display name from a folder URL. The last path
    /// component is the natural pick; falls back to "Untitled" when
    /// the URL is the root (`/`) or empty. URL.lastPathComponent
    /// returns "/" for the root, not the empty string — handle both.
    public static func defaultDisplayName(for url: URL) -> String {
        let last = url.lastPathComponent
        if last.isEmpty || last == "/" { return "Untitled" }
        return last
    }
}
