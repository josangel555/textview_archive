import Combine
import Foundation
import ViewerCore
import ViewerKit

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
    /// `SessionSnapshot`. The coordinator persists the result. Phase
    /// 1 mirrors the existing `WorkspaceSnapshot` field set; new
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
    /// Mirrors the existing `restoreWorkspaceAutoSlot` path, but
    /// keyed off the session's persisted snapshot instead of
    /// `_last.json`.
    ///
    /// Phase 1 reuses `DocumentModel.restoreWorkspaceAutoSlot` for
    /// the actual restore work by *temporarily* projecting the
    /// snapshot back to a `WorkspaceSnapshot` shape on disk. That
    /// indirection is gone in Phase 2 when `DocumentModel` gains a
    /// session-aware restore entry point. For now it keeps the
    /// Phase-1 diff against `DocumentModel` minimal.
    public func hydrate(from snapshot: SessionSnapshot) {
        // Set sidebar root first so any subsequent tab open doesn't
        // implicitly reset it.
        if let rootPath = snapshot.sidebarRootPath {
            let url = URL(fileURLWithPath: rootPath)
            if FileManager.default.fileExists(atPath: url.path) {
                model.openFolder(url)
            }
        }
        // Lazy-restore the tab list. The model's existing
        // `restoreWorkspaceAutoSlot` does this against a legacy
        // snapshot on disk; for phase 1 we write a one-shot legacy
        // file in a tmp location and call that path, so we don't
        // duplicate the lazy-tab logic.
        let legacy = snapshot.toLegacyWorkspaceSnapshot()
        SessionStateRestoreBridge.restoreInto(model: model, legacy: legacy)
    }

    /// Best-effort display name from a folder URL. The last path
    /// component is the natural pick; falls back to "Untitled" when
    /// the URL is the root (`/`) or empty.
    public static func defaultDisplayName(for url: URL) -> String {
        let last = url.lastPathComponent
        return last.isEmpty ? "Untitled" : last
    }
}

/// Tiny helper so `SessionState.hydrate` doesn't duplicate the lazy
/// tab-restore logic that lives on `DocumentModel`. Writes a
/// per-call temporary `_last.json` and calls the model's existing
/// restore method. This is Phase-1 expedience — Phase 2 will route
/// directly through a session-aware restore on DocumentModel.
@MainActor
enum SessionStateRestoreBridge {
    static func restoreInto(model: DocumentModel, legacy: WorkspaceSnapshot) {
        // Render the legacy snapshot into an in-memory ad-hoc file so
        // the existing restore path picks it up. We can't simply call
        // a private path on DocumentModel from here without expanding
        // its API surface; the throwaway file is the smallest seam.
        //
        // Note: we can't reuse `WorkspaceStore.defaultDirectory()/_last.json`
        // because that's the global compat slot — overwriting it would
        // race with `saveWorkspaceAutoSlot` (the bridge writer). A
        // per-session tmp file in the per-user `temporaryDirectory`
        // sidesteps that entirely.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "mdv-session-restore-\(UUID().uuidString).json"
            )
        guard JSONFileStore.write(legacy, to: tmp) else { return }
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Read it back via the model's stock path. We do a direct
        // load-and-apply by routing through a TempWorkspaceStore
        // shape rather than touching the real `_last.json`.
        if let snap = JSONFileStore.read(WorkspaceSnapshot.self, from: tmp) {
            applyLegacySnapshot(snap, to: model)
        }
    }

    /// Apply a legacy WorkspaceSnapshot's contents to a DocumentModel.
    /// Mirrors `DocumentModel.restoreWorkspaceAutoSlot()` minus the
    /// `_last.json` read step — we already have the value in hand.
    private static func applyLegacySnapshot(_ snap: WorkspaceSnapshot,
                                            to model: DocumentModel) {
        if let root = snap.sidebarRootPath {
            let url = URL(fileURLWithPath: root)
            if FileManager.default.fileExists(atPath: url.path) {
                model.sidebar.setRoot(url)
            }
        }
        for t in snap.openTabs {
            let url = URL(fileURLWithPath: t.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            let mode = ViewMode(rawValue: t.viewMode)
                ?? ViewModeOptions.defaultMode(for: url)
            model.appendLazyTab(url: url, viewMode: mode)
        }
        if let zoom = snap.zoom { model.zoom = zoom }
        if let wrap = snap.wordWrap { model.sourceWordWrap = wrap }
        if let theme = snap.themeOverride {
            model.themeOverride = SyntaxTheme.Name(rawValue: theme)
        }
        let target = snap.selectedTabIndex ?? 0
        if model.tabs.tabs.indices.contains(target) {
            model.selectTab(at: target)
        }
    }
}
