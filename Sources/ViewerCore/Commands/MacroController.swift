import Foundation

/// Stateful `@MainActor` coordinator that wires the pure `MacroRecorder`
/// (TSK-957) into the live command surface (TSK-1162): it holds the in-flight
/// recording + the last finished macro, maps dispatched script-verbs back to
/// command ids for capture, and replays through an injected `MacroDispatcher`
/// with a re-entrancy guard so a replay's own dispatches are never re-recorded.
///
/// The record/replay LOGIC stays in the pure `MacroRecorder`; this is the small
/// stateful holder the verb dispatch reaches. Dispatcher-injected, so the
/// record→replay loop is host-unit-testable with a spy; the production caller
/// (ViewerUI) injects a dispatcher that forwards to `ScriptVerb.apply`. The
/// record-hook + the macro-control verbs that drive this live in the verb
/// dispatch (Slice B); the hotkey / recording-indicator / management UI are the
/// render/VM tail.
@MainActor
public final class MacroController {
    private var recorder: MacroRecorder
    /// The most recently finished macro, replayable via `replayLast`.
    public private(set) var lastMacro: Macro?
    /// True while a replay is in flight — `recordVerb` checks this so a replay's
    /// own dispatches are never re-captured into a concurrent recording.
    public private(set) var isReplaying = false

    public init(registry: CommandRegistry) {
        self.recorder = MacroRecorder(registry: registry)
    }

    /// True while actively capturing dispatched verbs.
    public var isRecording: Bool { recorder.isRecording }

    public func startRecording() { recorder.startRecording() }

    /// Stop recording, store the captured steps as `lastMacro`, and return it.
    @discardableResult
    public func finishRecording(name: String = "Macro") -> Macro {
        let macro = recorder.finishRecording(name: name)
        lastMacro = macro
        return macro
    }

    public func cancelRecording() { recorder.cancelRecording() }

    /// Capture one dispatched script-verb into the in-flight recording, mapping
    /// the verb back to its command id via the registry. No-op when not
    /// recording, while replaying (so a replay never records itself), or when
    /// the verb maps to no command / a non-replayable one (the recorder gates).
    public func recordVerb(_ verb: String) {
        guard recorder.isRecording, !isReplaying else { return }
        guard let descriptor = recorder.registry.descriptor(forScriptVerb: verb) else { return }
        recorder.record(commandID: descriptor.id)
    }

    /// Replay `lastMacro` through `dispatcher`, guarding re-entrancy so the
    /// replay's dispatches aren't re-captured. Returns the per-step results, or
    /// empty when there is no macro to replay.
    @discardableResult
    public func replayLast<D: MacroDispatcher>(on dispatcher: inout D) -> [MacroStepResult] {
        guard let macro = lastMacro else { return [] }
        isReplaying = true
        defer { isReplaying = false }
        return recorder.replay(macro: macro, on: &dispatcher)
    }
}
