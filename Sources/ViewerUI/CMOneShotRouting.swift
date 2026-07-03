import Foundation

// TSK-1483 — routing for one-shot IMPERATIVE editor requests (the key-event /
// focus routing audit's "wrong pane" class).
//
// THE CLASS THIS FIXES
// --------------------
// `EditorCoordinator` publishes app-global one-shot requests (`editorGotoLine`,
// `editorInsertRequest`, `editorSelectRequest`) that `ContentView` feeds into
// EVERY mounted `CodeMirrorEditorView` pane — and `MountedPanesLRU` keeps up to
// 4 panes mounted at once. Each pane's Coordinator used to apply a request
// whenever it differed from its OWN `lastApplied*` mirror, which broke two ways:
//
//   1. FAN-OUT: a snippet/date insert or goto-line fired on the active pane was
//      ALSO applied by every other mounted, ready pane (their mirrors differed
//      too) — text landed in invisible documents ("snippets insert into
//      whichever view has stale focus", OwnerWishlist).
//   2. STALE REPLAY: the published request is never cleared, so a pane mounted
//      (or warm-cache re-attached — `adoptState` deliberately drops nonces)
//      AFTER the request fired saw it as new and replayed it into the wrong
//      document, possibly minutes later.
//
// THE RULE (see docs/FOCUS_ROUTING.md)
// ------------------------------------
// A one-shot request is stamped with the TAB it targets at creation time (the
// model layer knows the active tab; the view layer must not guess from focus).
// Exactly ONE pane may apply it — the pane hosting that tab — and exactly ONCE
// app-wide, enforced by a shared consumed-ledger keyed on the request's nonce
// `id`. Untargeted requests (legacy creators, tests) degrade to "the active
// pane only", never a mounted-but-inactive sibling.
//
// `paneMayApply` is the pure, host-testable eligibility decision (same pattern
// as `SidebarKeyMonitor.shouldYield` / `PaneCompositingPolicy.render`);
// `CMOneShotLedger` is the tiny exactly-once guard.

/// Exactly-once guard for one-shot editor requests. Shared across every
/// mounted pane's Coordinator (`CMOneShotLedger.shared`): the FIRST pane to
/// `consume(id)` a request dispatches it; every later sighting — another
/// mounted pane, a re-mount of the same pane, a warm-cache re-attach — is
/// rejected, killing the stale-replay half of the TSK-1483 bug.
///
/// Bounded: remembers the most recent `capacity` ids (FIFO eviction). One id
/// is minted per user action, so 512 comfortably outlives any realistic
/// remount window while keeping the set O(1)-small.
@MainActor
final class CMOneShotLedger {
    static let shared = CMOneShotLedger()

    private var consumed: Set<UUID> = []
    private var order: [UUID] = []
    private let capacity: Int

    init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
    }

    /// Consume `id`. Returns `true` exactly once per id (the caller may
    /// dispatch); `false` for every subsequent call with the same id.
    func consume(_ id: UUID) -> Bool {
        guard !consumed.contains(id) else { return false }
        consumed.insert(id)
        order.append(id)
        if order.count > capacity {
            consumed.remove(order.removeFirst())
        }
        return true
    }

    /// Read-only probe (tests / diagnostics).
    func isConsumed(_ id: UUID) -> Bool { consumed.contains(id) }
}

/// Pure pane-eligibility decision for a one-shot request.
enum CMOneShotRouting {
    /// May the pane hosting tab `paneTabID` apply a request stamped with
    /// `target`?
    ///
    ///   - Targeted request (`target != nil`): ONLY the pane whose tab id
    ///     matches — mounted-but-inactive siblings and freshly mounted panes
    ///     for other tabs are ineligible regardless of focus or activity.
    ///   - Untargeted request (`target == nil` — legacy creators): only the
    ///     ACTIVE pane, preserving pre-TSK-1483 intent without the fan-out.
    ///
    /// Exactly-once is NOT decided here — that's `CMOneShotLedger` — so this
    /// stays a pure function of its arguments.
    static func paneMayApply(target: UUID?, paneTabID: UUID?, isActivePane: Bool) -> Bool {
        if let target { return paneTabID == target }
        return isActivePane
    }
}
