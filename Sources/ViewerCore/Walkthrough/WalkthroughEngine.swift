import Foundation

/// Pure-logic state machine that walks a `WalkthroughScript` step by
/// step. The engine owns the current step index and emits each step's
/// actions to a delegate; the delegate is the UI layer's adapter and
/// is the only place AppKit/SwiftUI is allowed.
///
/// Why a delegate (not a closure / publisher): the UI layer routes
/// actions onto multiple existing nonce channels on `DocumentModel`
/// (see `WALKTHROUGH_DESIGN_v2.md` §7). A protocol with one entry per
/// variant keeps the routing exhaustive — `switch` over `Action` in
/// the delegate, no fallthrough.
///
/// Threading: the engine is `@MainActor` because every delegate call
/// ultimately mutates `DocumentModel` (also `@MainActor`). The state
/// transitions are synchronous; the engine does not own any timers in
/// v1 — auto-advance via `dwellSec` belongs to the UI strip, which
/// calls `next()` on the engine.
@MainActor
public final class WalkthroughEngine {

    // MARK: - Observable state

    /// High-level state for the controller strip's transport buttons.
    /// Kept narrow on purpose; UI subscribes via the delegate, not by
    /// reading these fields under a publisher.
    public enum State: Equatable, Sendable {
        case idle
        case playing
        case paused
        case done
    }

    public private(set) var state: State = .idle
    public private(set) var script: WalkthroughScript?
    /// Index of the **current** step (the one whose actions were last
    /// applied). `-1` means "before the first step" — only reachable
    /// transiently between `load` and the first `next/jumpTo/restart`.
    public private(set) var stepIndex: Int = -1

    // MARK: - Delegate

    public weak var delegate: WalkthroughEngineDelegate?

    public init(delegate: WalkthroughEngineDelegate? = nil) {
        self.delegate = delegate
    }

    // MARK: - Script lifecycle

    /// Replace any in-flight script with `script` and reset the cursor.
    /// Caller must invoke `next()` (or `jumpTo`) to actually apply the
    /// first step — `load` is intentionally non-firing so the UI can
    /// wire up before any verbs land.
    public func load(_ script: WalkthroughScript) {
        self.script = script
        self.stepIndex = -1
        self.state = .idle
    }

    // MARK: - Transport

    /// Advance to the next step. No-op if no script is loaded or we're
    /// already on the last step (state transitions to `.done` once we
    /// step off the end).
    public func next() {
        guard let script else { return }
        guard stepIndex + 1 < script.steps.count else {
            state = .done
            return
        }
        stepIndex += 1
        state = .playing
        applyCurrent()
    }

    /// Step back one. No-op at index 0 or before-first. Re-applies the
    /// target step's actions — verbs are required to be idempotent
    /// (design §5 invariants).
    public func previous() {
        guard script != nil else { return }
        guard stepIndex > 0 else { return }
        stepIndex -= 1
        state = .playing
        applyCurrent()
    }

    /// Jump to a step by id. Throws if the id isn't in the loaded
    /// script — callers (the TOC popover) own the id list so a miss is
    /// a programming error, not a runtime branch.
    public func jumpTo(stepID: String) throws {
        guard let script else { throw EngineError.noScriptLoaded }
        guard let idx = script.steps.firstIndex(where: { $0.id == stepID }) else {
            throw EngineError.unknownStepID(stepID)
        }
        stepIndex = idx
        state = .playing
        applyCurrent()
    }

    /// Return to step 0 and re-apply it. Equivalent to `load` + `next`
    /// but cheaper (skips the script swap).
    public func restart() {
        guard let script, !script.steps.isEmpty else { return }
        stepIndex = 0
        state = .playing
        applyCurrent()
    }

    /// Mark the engine paused. The engine itself has no timers in v1;
    /// the UI strip checks `state == .paused` to halt its dwell timer.
    public func pause() {
        guard state == .playing else { return }
        state = .paused
    }

    /// Resume after pause. Does not re-apply the current step — the
    /// effects are still on screen.
    public func resume() {
        guard state == .paused else { return }
        state = .playing
    }

    // MARK: - Private

    private func applyCurrent() {
        guard let script else { return }
        guard stepIndex >= 0, stepIndex < script.steps.count else { return }
        let step = script.steps[stepIndex]
        let delegate = self.delegate
        delegate?.walkthroughEngine(self, willApplyStep: step)
        for action in step.actions {
            delegate?.walkthroughEngine(self, apply: action, in: step)
        }
        delegate?.walkthroughEngine(self, didApplyStep: step)
    }
}

// MARK: - Delegate

/// UI-side adapter that turns engine-emitted actions into nonce bumps
/// on `DocumentModel` (or whatever the host's request channel is).
/// Methods are `@MainActor` because the engine itself runs on the
/// main actor and the delegate is invoked synchronously from the
/// engine — there is no actor hop to worry about.
@MainActor
public protocol WalkthroughEngineDelegate: AnyObject {

    /// Called once per step before any of its actions are applied.
    /// Useful for clearing transient overlays from the previous step.
    func walkthroughEngine(
        _ engine: WalkthroughEngine,
        willApplyStep step: Step
    )

    /// One call per `Action` in the step, in declared order.
    func walkthroughEngine(
        _ engine: WalkthroughEngine,
        apply action: Action,
        in step: Step
    )

    /// Called once per step after every action has been dispatched.
    func walkthroughEngine(
        _ engine: WalkthroughEngine,
        didApplyStep step: Step
    )
}

public extension WalkthroughEngineDelegate {
    func walkthroughEngine(
        _ engine: WalkthroughEngine,
        willApplyStep step: Step
    ) {}
    func walkthroughEngine(
        _ engine: WalkthroughEngine,
        didApplyStep step: Step
    ) {}
}

// MARK: - Errors

public enum EngineError: Error, Equatable, Sendable {
    case noScriptLoaded
    case unknownStepID(String)
}
