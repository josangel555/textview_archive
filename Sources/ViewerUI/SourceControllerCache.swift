import Foundation

/// A source-view controller that the cache can preserve across tab
/// deactivations and tear down on real close / eviction.
///
/// Abstracted behind a protocol so the LRU state machine is pure host
/// logic — `SourceControllerCacheTests` drives it with a lightweight fake
/// (no AppKit / `NSTextStorage`), while `SourceTextController` conforms in
/// production (see `TextDisplayView.swift`).
@MainActor
public protocol PreservableSourceController: AnyObject {
    /// Approximate resident bytes held by this controller's laid-out glyph
    /// store / text storage. Drives the cache's byte-budget eviction so a
    /// few huge files can't pin more memory than the count cap alone implies.
    var retainedByteCount: Int { get }

    /// Release the heavy `NSTextStorage` / `NSLayoutManager` glyph store.
    /// The cache calls this EXACTLY on real close (`purge`) or LRU/byte-budget
    /// eviction — never on a plain tab deactivation, which is the whole point
    /// of preservation (the laid-out view survives so switch-back is cheap).
    func teardownStorage()
}

/// Main-actor LRU of laid-out source-view controllers, keyed by **tab
/// identity** (a stable `UUID`), so switching back to an already-open large
/// file reuses its typeset `NSTextView` instead of re-laying-out O(N) glyphs.
///
/// ## Why this exists (TSK-889)
/// `open()` de-dups a re-open to the existing tab, so re-opening a file is a
/// tab *switch*. But switching AWAY tears the inactive tab's source view out
/// of the SwiftUI hierarchy → `dismantleNSViewController` →
/// `teardownStorage()` frees the glyph store (a deliberate memory bound for
/// large files). Switching BACK then re-creates an empty-storage controller
/// whose `apply()` can't hit its skip fast-paths, so it re-runs the full
/// `setAttributedString` + O(N) typesetting. This cache keeps the laid-out
/// controller alive for the N most-recently-active tabs so switch-back is a
/// cheap viewport re-layout, not a full re-typeset.
///
/// ## Eviction policy
/// Two independent caps, both enforced after every `store`:
///   1. **Count** — at most `maxCount` (N≈4) preserved controllers.
///   2. **Byte budget** — total `retainedByteCount` across preserved
///      controllers stays `<= maxBytes`; otherwise the LRU tail is evicted
///      until it fits. This stops N huge files from blowing the memory budget
///      that the count cap alone would permit.
/// The MRU end is the just-stored / just-acquired tab; eviction always pulls
/// from the LRU (oldest) end. The currently-active tab is never the LRU tail
/// after a `store`/`touch`, so it is never evicted out from under itself.
///
/// ## Safety
/// `teardownStorage()` is invoked EXACTLY on eviction and `purge` — proven by
/// the host tests — never on `acquire` (reuse) or a plain deactivation. A
/// caller that did NOT find an entry in `acquire` owns the new controller; it
/// stores it after `make`, transferring ownership to the cache's strong ref.
///
/// Default-OFF behind `MDV_PRESERVE_RECENT_SOURCE_VIEWS`: when disabled,
/// `TextDisplayView` never consults the cache and `dismantle` always tears
/// down, preserving today's memory-bounded behaviour exactly.
@MainActor
public final class SourceControllerCache {

    /// Process-wide shared cache. The source view's representable lifecycle is
    /// global (one tab strip), so a single LRU spans all tabs.
    public static let shared = SourceControllerCache()

    /// Whether warm-reopen preservation is active for this run. Read once at
    /// init from `MDV_PRESERVE_RECENT_SOURCE_VIEWS` (default OFF). `TextDisplayView`
    /// consults this so a disabled run behaves EXACTLY as before (always teardown
    /// on dismantle, never reuse).
    public let isEnabled: Bool

    /// Max preserved controllers (count cap). N≈4 keeps a handful of recently
    /// visited tabs warm without an unbounded live-view set.
    public let maxCount: Int

    /// Max total retained bytes across preserved controllers (byte-budget cap).
    /// ~64 MiB by default: a few large laid-out files, not an unbounded glyph
    /// store. Evict the LRU tail until total retained bytes fits.
    public let maxBytes: Int

    /// One preserved entry. `controller` is a strong ref (the cache OWNS the
    /// preserved controller while resident). Ordered list below is the LRU
    /// order; `index 0` = LRU (evict first), `last` = MRU (just touched).
    private struct Entry {
        let tabID: UUID
        let controller: any PreservableSourceController
    }

    /// LRU-ordered: front = least-recently-used (next to evict), back = MRU.
    private var entries: [Entry] = []

    public init(
        isEnabled: Bool? = nil,
        maxCount: Int = 4,
        maxBytes: Int = 64 * 1024 * 1024,
        environment: [String: String]? = nil
    ) {
        if let isEnabled {
            self.isEnabled = isEnabled
        } else {
            self.isEnabled = Self.readFlag(environment: environment)
        }
        self.maxCount = max(0, maxCount)
        self.maxBytes = max(0, maxBytes)
    }

    /// Number of currently-preserved controllers. Test/diagnostics seam.
    public var count: Int { entries.count }

    /// Total retained bytes across preserved controllers. Test/diagnostics seam.
    public var totalRetainedBytes: Int {
        entries.reduce(0) { $0 + $1.controller.retainedByteCount }
    }

    /// Tab ids currently preserved, in LRU order (front = oldest). Test seam.
    public var residentTabIDs: [UUID] { entries.map(\.tabID) }

    /// Look up a preserved controller for `tabID`. On a hit, the entry is moved
    /// to the MRU end (a reuse counts as a recent access) and the controller is
    /// returned for reuse — NO teardown happens. On a miss, returns `nil`: the
    /// caller creates a fresh controller and `store`s it.
    public func acquire(tabID: UUID) -> (any PreservableSourceController)? {
        guard isEnabled else { return nil }
        guard let idx = entries.firstIndex(where: { $0.tabID == tabID }) else {
            return nil
        }
        let entry = entries.remove(at: idx)
        entries.append(entry)   // promote to MRU
        return entry.controller
    }

    /// Insert (or refresh) the controller for `tabID` as the MRU entry, then
    /// enforce both caps by evicting LRU-tail entries (each evicted controller
    /// gets `teardownStorage()`). If an entry for `tabID` already exists it is
    /// replaced in place (the old controller is torn down only if it is a
    /// DIFFERENT instance — replacing a tab's controller is a logical close of
    /// the old one).
    ///
    /// No-op when disabled (the controller is then owned by SwiftUI and torn
    /// down on dismantle as before).
    public func store(tabID: UUID, controller: any PreservableSourceController) {
        guard isEnabled else { return }
        if let idx = entries.firstIndex(where: { $0.tabID == tabID }) {
            let existing = entries[idx].controller
            if existing !== controller {
                // Replacing a tab's controller with a new instance: the old one
                // is logically closed — tear it down so its glyph store frees now.
                existing.teardownStorage()
            }
            entries.remove(at: idx)
        }
        entries.append(Entry(tabID: tabID, controller: controller))
        enforceCaps()
    }

    /// Mark `tabID` as recently accessed (promote to MRU) without inserting.
    /// A safety helper for callers that want to bump recency on activation
    /// independent of `acquire`. No-op if absent / disabled.
    public func touch(tabID: UUID) {
        guard isEnabled else { return }
        guard let idx = entries.firstIndex(where: { $0.tabID == tabID }) else { return }
        let entry = entries.remove(at: idx)
        entries.append(entry)
    }

    /// Remove and TEAR DOWN the preserved controller for `tabID` — the real
    /// close path (tab removed). Idempotent: a no-op if `tabID` isn't resident.
    /// This is one of the EXACTLY-TWO places `teardownStorage()` fires (the
    /// other is eviction).
    public func purge(tabID: UUID) {
        guard let idx = entries.firstIndex(where: { $0.tabID == tabID }) else { return }
        let entry = entries.remove(at: idx)
        entry.controller.teardownStorage()
    }

    /// Tear down and drop EVERY preserved controller. For app teardown / a
    /// global reset; tears down all resident controllers.
    public func purgeAll() {
        let drained = entries
        entries.removeAll()
        for entry in drained {
            entry.controller.teardownStorage()
        }
    }

    /// Is the controller for `tabID` still cache-resident? `TextDisplayView`'s
    /// `dismantleNSViewController` consults this: a resident controller is
    /// merely DEACTIVATED (preserve it, no teardown); a non-resident one is a
    /// real close (teardown). Returns false when disabled, so the disabled run
    /// always tears down on dismantle.
    public func isResident(tabID: UUID) -> Bool {
        guard isEnabled else { return false }
        return entries.contains { $0.tabID == tabID }
    }

    // MARK: - Eviction

    /// Enforce the count cap, then the byte-budget cap, evicting from the LRU
    /// (front) end. Each evicted controller is torn down. Never evicts the MRU
    /// entry to satisfy the byte budget (a single resident controller that
    /// alone exceeds `maxBytes` is kept — we don't tear down the tab the user
    /// just activated; the count cap is 1 in that degenerate case anyway).
    private func enforceCaps() {
        // Count cap: drop oldest until within maxCount.
        while entries.count > maxCount {
            evictLRU()
        }
        // Byte-budget cap: drop oldest until total fits, but keep at least the
        // MRU entry even if it alone exceeds the budget.
        while entries.count > 1, totalRetainedBytes > maxBytes {
            evictLRU()
        }
    }

    /// Remove the LRU (front) entry and tear it down.
    private func evictLRU() {
        guard !entries.isEmpty else { return }
        let evicted = entries.removeFirst()
        evicted.controller.teardownStorage()
    }

    // MARK: - Flag

    /// Read `MDV_PRESERVE_RECENT_SOURCE_VIEWS` (default OFF). `1`/`true`
    /// enables. Mirrors `RustCoreGates`' single-var getenv read (no full
    /// environ dict) for the production nil path; tests inject a dict.
    static func readFlag(environment: [String: String]?) -> Bool {
        let raw: String?
        if let environment {
            raw = environment["MDV_PRESERVE_RECENT_SOURCE_VIEWS"]
        } else if let c = getenv("MDV_PRESERVE_RECENT_SOURCE_VIEWS") {
            raw = String(cString: c)
        } else {
            raw = nil
        }
        guard let raw else { return false }
        return raw == "1" || raw.lowercased() == "true"
    }
}
