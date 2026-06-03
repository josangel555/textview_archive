import Foundation
import ViewerCore

/// Auto-advance scheduler for the walkthrough player. Owns the single
/// in-flight `Task` that, after the current step's dwell elapses,
/// calls `next()` on the bound `WalkthroughEngine`.
///
/// Design notes:
///
/// - The engine is timer-free by design (`WalkthroughEngine.swift`
///   §threading) — auto-advance belongs to the UI strip. This type IS
///   that strip's clock.
///
/// - We expose pure-logic `effectiveDwell(forStepDwell:speed:default:)`
///   so the dwell math has a host-runnable unit test independent of
///   `Task.sleep`. The schedule itself is async, but the math isn't.
///
/// - Pause / awaiting-user / speed change all cancel the in-flight
///   task; the next schedule is computed from the *current* dwell and
///   *current* speed.
///
/// - We DON'T use a wall-clock target ("advance at T+dwell"). We treat
///   each `schedule` call as a fresh dwell — pausing for 30 seconds
///   then resuming gives the user another full dwell to read. The UX
///   trade-off is intentional: a tour the user paused to think about
///   shouldn't blow through the next step the moment they unpause.
@MainActor
public final class WalkthroughAutoAdvance {

    public enum Speed: Double, Sendable, CaseIterable, Equatable {
        case x1   = 1.0
        case x1_5 = 1.5
        case x2   = 2.0

        public var label: String {
            switch self {
            case .x1:   return "1x"
            case .x1_5: return "1.5x"
            case .x2:   return "2x"
            }
        }
    }

    /// Default per-step dwell in milliseconds when the script omits
    /// `dwellSec`. Matches the design doc's STEP_MS = 9000.
    public static let defaultStepMs: Double = 9000

    /// Active speed. Mutating reschedules with the new value if a
    /// schedule is in flight.
    public private(set) var speed: Speed = .x1

    public var isRunning: Bool { task != nil }

    /// Invoked on the main actor immediately after an auto-fired
    /// `engine.next()` advances a step. The host wires this to its
    /// "re-arm the dwell timer for the now-current step" logic
    /// (`scheduleAdvanceIfNeeded`). Without it the scheduler would
    /// advance exactly once and stall: the in-flight Task calls
    /// `engine.next()` directly (bypassing the controller's `next()`),
    /// so nothing re-schedules unless the host's view lifecycle happens
    /// to fire — which it doesn't when the window is occluded. Making
    /// the clock re-arm itself here removes that fragile dependency.
    public var onAdvance: (() -> Void)?

    private weak var engine: WalkthroughEngine?
    private var task: Task<Void, Never>?
    /// Snapshot of the dwell that the in-flight schedule was based on,
    /// so a speed change can reschedule from the same target step.
    private var currentDwellSec: Double?

    public init(engine: WalkthroughEngine? = nil) {
        self.engine = engine
    }

    public func bind(engine: WalkthroughEngine) {
        self.engine = engine
    }

    // MARK: - Pure-logic dwell math (host-testable)

    /// Compute the wall-clock seconds to wait before firing `next()`.
    ///
    /// - `stepDwellSec`: per-step override from the script (may be nil).
    /// - `speed`: playback multiplier (1x / 1.5x / 2x).
    /// - `defaultStepMs`: fallback when stepDwellSec is nil.
    ///
    /// Guarded against zero/negative speed (would divide-by-zero); the
    /// `Speed` enum's raw values are positive so this is defense-in-
    /// depth, not a reachable path.
    public static func effectiveDwell(
        forStepDwell stepDwellSec: Double?,
        speed: Speed,
        defaultStepMs: Double = WalkthroughAutoAdvance.defaultStepMs
    ) -> Double {
        let baseSec = stepDwellSec ?? (defaultStepMs / 1000.0)
        let mult = max(0.0001, speed.rawValue)
        return max(0.0, baseSec / mult)
    }

    // MARK: - Transport

    /// Schedule auto-advance for the current step. Cancels any prior
    /// schedule. Called from the player view's `onAppear` /
    /// `didApplyStep` hook.
    public func schedule(forStepDwell stepDwellSec: Double?) {
        cancel()
        guard let engine else { return }
        currentDwellSec = stepDwellSec
        let dwell = Self.effectiveDwell(
            forStepDwell: stepDwellSec, speed: speed
        )
        // Skip the Task hop when dwell is zero (e.g. a deliberate
        // "advance immediately" override). Without this we'd still
        // queue a no-sleep task and pay the actor-hop cost.
        if dwell <= 0 {
            engine.next()
            // Re-arm for the now-current step. The early-return path
            // bypasses the Task, so without this a zero-dwell chain
            // would advance exactly one step and stall (see onAdvance).
            onAdvance?()
            return
        }
        let nanos = UInt64(dwell * 1_000_000_000)
        task = Task { [weak self, weak engine] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // Re-check engine state at fire time. The engine may have
            // moved to paused / done in the gap (user click during
            // sleep), in which case we silently drop the advance —
            // resume() will re-schedule.
            guard let engine, engine.state == .playing else { return }
            self.task = nil
            engine.next()
            // Re-arm the clock for the step we just landed on. The Task
            // calls engine.next() directly, bypassing the controller's
            // next(), so this is the only thing that schedules the
            // following step (see onAdvance).
            self.onAdvance?()
        }
    }

    /// Cancel the in-flight advance, if any. Idempotent.
    public func cancel() {
        task?.cancel()
        task = nil
    }

    /// Change playback speed. If a schedule is in flight, restart it
    /// with the new speed against the same target step. The remaining
    /// dwell is NOT computed from elapsed time — we simply reschedule
    /// a full dwell at the new speed. See type-level note on why.
    public func setSpeed(_ new: Speed) {
        guard new != speed else { return }
        speed = new
        if task != nil {
            schedule(forStepDwell: currentDwellSec)
        }
    }
}
