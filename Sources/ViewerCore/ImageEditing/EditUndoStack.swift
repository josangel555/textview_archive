import Foundation

/// A bounded undo/redo history of `ImageDocument` op-list states (TSK-749).
///
/// ## Why a dedicated stack (the `ops` array isn't enough)
/// `ImageDocument` already models its *lossless* history as the `ops` array —
/// push is `appending`, undo is `undoingLast`. That covers a one-way "drop the
/// last edit" but has **no redo** (an undone op is gone) and **no cap** (a long
/// draw session — TSK-749's 1000+ strokes — grows the live document's op list
/// without bound, and every redraw replays the whole list). This stack layers a
/// proper editor history *over* the document:
///
/// - **Snapshot model.** Each entry is a full `[EditOp]` state, not a delta. The
///   states are cheap value types (`EditOp` is a small enum; the source bytes
///   are NOT copied — only the op list is), so snapshotting is O(ops), and undo
///   /redo is an O(1) index move into a flat array with no replay bookkeeping.
///   This is the standard "snapshot the document model on every commit" pattern;
///   command/inverse-op patterns buy memory at the cost of getting every op's
///   inverse exactly right, which the lossy CI ops (`colorControls`, …) make
///   fragile. For an op list this small, snapshots win on simplicity + safety.
/// - **Redo via a forward branch.** Undo moves a cursor back; redo moves it
///   forward over the SAME entries. A fresh `push` after an undo truncates the
///   now-orphaned forward branch (the conventional "new edit discards redo"
///   behavior every editor has).
/// - **Bounded by `limit`.** When pushing past `limit` states, the OLDEST state
///   is evicted (FIFO at the base). The pristine baseline can therefore scroll
///   off after a very long session, but the cap keeps memory + replay cost
///   bounded — exactly what TSK-749's "1000+ undo entries" needs without an
///   unbounded list. Default `limit` is 1024 so 1000+ entries fit comfortably.
///
/// Value type + `Sendable`: the whole history can cross actor boundaries and be
/// snapshotted/persisted alongside the document.
public struct EditUndoStack: Sendable, Equatable {

    /// The op-list states, oldest → newest. Always non-empty: index 0 is the
    /// baseline the stack was seeded with (or the oldest surviving state after
    /// eviction).
    private var states: [[EditOp]]
    /// Index into `states` of the CURRENT state. `undo` decrements it, `redo`
    /// increments it, `push` appends a new state and points here.
    private var cursor: Int
    /// Maximum number of retained states. Pushing past this evicts the oldest.
    public let limit: Int

    /// The default cap. 1024 ≥ the 1000+ entries the image editor wants, and a
    /// power of two for tidy growth.
    public static let defaultLimit = 1024

    /// Seed the stack with a baseline state (typically the document's initial,
    /// often-empty `ops`). `limit` is floored at 1 — a stack must hold at least
    /// the current state.
    public init(baseline: [EditOp] = [], limit: Int = EditUndoStack.defaultLimit) {
        self.states = [baseline]
        self.cursor = 0
        self.limit = max(1, limit)
    }

    // MARK: - State

    /// The current op-list state. Never throws — the stack is always non-empty.
    public var current: [EditOp] { states[cursor] }

    /// `true` when there is a prior state to return to.
    public var canUndo: Bool { cursor > 0 }
    /// `true` when there is a forward (previously-undone) state to re-apply.
    public var canRedo: Bool { cursor < states.count - 1 }

    /// The number of retained states (including the current one). For tests /
    /// diagnostics; a healthy stack keeps this `<= limit`.
    public var count: Int { states.count }

    // MARK: - Mutation

    /// Record a new current state. Truncates any forward (redo) branch first —
    /// a new edit after an undo discards the orphaned future, the universal
    /// editor behavior — then appends `state` and, if the cap is exceeded,
    /// evicts the oldest state (keeping the cursor pointing at the new tip).
    ///
    /// A push of a state identical to `current` is collapsed to a no-op so a
    /// committed-but-unchanged action (e.g. a degenerate zero-area draw the
    /// caller chose to record anyway) doesn't bloat the history.
    public mutating func push(_ state: [EditOp]) {
        if state == current { return }
        // Drop the redo branch: everything after the cursor is now orphaned.
        if cursor < states.count - 1 {
            states.removeSubrange((cursor + 1)...)
        }
        states.append(state)
        cursor = states.count - 1
        // Enforce the cap by evicting from the FRONT (oldest first).
        if states.count > limit {
            let overflow = states.count - limit
            states.removeFirst(overflow)
            cursor -= overflow
        }
    }

    /// Step back one state and return it (the new `current`). No-op returning the
    /// unchanged current state when already at the baseline.
    @discardableResult
    public mutating func undo() -> [EditOp] {
        if canUndo { cursor -= 1 }
        return current
    }

    /// Step forward one state and return it (the new `current`). No-op returning
    /// the unchanged current state when already at the tip.
    @discardableResult
    public mutating func redo() -> [EditOp] {
        if canRedo { cursor += 1 }
        return current
    }

    /// Reset the history to a single `baseline` state (clears undo + redo).
    public mutating func reset(to baseline: [EditOp] = []) {
        states = [baseline]
        cursor = 0
    }
}
