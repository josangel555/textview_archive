import Foundation
import ViewerCore

/// Synchronous-read cache for "can this file show in-app history?" so the
/// menu/context-menu enable-state check (`DocumentModel.canShowFileHistory`)
/// never spawns a git subprocess on the main thread (TSK-972).
///
/// ## The bug this fixes
/// `canShowFileHistory(for:)` used to call `GitClient(...).isTracked(path:)`
/// inline, which shells out to `git ls-files`. That method backs three
/// main-thread hot paths:
/// - `.disabled(!model.canShowFileHistory(for: url))` on the **File History**
///   item in the tab-bar and sidebar context menus — re-evaluated on EVERY
///   SwiftUI body render of those menus, so a single context-menu open could
///   fork git several times.
/// - the AppKit menu-validation / action path in `main.swift`.
///
/// Forking a process from the main thread blocks the run loop for the
/// fork+exec+wait round-trip; under a slow/locked repo (a wedged
/// `index.lock`, a network filesystem) it stalls the whole UI.
///
/// ## The fix
/// This cache answers `canShowFileHistory` from an in-memory map keyed by the
/// file's standardized path — pure, allocation-free, main-thread-safe. The
/// real git probe (`discoverRoot` + `isTracked`) runs OFF the main thread on
/// a detached task; when it lands, the answer is written back and the model
/// republishes so SwiftUI re-evaluates `.disabled` with the true value.
///
/// ## Why "unknown ⇒ enabled"
/// Before the first probe lands there is no cached answer. We return `true`
/// (item enabled) rather than `false`: a stray click while the probe is in
/// flight is harmless — `openFileHistory(for:)` independently re-gates on the
/// real repo/tracked check and is a graceful no-op for an untracked file. A
/// transient "enabled then disabled" flicker is strictly better than a
/// transient "disabled then enabled" one (the latter hides a real, available
/// action behind a greyed-out item until the probe lands).
///
/// The cache is intentionally NOT HEAD-invalidated: tracked-ness flips only
/// when a file is `git add`ed or `git rm`ed, which is rare and self-corrects
/// on the next probe scheduled by a fresh menu open after the entry is
/// dropped. `invalidate()` / `invalidateAll()` drop stale entries (e.g. on a
/// repo-root change) so the next read re-probes.
///
/// `@MainActor` (matches `DocumentModel`): all reads/writes of `entries`
/// happen on the main actor, so the map needs no lock. Only the blocking git
/// probe leaves the actor (via `probe`, a `Sendable` `nonisolated` closure).
@MainActor
public final class FileHistoryAvailabilityCache {

    /// Path (standardized) → "is tracked file in a repo".
    private var entries: [String: Bool] = [:]

    /// Paths with a probe currently in flight, so a burst of body re-renders
    /// (the SwiftUI `.disabled` hot path) schedules exactly ONE git fork per
    /// file instead of one per render.
    private var inFlight: Set<String> = []

    /// The blocking availability probe, factored out so tests can inject a
    /// deterministic fake (no real git) AND so the one place that forks git
    /// is explicit. `nonisolated` + `Sendable`: it runs on a detached task,
    /// off the main actor. Default = the real `GitClient` path.
    private let probe: @Sendable (URL) -> Bool

    /// Production initializer — probes via the real `GitClient`.
    public init() {
        self.probe = FileHistoryAvailabilityCache.gitProbe
    }

    /// Test/seam initializer — inject a fake probe to exercise the
    /// cache/scheduling logic without spawning git.
    init(probe: @escaping @Sendable (URL) -> Bool) {
        self.probe = probe
    }

    /// The real availability probe: `url` is a tracked file inside a git
    /// repo. Pure of any UI/actor state, so it is safe to run off-main.
    /// Mirrors the historical inline body of `canShowFileHistory`.
    nonisolated static func gitProbe(_ url: URL) -> Bool {
        guard let root = GitClient.discoverRoot(from: url) else { return false }
        let rel = DocumentModel.repoRelativePath(of: url, root: root)
        guard let rel, !rel.isEmpty else { return false }
        return GitClient(repoRoot: root).isTracked(path: rel)
    }

    /// Standardized cache key for `url` (resolves `.`/`..`, trailing slash).
    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// Synchronous, non-blocking answer for `url`:
    /// - a cached value if one exists (the common, post-probe case),
    /// - otherwise `true` (enabled — see the "unknown ⇒ enabled" note),
    ///   while scheduling an off-main probe whose result is delivered via
    ///   `onResolved` (the model uses it to write the answer + republish).
    ///
    /// `onResolved` is invoked on the main actor with `(url, isAvailable)`
    /// ONLY when a probe actually ran and produced a *new or changed* answer
    /// for `url`, so the caller can republish exactly when the UI needs it.
    public func availability(
        for url: URL,
        onResolved: @escaping @MainActor (URL, Bool) -> Void
    ) -> Bool {
        let k = Self.key(for: url)
        if let cached = entries[k] { return cached }

        scheduleProbe(url: url, key: k, onResolved: onResolved)
        return true   // unknown ⇒ enabled (see type doc)
    }

    /// Schedule a single off-main probe for `url` (deduped by `inFlight`).
    private func scheduleProbe(
        url: URL,
        key k: String,
        onResolved: @escaping @MainActor (URL, Bool) -> Void
    ) {
        guard !inFlight.contains(k) else { return }
        inFlight.insert(k)
        let probe = self.probe
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = probe(url)   // forks git OFF the main thread
            await self?.store(key: k, url: url, value: result, onResolved: onResolved)
        }
    }

    /// Land a probe result back on the main actor: clear the in-flight mark,
    /// write the entry, and notify `onResolved` only when the value is new or
    /// changed (so we don't churn the UI on a no-op re-probe).
    private func store(
        key k: String,
        url: URL,
        value: Bool,
        onResolved: @MainActor (URL, Bool) -> Void
    ) {
        inFlight.remove(k)
        let prior = entries[k]
        entries[k] = value
        if prior != value {
            onResolved(url, value)
        }
    }

    /// Drop the cached answer for one file (e.g. after a `git add`/`rm` the
    /// app initiated). The next read re-probes.
    public func invalidate(for url: URL) {
        entries[Self.key(for: url)] = nil
    }

    /// Drop everything (e.g. on a repo-root / workspace change). The next
    /// reads re-probe lazily.
    public func invalidateAll() {
        entries.removeAll()
    }

    // MARK: - Test seams

    /// Number of cached entries — lets tests assert caching happened without
    /// exposing the map.
    var cachedCount: Int { entries.count }

    /// Whether a synchronous cached answer exists for `url` (no probe).
    func hasCachedValue(for url: URL) -> Bool {
        entries[Self.key(for: url)] != nil
    }
}
