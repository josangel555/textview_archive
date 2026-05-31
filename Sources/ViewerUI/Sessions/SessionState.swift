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
        SessionSnapshot(
            schemaVersion: SessionSnapshot.currentSchema,
            savedAt: Date(),
            id: id,
            displayName: displayName,
            createdAt: createdAt,
            lastActiveAt: lastActiveAt,
            sidebarRootPath: model.sidebar.rootURL?.path
                ?? rootURL.path,
            openTabs: model.tabs.tabs.compactMap { t in
                guard let url = t.url else { return nil }
                return TabSnapshot(path: url.path,
                                   viewMode: t.viewMode.rawValue)
            },
            selectedTabIndex: model.tabs.selectedIndex,
            sidebarExpandedPaths: nil,
            sidebarIncludeHidden: nil,
            splitURL: nil,
            zoom: model.zoom,
            wordWrap: model.sourceWordWrap,
            themeOverride: model.themeOverride?.rawValue
        )
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
        for t in snapshot.openTabs {
            let url = URL(fileURLWithPath: t.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            let mode = ViewMode(rawValue: t.viewMode)
                ?? ViewModeOptions.defaultMode(for: url)
            model.appendLazyTab(url: url, viewMode: mode)
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
