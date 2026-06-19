import Foundation

/// FOUNDATION SLICE of the unified-action-history epic (TSK-703).
///
/// Today undo is fragmented across the app: `NSTextView`'s native stack in the
/// editor, `LocalHistoryStore` (on-disk file snapshots), `HistoryStore`
/// (recents), bespoke per-feature undo (bookmarks). There is no single place
/// that records "what the user did" as a reversible, inspectable stream.
///
/// This slice introduces that spine:
///   - `ReversibleAction` — the contract every undoable operation conforms to:
///     `apply()` performs (or re-performs) the action, `revert()` undoes it,
///     plus a human-readable `label`, a `category` (for grouping/coalescing),
///     and a `timestamp`.
///   - `ActionHistory` — an ordered, size-capped coordinator that *executes*
///     actions (calling `apply()`), records them in a log, and drives
///     undo/redo by walking that log. Coalesces consecutive same-category
///     entries inside a short time window so a burst of keystroke-grain edits
///     collapses into one logical undo step.
///   - `ActionHistoryLogEntry` — the read-only projection the History list view
///     renders (label + category + timestamp + a coalesced-count badge).
///
/// Scope discipline: this does NOT migrate every existing undo site. It wires
/// the mechanism + a `ClosureAction` adapter seam so any feature can register a
/// reversible op without depending on the rest of the app. Concrete adoption
/// (CSV cell edit, tab close/reopen, editor edits) lands in follow-up slices.
///
/// Threading: not internally synchronized — like `HistoryStore` /
/// `DocumentModel`, callers drive it from the main actor. Pure logic, no
/// SwiftUI / AppKit imports, so the whole thing is host-testable.

// MARK: - Category

/// Coarse grouping for actions. Drives the coalescing rule (only adjacent
/// entries in the *same* category may merge) and the History view's per-row
/// icon/affordance. Deliberately small + stable so it can be persisted later.
public enum ActionCategory: String, Codable, Equatable, Sendable, CaseIterable {
    /// Text/content edit inside a buffer (typing, paste, delete).
    case edit
    /// A spreadsheet/table cell value change (CSV editor).
    case cell
    /// Tab lifecycle (open / close / reorder).
    case tab
    /// File-system mutation initiated from the UI (rename, move, delete).
    case file
    /// Bookmark / pin / marker toggles.
    case marker
    /// Anything not yet categorized. Never coalesces (each stays distinct).
    case other

    /// Whether two adjacent actions of this category are *eligible* to merge.
    /// `.other` is intentionally non-coalescing — an uncategorized op is opaque
    /// to us, so collapsing it would hide steps the user may want to undo
    /// individually.
    public var coalesces: Bool {
        switch self {
        case .other: return false
        default: return true
        }
    }
}

// MARK: - ReversibleAction

/// The contract every undoable operation conforms to. An action OWNS the state
/// needed to both perform and reverse itself (e.g. an edit captures the old +
/// new text). `apply` and `revert` must be exact inverses: after
/// `apply(); revert()` the world is byte-for-byte where it started, and after
/// `apply(); revert(); apply()` it is where the first `apply` left it (redo is
/// symmetric).
///
/// A class (reference type) so the coordinator can hold heterogeneous actions
/// in one array without existential boxing friction, and so an action may carry
/// mutable bookkeeping (e.g. a captured "before" value computed at apply time).
public protocol ReversibleAction: AnyObject {
    /// Human-readable, present-tense description for the History list and the
    /// Edit-menu "Undo <label>" affordance, e.g. "Edit cell B3", "Close tab
    /// README.md".
    var label: String { get }

    /// Coarse grouping for coalescing + display.
    var category: ActionCategory { get }

    /// When the action was executed (set by the coordinator on `execute`, but
    /// the action declares storage so it travels with the entry).
    var timestamp: Date { get set }

    /// Perform (or re-perform, on redo) the action. Must be idempotent w.r.t.
    /// the modeled state: calling `apply` from the pre-action state always
    /// produces the post-action state.
    func apply()

    /// Reverse the action, restoring the exact pre-action state.
    func revert()

    /// Attempt to absorb `next` (a freshly-executed action of the same
    /// category) into `self`, collapsing two log entries into one. Returns
    /// `true` if merged (the coordinator then discards `next`'s separate entry
    /// but `next.apply()` has ALREADY run, so the live state is correct), or
    /// `false` to keep them distinct. Default: never merge. Override for
    /// keystroke-grain edits where a run of single-char inserts should undo as
    /// one word.
    func coalesce(with next: ReversibleAction) -> Bool
}

public extension ReversibleAction {
    func coalesce(with next: ReversibleAction) -> Bool { false }
}

// MARK: - ClosureAction (adapter seam)

/// A `ReversibleAction` built from two closures. The adapter seam that lets any
/// feature register a reversible op without writing a bespoke class. The
/// closures capture whatever state they need (old/new value, indices, the
/// owning model). Optionally supply a `merge` closure to opt into coalescing.
public final class ClosureAction: ReversibleAction {
    public let label: String
    public let category: ActionCategory
    public var timestamp: Date
    private let applyFn: () -> Void
    private let revertFn: () -> Void
    private let mergeFn: ((ReversibleAction) -> Bool)?

    public init(
        label: String,
        category: ActionCategory,
        timestamp: Date = Date(),
        apply: @escaping () -> Void,
        revert: @escaping () -> Void,
        merge: ((ReversibleAction) -> Bool)? = nil
    ) {
        self.label = label
        self.category = category
        self.timestamp = timestamp
        self.applyFn = apply
        self.revertFn = revert
        self.mergeFn = merge
    }

    public func apply() { applyFn() }
    public func revert() { revertFn() }
    public func coalesce(with next: ReversibleAction) -> Bool {
        mergeFn?(next) ?? false
    }
}

// MARK: - Log entry (read-only projection)

/// The read-only row the History list view renders. A flattened snapshot of a
/// recorded action — deliberately decoupled from the live `ReversibleAction` so
/// the view never holds (or can mutate) the action objects, and so the
/// projection can be persisted/serialized in a later slice.
public struct ActionHistoryLogEntry: Identifiable, Equatable, Sendable {
    /// Stable id, assigned at record time in monotonically increasing order so
    /// the view's `ForEach` is stable and insertion order is recoverable.
    public let id: UInt64
    public let label: String
    public let category: ActionCategory
    public let timestamp: Date
    /// How many raw actions this entry represents (>1 ⇒ coalesced run). The
    /// view can show a "×N" badge.
    public let coalescedCount: Int

    public init(
        id: UInt64,
        label: String,
        category: ActionCategory,
        timestamp: Date,
        coalescedCount: Int = 1
    ) {
        self.id = id
        self.label = label
        self.category = category
        self.timestamp = timestamp
        self.coalescedCount = coalescedCount
    }
}

// MARK: - ActionHistory coordinator

/// Central reversible-command bus + recorded log. Executes actions, records
/// them, and drives undo/redo. The undo/redo *cursor* model mirrors a standard
/// editor stack: `execute` appends past the cursor and clears any redo tail;
/// `undo` walks the cursor back (reverting); `redo` walks it forward
/// (re-applying).
///
/// `ObservableObject` so the History view re-renders on `@Published log`
/// mutations. (Importing Combine via Foundation; no SwiftUI dependency.)
public final class ActionHistory: ObservableObject {

    /// The recorded log, oldest-first (insertion order). Read-only to the view.
    /// Published so SwiftUI refreshes on every record/undo/redo.
    @Published public private(set) var log: [ActionHistoryLogEntry] = []

    /// Max log entries retained. When exceeded, the OLDEST entry is evicted
    /// (and its action dropped — it can no longer be undone). Bounds memory for
    /// a long session.
    public let maxEntries: Int

    /// Coalescing window: a freshly-executed action may merge into the previous
    /// one only if they share a (coalescing) category AND were executed within
    /// this interval. Keeps a burst of typing as one undo step but lets a pause
    /// start a fresh step. Zero disables time-based coalescing entirely.
    public let coalesceWindow: TimeInterval

    private let clock: () -> Date

    /// The live action objects, parallel to `log` by id. We keep them out of
    /// the published projection so the view can't touch them.
    private var actions: [UInt64: ReversibleAction] = [:]
    /// id order of recorded actions, oldest-first — the undo/redo spine.
    private var order: [UInt64] = []
    /// Index of the next-to-undo position: everything in `order[..<cursor]` is
    /// "applied" (undoable), `order[cursor...]` is "reverted" (redoable). So
    /// `cursor == order.count` means nothing is redoable.
    private var cursor: Int = 0
    private var nextID: UInt64 = 0

    public init(
        maxEntries: Int = 500,
        coalesceWindow: TimeInterval = 1.0,
        clock: @escaping () -> Date = { Date() }
    ) {
        self.maxEntries = max(1, maxEntries)
        self.coalesceWindow = max(0, coalesceWindow)
        self.clock = clock
    }

    /// `true` if there is an applied action the cursor can step back over.
    public var canUndo: Bool { cursor > 0 }
    /// `true` if there is a reverted action the cursor can step forward over.
    public var canRedo: Bool { cursor < order.count }

    /// The label of the next action `undo()` would reverse, for the Edit menu.
    public var undoLabel: String? {
        guard cursor > 0, let a = actions[order[cursor - 1]] else { return nil }
        return a.label
    }
    /// The label of the next action `redo()` would re-apply.
    public var redoLabel: String? {
        guard cursor < order.count, let a = actions[order[cursor]] else { return nil }
        return a.label
    }

    /// Execute `action` (calls `apply()`), then record it.
    ///
    /// Semantics:
    ///   1. `apply()` runs FIRST so the live state is mutated regardless of
    ///      whether the entry coalesces (a merged action's effect must still
    ///      land).
    ///   2. If the cursor is not at the end (the user had undone some steps),
    ///      the redo tail is discarded — a new action forks history, standard
    ///      editor behavior.
    ///   3. Coalescing: if the immediately-preceding applied action shares a
    ///      coalescing category, was recorded within `coalesceWindow`, and
    ///      accepts the merge via `coalesce(with:)`, the two collapse into one
    ///      log entry (count bumped, label/timestamp refreshed to the newest).
    ///   4. Otherwise a fresh entry is appended and the cap enforced.
    public func execute(_ action: ReversibleAction) {
        let now = clock()
        action.timestamp = now
        action.apply()

        // (2) Forking: drop the redo tail (reverted actions ahead of cursor).
        if cursor < order.count {
            for id in order[cursor...] { actions[id] = nil }
            order.removeSubrange(cursor...)
            log.removeLast(log.count - cursor)
        }

        // (3) Coalescing into the previous applied entry.
        if let prevID = order.last,
           let prev = actions[prevID],
           let prevEntry = log.last,
           action.category.coalesces,
           prev.category == action.category,
           (coalesceWindow == 0 ? true : now.timeIntervalSince(prevEntry.timestamp) <= coalesceWindow),
           prev.coalesce(with: action) {
            // Merged: prev absorbed next's effect. Refresh the projection
            // (newest label/timestamp wins; bump the coalesced count).
            log[log.count - 1] = ActionHistoryLogEntry(
                id: prevEntry.id,
                label: action.label,
                category: action.category,
                timestamp: now,
                coalescedCount: prevEntry.coalescedCount + 1
            )
            // `action` is discarded — `prev` remains the undoable unit.
            return
        }

        // (4) Fresh entry.
        let id = nextID
        nextID &+= 1
        actions[id] = action
        order.append(id)
        log.append(ActionHistoryLogEntry(
            id: id, label: action.label, category: action.category, timestamp: now
        ))
        cursor = order.count

        enforceCap()
    }

    /// Reverse the most-recent applied action, stepping the cursor back. No-op
    /// if nothing is undoable. Returns the reverted action's label, if any.
    @discardableResult
    public func undo() -> String? {
        guard cursor > 0 else { return nil }
        cursor -= 1
        guard let action = actions[order[cursor]] else { return nil }
        action.revert()
        // A reverted entry stays in the log (it's redoable) — the cursor, not
        // the log, tracks applied/reverted. The view may dim past-cursor rows.
        objectWillChange.send()
        return action.label
    }

    /// Re-apply the next reverted action, stepping the cursor forward. No-op if
    /// nothing is redoable. Returns the re-applied action's label, if any.
    @discardableResult
    public func redo() -> String? {
        guard cursor < order.count else { return nil }
        guard let action = actions[order[cursor]] else { return nil }
        action.apply()
        cursor += 1
        objectWillChange.send()
        return action.label
    }

    /// Drop the entire history (e.g. on document close / reset). Does NOT
    /// revert anything — purely clears the record.
    public func clear() {
        actions.removeAll()
        order.removeAll()
        log.removeAll()
        cursor = 0
    }

    /// The number of currently-applied (undoable) actions — the cursor depth.
    /// Distinct from `log.count`, which also counts redoable entries.
    public var appliedCount: Int { cursor }

    // MARK: - Private

    /// Evict oldest entries until within `maxEntries`. An evicted action can no
    /// longer be undone; we drop it from `actions` and shift the cursor so it
    /// still points at the same logical position.
    private func enforceCap() {
        guard order.count > maxEntries else { return }
        let overflow = order.count - maxEntries
        for id in order.prefix(overflow) { actions[id] = nil }
        order.removeFirst(overflow)
        log.removeFirst(overflow)
        cursor = max(0, cursor - overflow)
    }
}
