import Combine
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

    private var cancellables: Set<AnyCancellable> = []

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
        wireForwarding()
    }

    /// Re-publish any change in the wrapped `DocumentModel` as a
    /// change on this `SessionState`. Without this, SwiftUI views
    /// that observe SessionState (the outer strip's `@ObservedObject`)
    /// won't re-render when DocumentModel emits — same SwiftUI gotcha
    /// LESSONS.md "SwiftUI child-ObservableObject changes don't
    /// propagate" calls out for SidebarModel.
    private func wireForwarding() {
        model.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

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
        if let target = snapshot.selectedTabIndex,
           model.tabs.tabs.indices.contains(target) {
            model.selectTab(at: target)
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
