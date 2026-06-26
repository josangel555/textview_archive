import XCTest
@testable import ViewerCore

/// MacroController (TSK-1162) — the stateful holder that wires the pure
/// MacroRecorder into record/replay over the live command surface. Host-tested
/// with a spy dispatcher; the production dispatcher (forwarding to
/// ScriptVerb.apply) + the verb-dispatch record-hook are the Slice-B integration.
@MainActor
final class MacroControllerTests: XCTestCase {

    private func registry() -> CommandRegistry {
        CommandRegistry(commands: [
            CommandDescriptor(id: "edit.up", title: "Up", category: .edit, scriptVerb: "edit-up"),
            CommandDescriptor(id: "edit.down", title: "Down", category: .edit, scriptVerb: "edit-down"),
            CommandDescriptor(id: "edit.noverb", title: "NoVerb", category: .edit),
        ])
    }

    /// Captures the command ids it is asked to dispatch (mirrors ScriptVerb.apply's
    /// success contract).
    private struct Spy: MacroDispatcher {
        var dispatched: [String] = []
        mutating func dispatch(command: CommandDescriptor, args: [String: String]) -> Bool {
            dispatched.append(command.id)
            return true
        }
    }

    // MARK: - CommandRegistry reverse lookup (the record-hook's mapping)

    func test_registry_descriptorForScriptVerb_reverseLookup() {
        let reg = registry()
        XCTAssertEqual(reg.descriptor(forScriptVerb: "edit-up")?.id, "edit.up")
        XCTAssertEqual(reg.descriptor(forScriptVerb: "edit-down")?.id, "edit.down")
        XCTAssertNil(reg.descriptor(forScriptVerb: "edit-nonexistent"))
        XCTAssertNil(reg.descriptor(forScriptVerb: ""), "empty verb maps to nothing")
    }

    // MARK: - Record → replay

    func test_record_then_replayLast_redispatchesInOrder() {
        let c = MacroController(registry: registry())
        c.startRecording()
        c.recordVerb("edit-up")
        c.recordVerb("edit-down")
        c.recordVerb("edit-up")
        let macro = c.finishRecording(name: "M")
        XCTAssertEqual(macro.steps.map(\.commandID), ["edit.up", "edit.down", "edit.up"])
        var spy = Spy()
        c.replayLast(on: &spy)
        XCTAssertEqual(spy.dispatched, ["edit.up", "edit.down", "edit.up"],
                       "replay re-dispatches the recorded commands in order")
    }

    func test_recordVerb_whenNotRecording_capturesNothing() {
        let c = MacroController(registry: registry())
        c.recordVerb("edit-up")        // not recording → ignored
        let macro = c.finishRecording()
        XCTAssertTrue(macro.isEmpty, "verbs dispatched outside a recording aren't captured")
    }

    func test_unknownVerb_isNotRecorded() {
        let c = MacroController(registry: registry())
        c.startRecording()
        c.recordVerb("edit-up")
        c.recordVerb("edit-does-not-exist")   // maps to no command → skipped
        let macro = c.finishRecording()
        XCTAssertEqual(macro.steps.map(\.commandID), ["edit.up"],
                       "a verb with no registered command is skipped")
    }

    func test_replayLast_withNoMacro_isEmptyNoOp() {
        let c = MacroController(registry: registry())
        var spy = Spy()
        let results = c.replayLast(on: &spy)
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(spy.dispatched.isEmpty)
    }

    func test_isReplaying_resetsAfterReplay() {
        let c = MacroController(registry: registry())
        c.startRecording(); c.recordVerb("edit-up"); c.finishRecording()
        XCTAssertFalse(c.isReplaying)
        var spy = Spy()
        c.replayLast(on: &spy)
        XCTAssertFalse(c.isReplaying, "isReplaying resets after replay (the re-entrancy guard window closes)")
    }

    func test_cancelRecording_discardsInFlight() {
        let c = MacroController(registry: registry())
        c.startRecording()
        c.recordVerb("edit-up")
        c.cancelRecording()
        XCTAssertFalse(c.isRecording)
        // A fresh finish (no active recording) yields an empty macro.
        let macro = c.finishRecording()
        XCTAssertTrue(macro.isEmpty, "cancel discards the captured steps")
    }

    func test_isRecording_reflectsLifecycle() {
        // The @Published isRecording drives the StatusBar recording indicator
        // (TSK-1162 vm slice) — verify it tracks the record lifecycle.
        let c = MacroController(registry: registry())
        XCTAssertFalse(c.isRecording)
        c.startRecording()
        XCTAssertTrue(c.isRecording, "true while recording")
        _ = c.finishRecording()
        XCTAssertFalse(c.isRecording, "clears when recording stops")
        c.startRecording()
        c.cancelRecording()
        XCTAssertFalse(c.isRecording, "cancel also clears it")
    }
}
