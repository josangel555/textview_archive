import Foundation

/// One recorded step of a command macro (TSK-957): a command id plus the
/// serializable arguments it was invoked with.
///
/// The id is a `CommandRegistry` command id (e.g. `"edit.trimTrailing"`); the
/// args are a small, order-independent string→string map (e.g. a path, a
/// count). Most replayable commands today take no args, but keeping the slot
/// means a macro can capture arg-bearing verbs without a schema change. The
/// type is `Codable` so a macro can be persisted to disk and round-tripped.
public struct CommandInvocation: Sendable, Hashable, Codable {
    /// `CommandRegistry` command id this step invokes.
    public let commandID: String
    /// Serializable arguments captured at record time, empty for the common
    /// no-arg case. Kept as `String` values so the whole macro is JSON-safe.
    public let args: [String: String]

    public init(commandID: String, args: [String: String] = [:]) {
        self.commandID = commandID
        self.args = args
    }
}

/// An ordered, named sequence of command invocations that can be replayed
/// (TSK-957). Pure value type — `Codable` so it persists to disk.
public struct Macro: Sendable, Hashable, Codable, Identifiable {
    /// Stable identity for the macro (defaults to a fresh UUID string).
    public let id: String
    /// Human label shown in the macros menu / palette.
    public var name: String
    /// The recorded steps, in invocation order.
    public var steps: [CommandInvocation]

    public init(id: String = UUID().uuidString, name: String, steps: [CommandInvocation] = []) {
        self.id = id
        self.name = name
        self.steps = steps
    }

    /// `true` when the macro has no steps to replay.
    public var isEmpty: Bool { steps.isEmpty }
}

/// Why a command could not be captured into a macro (TSK-957).
public enum MacroRecordRejection: Error, Sendable, Equatable {
    /// The command id is not in the registry.
    case unknownCommand(id: String)
    /// The command is pointer/selection-dependent or interactive-prompt and is
    /// marked `.excluded` — it cannot be deterministically replayed.
    case notReplayable(id: String)
}

/// The outcome of replaying one macro step (TSK-957).
public enum MacroStepResult: Sendable, Equatable {
    /// The step was dispatched.
    case dispatched(commandID: String)
    /// The step was skipped because the command id is unknown to the registry.
    case skippedUnknown(commandID: String)
    /// The step was skipped because the command is `.excluded` from replay.
    /// (Defence in depth: `record` refuses these up front, but a macro loaded
    /// from disk — possibly authored against an older catalog — is re-checked.)
    case skippedNotReplayable(commandID: String)
    /// The step dispatched into the registry but the dispatcher reported the
    /// command was not recognised / not applied (e.g. a window-coupled verb).
    case dispatchFailed(commandID: String)
}

/// Dispatches a single command invocation against the live app surface.
///
/// `MacroRecorder.replay` is pure — it walks the macro, consults the registry
/// for the replayability gate, and hands each safe step to this sink. A
/// production implementation forwards to `ScriptVerb.apply` (using the
/// descriptor's `scriptVerb`); a test passes a spy that records the calls.
/// Keeping it a protocol is what lets the recorder + replay logic live in pure
/// ViewerCore with full host-side test coverage, away from `@MainActor` model
/// state.
public protocol MacroDispatcher {
    /// Invoke `command` with `args`. Return `true` if the command was
    /// recognised and applied, `false` otherwise (mirrors
    /// `ScriptVerb.apply`'s contract). The recorder maps `false` to
    /// `.dispatchFailed`.
    mutating func dispatch(command: CommandDescriptor, args: [String: String]) -> Bool
}

/// Records a sequence of invoked commands and replays them through the registry
/// (TSK-957). Pure model — no AppKit, no `@MainActor`, no I/O — so the whole
/// record→classify→replay loop is host-unit-testable.
///
/// ## Record-time gate vs replay-time gate
///
/// The replayability classifier (`CommandReplayability` on the registry entry)
/// is enforced at BOTH ends:
///   - `record` *refuses* an `.excluded` (or unknown) command, returning the
///     reason — so a recording never captures a step it can't faithfully
///     reproduce.
///   - `replay` *re-checks* every step against the registry and *skips*
///     `.excluded`/unknown ones. This matters for macros loaded from disk that
///     may have been authored against a different catalog version, and keeps
///     replay safe even if a caller bypasses `record` to build a `Macro`
///     directly.
public struct MacroRecorder {

    /// The registry whose `replayability` flags gate record + replay.
    public let registry: CommandRegistry

    /// The steps captured so far, in invocation order.
    public private(set) var recorded: [CommandInvocation]

    /// `true` while actively capturing invocations.
    public private(set) var isRecording: Bool

    public init(registry: CommandRegistry) {
        self.registry = registry
        self.recorded = []
        self.isRecording = false
    }

    // MARK: - Recording lifecycle

    /// Begin a fresh recording, discarding any previously captured steps.
    public mutating func startRecording() {
        recorded.removeAll(keepingCapacity: true)
        isRecording = true
    }

    /// Stop recording and return the macro built from the captured steps.
    /// `name` labels the macro; the steps are a snapshot (further `record`
    /// calls after `finish` are ignored until the next `startRecording`).
    public mutating func finishRecording(name: String) -> Macro {
        isRecording = false
        return Macro(name: name, steps: recorded)
    }

    /// Discard the in-flight recording without producing a macro.
    public mutating func cancelRecording() {
        recorded.removeAll(keepingCapacity: true)
        isRecording = false
    }

    // MARK: - Record one invocation

    /// Append an invoked command to the recording, enforcing the replayability
    /// gate.
    ///
    /// - Returns: `.success` with the captured invocation, or `.failure` with
    ///   the reason it was refused (`unknownCommand` / `notReplayable`). A
    ///   refusal does NOT mutate the recording, and is a no-op when not
    ///   currently recording (returns `.failure(.notReplayable)` only on a real
    ///   gate violation — a non-recording call returns success without
    ///   capturing, see below).
    ///
    /// Calling `record` while `isRecording == false` is a deliberate no-op that
    /// reports success: the app dispatches commands all the time; only the ones
    /// invoked *during* a recording should be captured. The caller need not
    /// guard every dispatch site — it can hand every invocation to the recorder
    /// and let `isRecording` decide.
    @discardableResult
    public mutating func record(
        commandID: String,
        args: [String: String] = [:]
    ) -> Result<CommandInvocation, MacroRecordRejection> {
        guard let descriptor = registry.command(id: commandID) else {
            return .failure(.unknownCommand(id: commandID))
        }
        guard descriptor.isMacroReplayable else {
            return .failure(.notReplayable(id: commandID))
        }
        let invocation = CommandInvocation(commandID: commandID, args: args)
        if isRecording {
            recorded.append(invocation)
        }
        return .success(invocation)
    }

    // MARK: - Replay

    /// Re-dispatch every step of `macro` through `dispatcher`, in order,
    /// skipping any step whose command is now unknown or `.excluded`.
    ///
    /// - Returns: a per-step result list (same length + order as
    ///   `macro.steps`), so a caller can surface which steps ran, which were
    ///   skipped, and which the dispatcher rejected.
    @discardableResult
    public func replay<D: MacroDispatcher>(
        macro: Macro,
        on dispatcher: inout D
    ) -> [MacroStepResult] {
        var results: [MacroStepResult] = []
        results.reserveCapacity(macro.steps.count)
        for step in macro.steps {
            guard let descriptor = registry.command(id: step.commandID) else {
                results.append(.skippedUnknown(commandID: step.commandID))
                continue
            }
            guard descriptor.isMacroReplayable else {
                results.append(.skippedNotReplayable(commandID: step.commandID))
                continue
            }
            let applied = dispatcher.dispatch(command: descriptor, args: step.args)
            results.append(applied
                ? .dispatched(commandID: step.commandID)
                : .dispatchFailed(commandID: step.commandID))
        }
        return results
    }
}
