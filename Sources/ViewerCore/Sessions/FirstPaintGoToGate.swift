import Foundation

/// One-shot gate that records whether the next paint should present
/// the Go-to-path prompt because a brand-new session was just spawned.
///
/// Decoupled from `SessionsCoordinator` so it can be unit-tested
/// without spinning up a `SessionStore`. The host (`SessionsAppCoordinator`)
/// drives it via `recordOpenFolder(forceNew:)` and `recordActivate(id:)`,
/// and the view layer consumes it via `take()` on the next paint.
///
/// Semantics:
///   - `recordOpenFolder(forceNew: true)` arms the gate.
///   - `recordOpenFolder(forceNew: false)` is a no-op (the user
///     activated an existing matching session; not a new-blank one).
///   - `recordActivate(id:)` is a no-op (plain session switches do
///     NOT trigger the auto-prompt — they restore tabs).
///   - `take()` returns the armed state once and disarms.
///
/// Why a gate value-type instead of a Bool on the coordinator?
/// `take()` semantics (read+clear in one call) is easier to test and
/// rules out the obvious double-fire bug where two view re-renders
/// both observe the flag and both open the prompt.
public struct FirstPaintGoToGate: Sendable, Equatable {

    /// Internal armed flag. Exposed read-only for assertions; mutation
    /// goes through the explicit methods.
    public private(set) var isArmed: Bool

    public init(isArmed: Bool = false) {
        self.isArmed = isArmed
    }

    /// Arms the gate iff this `openFolder` call created a fresh
    /// session (`forceNew == true`). The coordinator-side call site
    /// passes `forceNew` through unchanged.
    public mutating func recordOpenFolder(forceNew: Bool) {
        if forceNew { isArmed = true }
    }

    /// Plain session-switch — never arms the gate. Defined as an
    /// explicit method (rather than letting the caller skip the call)
    /// so the contract is visible at the call site and so the test
    /// suite can exercise it directly.
    public mutating func recordActivate(id: UUID) {
        // intentional no-op
        _ = id
    }

    /// Read-and-clear. Returns `true` exactly once after each arm.
    public mutating func take() -> Bool {
        defer { isArmed = false }
        return isArmed
    }
}
