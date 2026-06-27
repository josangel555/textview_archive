import Foundation
import ViewerKit

/// Persists per-file *locks* of the view mode (TSK-811, split from TSK-732).
///
/// ## What a "lock" is and why it differs from the per-category default
///
/// `PreferencesStore.viewModeDefaults` (TSK-671) pins a default mode for a
/// whole file *category* (e.g. "always open Markdown as Source"). This store
/// is the narrower, per-FILE pin: the user picks a non-default lens for a
/// specific file (open a `.txt` as Markdown-rendered, force an `.md` into
/// Editor) and locks it so REOPENING that file re-applies the chosen mode.
///
/// ## Keying — exact filename first, extension second
///
/// A lock is keyed by the file's `lastPathComponent` (exact name, e.g.
/// `notes.txt`), with a fallback to the bare extension key (`.txt`). So the
/// user can pin one specific file OR a whole extension. Both keys are
/// lowercased on the way in/out — macOS's default filesystem is
/// case-insensitive, so `Notes.TXT` and `notes.txt` are the same file as far
/// as a lock is concerned, and treating them otherwise would silently "lose"
/// a lock on a case-differing reopen.
///
/// Resolution precedence: exact-name lock > extension lock > inferred default.
///
/// ## Persistence
///
/// A single Codable `[String: ViewMode]` map written to
/// `~/Library/Application Support/MarkdownViewer/view-mode-locks.json` via the
/// shared `JSONFileStore` (off-main coalesced write, atomic, size-capped read).
/// No new dependencies. A tampered / schema-drifted file degrades gracefully:
/// the lenient decode drops unknown `ViewMode` values, and the load caps the
/// entry count so a bloated file can't balloon memory.
///
/// Thread-safety: callers touch this from the main actor (via `DocumentModel`),
/// matching `GoToPathHistoryStore`/`BookmarksStore`. The in-memory map is the
/// source of truth; disk writes are coalesced off-main.
public final class ViewModeLockStore {
    public let storeURL: URL

    /// Cap on the number of distinct locks. A few-thousand-file workspace
    /// locking even a fraction of its files stays tiny; this just bounds a
    /// tampered/runaway file. Mirrors the defensive caps elsewhere.
    public let maxEntries: Int

    /// 256 KiB ceiling on the persisted file (filename keys + short mode
    /// strings; far more headroom than `maxEntries` short keys need).
    public let maxStoreFileBytes: Int

    /// key (lowercased filename OR `.ext`) → locked `ViewMode`.
    private var locks: [String: ViewMode] = [:]

    public init(
        storeURL: URL,
        maxEntries: Int = 2048,
        maxStoreFileBytes: Int = 256 * 1024
    ) {
        self.storeURL = storeURL
        self.maxEntries = maxEntries
        self.maxStoreFileBytes = maxStoreFileBytes
        load()
    }

    public static func defaultStoreURL() -> URL {
        // TSK-1288: markdownViewerDir() redirects to tmp under XCTest (real dir in prod).
        return TestStateRedirect.markdownViewerDir()
            .appendingPathComponent("view-mode-locks.json", isDirectory: false)
    }

    // MARK: - Key derivation (pure, testable)

    /// The exact-filename lock key for `url`: lowercased `lastPathComponent`.
    /// Empty (no filename) → `nil`.
    public static func nameKey(for url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        return name.isEmpty ? nil : name
    }

    /// The extension lock key for `url`: `.` + lowercased `pathExtension`.
    /// A file with no extension (`Makefile`, a dotfile like `.gitignore` whose
    /// `pathExtension` is empty) → `nil`, so only an exact-name lock can pin it.
    public static func extensionKey(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? nil : ".\(ext)"
    }

    // MARK: - Query

    /// The raw locked mode recorded for `url` (exact-name lock preferred over
    /// extension lock), or `nil` when neither is locked. Does NOT gate on
    /// availability — that's `resolvedMode`'s job. Exposed for the lock-icon
    /// state and for tests.
    public func lockedMode(for url: URL) -> ViewMode? {
        if let nk = Self.nameKey(for: url), let m = locks[nk] { return m }
        if let ek = Self.extensionKey(for: url), let m = locks[ek] { return m }
        return nil
    }

    /// Whether `url` has any lock (exact-name or extension) — the lock icon's
    /// filled/unfilled state.
    public func isLocked(for url: URL) -> Bool {
        lockedMode(for: url) != nil
    }

    /// Resolve the view mode `url` should open in, given the modes the file can
    /// actually show (`available`, i.e. `ViewModeOptions.availableModes`) and
    /// the mode the app would otherwise infer (`inferredDefault`).
    ///
    /// A locked mode WINS over the inferred default — but ONLY when it's in
    /// `available`. A stale lock (the file type changed so its locked lens is
    /// gone, or a cross-type extension lock that this file can't satisfy)
    /// degrades to `inferredDefault` rather than desyncing the picker from the
    /// pane (the same guard `ViewModeOptions.defaultMode` applies to the
    /// per-category override). Non-matching files (no lock) fall straight
    /// through to `inferredDefault`.
    public func resolvedMode(
        for url: URL, available: [ViewMode], inferredDefault: ViewMode
    ) -> ViewMode {
        guard let locked = lockedMode(for: url) else { return inferredDefault }
        return available.contains(locked) ? locked : inferredDefault
    }

    // MARK: - Mutation

    /// Lock `url` to `mode`, keyed by exact filename. Reopening the file
    /// re-applies `mode` (subject to availability). Overwrites any existing
    /// exact-name lock for the file.
    public func lock(_ url: URL, to mode: ViewMode) {
        guard let key = Self.nameKey(for: url) else { return }
        setLock(key: key, mode: mode)
    }

    /// Lock every file of `url`'s extension to `mode`, keyed by `.ext`. No-op
    /// for an extension-less file (use `lock(_:to:)` for those).
    public func lockExtension(_ url: URL, to mode: ViewMode) {
        guard let key = Self.extensionKey(for: url) else { return }
        setLock(key: key, mode: mode)
    }

    /// Clear the lock(s) that apply to `url` — both the exact-name AND the
    /// extension key, so toggling the lock off on a file fully unlocks it
    /// regardless of which key was set. Returns whether anything was removed.
    @discardableResult
    public func clear(for url: URL) -> Bool {
        var removed = false
        if let nk = Self.nameKey(for: url), locks.removeValue(forKey: nk) != nil {
            removed = true
        }
        if let ek = Self.extensionKey(for: url), locks.removeValue(forKey: ek) != nil {
            removed = true
        }
        if removed { save() }
        return removed
    }

    /// Toggle the lock for `url`: if already locked, clear it and return `nil`;
    /// otherwise lock the exact filename to `mode` and return `mode`. This is
    /// the lock-icon click behavior.
    @discardableResult
    public func toggle(_ url: URL, mode: ViewMode) -> ViewMode? {
        if isLocked(for: url) {
            clear(for: url)
            return nil
        }
        lock(url, to: mode)
        return mode
    }

    /// Number of distinct locks currently held.
    public var count: Int { locks.count }

    /// Drop every lock.
    public func clearAll() {
        guard !locks.isEmpty else { return }
        locks.removeAll()
        save()
    }

    private func setLock(key: String, mode: ViewMode) {
        // Enforce the cap: if at capacity and adding a NEW key, drop nothing
        // silently — overwriting an existing key is always fine; a brand-new
        // key past the cap is simply ignored (the user can clear stale locks).
        if locks[key] == nil, locks.count >= maxEntries { return }
        locks[key] = mode
        save()
    }

    // MARK: - Persistence

    private func load() {
        // Decode the raw `[String: String]` first (NOT `[String: ViewMode]`):
        // a strongly-typed dictionary decode is all-or-nothing, so one
        // unknown/renamed `ViewMode` raw value would nuke the ENTIRE map. Map
        // each value through `ViewMode(rawValue:)` and DROP the ones that don't
        // resolve — schema drift / a single tampered entry loses only that lock,
        // mirroring `PreferencesStore.viewModeDefaults`.
        guard let raw = JSONFileStore.read(
            [String: String].self, from: storeURL, maxSize: maxStoreFileBytes
        ) else { return }
        var out: [String: ViewMode] = [:]
        for (key, value) in raw {
            if out.count >= maxEntries { break }  // cap on load
            if let mode = ViewMode(rawValue: value) { out[key] = mode }
        }
        locks = out
    }

    private func save() {
        // Persist as a primitives-only `[String: String]` map (raw mode
        // strings) so the on-disk schema is stable and a future enum rename
        // can't make the file undecodable.
        var raw: [String: String] = [:]
        for (key, mode) in locks { raw[key] = mode.rawValue }
        JSONFileStore.enqueueWrite(raw, to: storeURL)
    }

    /// Block until pending writes have landed (for terminate-drain + tests).
    public func flush() {
        JSONFileStore.flushSync()
    }
}
