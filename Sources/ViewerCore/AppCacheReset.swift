import Foundation

/// Granular "invalidate the things that get stuck" reset, surfaced as
/// **File → Reset** in the app. Motivated by a real failure: the session
/// `index.json` got clobbered to `{"sessions":[]}` while the per-session
/// snapshot files survived, so the session-tab strip rendered empty with no
/// in-app way to recover. This gives the user a targeted escape hatch per
/// persisted store instead of forcing a hand-edit under `~/Library`.
///
/// **Safety: never hard-deletes.** Every target is *moved* into a timestamped
/// backup folder (`_reset-backups/<stamp>/…`), so a mistaken reset is fully
/// recoverable from Finder. The planner (`relativeTargets` / `base`) is pure so
/// it's unit-testable without touching the real Application Support tree; the
/// executor takes explicit base dirs for the same reason.
public enum CacheDomain: String, CaseIterable, Sendable {
    /// Saved sessions: `Sessions/` (index.json + per-session snapshots + trash).
    /// THE one that fixes "I can't see session tabs" — a bad/empty index here
    /// hides the whole strip.
    case sessions
    /// Window/layout workspace state: `Workspaces/_last.json`.
    case workspaces
    /// Pinned bookmarks: `bookmarks.json`.
    case bookmarks
    /// Recent files + go-to-path history: `history.json`, `recent-paths.json`.
    case recents
    /// Language-server on-disk caches (e.g. the Java `jdtls-data/` index — can
    /// grow to thousands of files). Lives under the bundle-id support dir.
    case lspCache

    public var base: AppSupportBase {
        switch self {
        case .lspCache: return .bundleID
        default:        return .markdownViewer
        }
    }

    /// Path components (relative to `base`'s dir) this domain owns. Files OR
    /// directories; the executor removes whichever exist and skips the rest.
    public var relativeTargets: [String] {
        switch self {
        case .sessions:   return ["Sessions"]
        case .workspaces: return ["Workspaces"]
        case .bookmarks:  return ["bookmarks.json"]
        case .recents:    return ["history.json", "recent-paths.json"]
        case .lspCache:   return ["jdtls-data"]
        }
    }

    /// Menu title.
    public var title: String {
        switch self {
        case .sessions:   return "Reset Session Tabs…"
        case .workspaces: return "Reset Window & Layout…"
        case .bookmarks:  return "Reset Bookmarks…"
        case .recents:    return "Reset Recent Files…"
        case .lspCache:   return "Clear Language-Server Cache…"
        }
    }

    /// One-line explanation for the confirmation dialog.
    public var detail: String {
        switch self {
        case .sessions:
            return "Clears all saved session tabs (use this if session tabs are missing or stuck)."
        case .workspaces:
            return "Clears the saved window layout / last workspace."
        case .bookmarks:
            return "Removes all pinned file/folder bookmarks."
        case .recents:
            return "Clears the Recent Files list and go-to-path history."
        case .lspCache:
            return "Deletes cached language-server index data (rebuilds on next use)."
        }
    }
}

/// Which Application Support subdirectory a domain lives under. The app
/// fragments persisted state across two siblings — `MarkdownViewer/` (sessions,
/// bookmarks, recents, workspaces) and the bundle-id `com.markdownviewer.…/`
/// (plugins, walkthroughs, jdtls-data) — so a reset has to know which one.
public enum AppSupportBase: Sendable {
    case markdownViewer
    case bundleID
}

public enum AppCacheReset {

    /// `~/Library/Application Support/MarkdownViewer` — mirrors
    /// `SessionStore.defaultDirectory()`'s parent so resets hit the exact tree
    /// the stores write to. Honors the same `MDV_APP_SUPPORT` override.
    public static func markdownViewerSupportDir() -> URL {
        appSupportRoot().appendingPathComponent("MarkdownViewer", isDirectory: true)
    }

    /// `~/Library/Application Support/com.markdownviewer.MarkdownViewer`.
    public static func bundleIDSupportDir() -> URL {
        appSupportRoot().appendingPathComponent(
            "com.markdownviewer.MarkdownViewer", isDirectory: true)
    }

    private static func appSupportRoot() -> URL {
        let env = ProcessInfo.processInfo.environment
        if let appSupport = env["MDV_APP_SUPPORT"], !appSupport.isEmpty {
            return URL(fileURLWithPath: appSupport, isDirectory: true)
        }
        let fm = FileManager.default
        return (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                            appropriateFor: nil, create: false))
            ?? fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// Resolve the absolute URLs a set of domains would clear, against the given
    /// base dirs. Pure (no FS mutation) — used by the executor and testable on
    /// its own.
    public static func plannedTargets(
        _ domains: [CacheDomain],
        markdownViewerBase: URL,
        bundleIDBase: URL
    ) -> [URL] {
        domains.flatMap { domain -> [URL] in
            let root = domain.base == .bundleID ? bundleIDBase : markdownViewerBase
            return domain.relativeTargets.map { root.appendingPathComponent($0) }
        }
    }

    /// Outcome of a reset run: what actually moved, and where the backup landed.
    public struct Result: Sendable {
        public let movedTargets: [URL]
        public let backupDirectory: URL
    }

    /// Move every existing target for `domains` into
    /// `backupRoot/<timestamp>/…`, preserving the relative path so the backup
    /// is browsable. Absent targets are skipped. Returns what moved. Never
    /// deletes — recovery is a Finder drag.
    ///
    /// `timestamp` is injected (not `Date()`) so callers stamp it and the unit
    /// tests stay deterministic.
    @discardableResult
    public static func reset(
        _ domains: [CacheDomain],
        markdownViewerBase: URL,
        bundleIDBase: URL,
        backupRoot: URL,
        timestamp: String
    ) -> Result {
        let fm = FileManager.default
        let backupDir = backupRoot.appendingPathComponent(timestamp, isDirectory: true)
        var moved: [URL] = []
        for domain in domains {
            let root = domain.base == .bundleID ? bundleIDBase : markdownViewerBase
            let tag = domain.base == .bundleID ? "bundleID" : "MarkdownViewer"
            for rel in domain.relativeTargets {
                let src = root.appendingPathComponent(rel)
                guard fm.fileExists(atPath: src.path) else { continue }
                let dst = backupDir.appendingPathComponent(tag, isDirectory: true)
                    .appendingPathComponent(rel)
                try? fm.createDirectory(at: dst.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                // If a same-named backup exists from a prior reset this second,
                // remove it so the move can't fail on a collision.
                try? fm.removeItem(at: dst)
                do {
                    try fm.moveItem(at: src, to: dst)
                    moved.append(src)
                } catch {
                    // Best-effort: a target we can't move (permissions / in-use)
                    // is left in place rather than aborting the whole reset.
                    continue
                }
            }
        }
        return Result(movedTargets: moved, backupDirectory: backupDir)
    }

    /// Default backup root: `MarkdownViewer/_reset-backups`.
    public static func defaultBackupRoot(markdownViewerBase: URL) -> URL {
        markdownViewerBase.appendingPathComponent("_reset-backups", isDirectory: true)
    }
}
