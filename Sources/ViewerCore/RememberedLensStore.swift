import Foundation
import ViewerKit

/// TSK-1502 — the IMPLICIT "remember the last lens I viewed this file
/// through" store: on a fresh reopen (after close), land in the mode the
/// file was last viewed in. Distinct from the two existing mechanisms:
///   - `TabSnapshot.viewMode` remembers only while the tab stays OPEN.
///   - `ViewModeLockStore` remembers durably but ONLY when the user
///     EXPLICITLY locks (the lock icon = intent).
/// This fills the middle: automatic, no intent required.
///
/// PRODUCT-GATED (`RememberedLensGate`, default OFF). Auto-remember has a
/// real downside — inspect a file once in Hex and every reopen is Hex until
/// re-switched — which the explicit lock avoids by requiring intent. So the
/// store + precedence ship TESTED but INERT behind the gate; the flip is an
/// owner decision (parked). When ON, precedence is:
///   explicit lock  >  remembered lens  >  category/inferred default
/// (all availability-gated). The explicit lock always wins, so a user who
/// locked a file is never overridden by auto-remember.
///
/// Keyed by exact lowercased filename (like the lock store's name key); a
/// single Codable map via `JSONFileStore` (off-main, atomic, size-capped).
public final class RememberedLensStore {
    public let storeURL: URL
    public let maxEntries: Int
    public let maxStoreFileBytes: Int

    /// lowercased filename → last-viewed `ViewMode`.
    private var remembered: [String: ViewMode] = [:]

    public init(
        storeURL: URL,
        maxEntries: Int = 4096,
        maxStoreFileBytes: Int = 512 * 1024
    ) {
        self.storeURL = storeURL
        self.maxEntries = maxEntries
        self.maxStoreFileBytes = maxStoreFileBytes
        load()
    }

    public static func defaultStoreURL() -> URL {
        TestStateRedirect.markdownViewerDir()
            .appendingPathComponent("remembered-lenses.json", isDirectory: false)
    }

    static func nameKey(for url: URL) -> String? {
        let name = url.lastPathComponent.lowercased()
        return name.isEmpty ? nil : name
    }

    // MARK: - Query

    public func rememberedMode(for url: URL) -> ViewMode? {
        guard let key = Self.nameKey(for: url) else { return nil }
        return remembered[key]
    }

    /// The precedence resolver — the single source of truth the view consults
    /// (when the gate is on). `locked` (explicit intent) wins; else the
    /// `remembered` lens IF the gate is on and it's available; else the
    /// inferred default. Every candidate is availability-gated so a stale
    /// value never desyncs the picker from the pane.
    public static func resolve(
        locked: ViewMode?,
        remembered: ViewMode?,
        available: [ViewMode],
        inferredDefault: ViewMode,
        gateOn: Bool
    ) -> ViewMode {
        if let locked, available.contains(locked) { return locked }
        if gateOn, let remembered, available.contains(remembered) { return remembered }
        return inferredDefault
    }

    // MARK: - Mutation

    /// Record `mode` as the last lens for `url`. Called on every explicit
    /// view-mode change (cheap; coalesced write). No-op for an unnamed url.
    public func remember(_ url: URL, mode: ViewMode) {
        guard let key = Self.nameKey(for: url) else { return }
        if remembered[key] == mode { return }   // no-op guard (avoid a needless write)
        remembered[key] = mode
        evictIfNeeded()
        persist()
    }

    public func forget(_ url: URL) {
        guard let key = Self.nameKey(for: url), remembered[key] != nil else { return }
        remembered.removeValue(forKey: key)
        persist()
    }

    // MARK: - Persistence

    private func evictIfNeeded() {
        guard remembered.count > maxEntries else { return }
        // Deterministic trim (sorted keys) — the store is a convenience cache,
        // not authoritative, so a bounded arbitrary drop is fine.
        let overflow = remembered.count - maxEntries
        for key in remembered.keys.sorted().prefix(overflow) {
            remembered.removeValue(forKey: key)
        }
    }

    private func load() {
        guard let decoded = JSONFileStore.read(
            [String: ViewMode].self, from: storeURL, maxSize: maxStoreFileBytes)
        else { return }
        remembered = decoded
        evictIfNeeded()
    }

    private func persist() {
        JSONFileStore.enqueueWrite(remembered, to: storeURL)
    }
}

/// TSK-1502 — the gate for auto-remember-last-lens. Ships OFF: the explicit
/// lock is the intended durable mechanism until the owner decides auto is
/// wanted (the Hex-trap downside is real). Flip per-run with
/// `MDV_REMEMBER_LENS=1` or the persisted default.
public enum RememberedLensGate {
    public static let defaultsKey = "mdv.rememberLastLens"
    static let envKey = "MDV_REMEMBER_LENS"

    public static func isEnabled(
        defaults: UserDefaults = .standard,
        environment: [String: String]? = nil
    ) -> Bool {
        let env = environment ?? ProcessInfo.processInfo.environment
        if let v = env[envKey] { return v == "1" }
        if defaults.object(forKey: defaultsKey) != nil {
            return defaults.bool(forKey: defaultsKey)
        }
        return false   // OFF until the owner resolves auto-vs-explicit
    }
}
