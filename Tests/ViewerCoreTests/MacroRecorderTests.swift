import XCTest
@testable import ViewerCore

/// Pure-logic (T1, host-safe) coverage for the command-macro
/// recorder/replayer (TSK-957).
///
/// The whole record → classify → replay loop lives in ViewerCore with no
/// AppKit / `@MainActor` coupling, so these tests construct a hermetic
/// `CommandRegistry`, record a sequence, assert the captured invocation list,
/// and replay through a spy dispatcher — no app, no window.
final class MacroRecorderTests: XCTestCase {

    // MARK: - Fixtures

    /// A spy dispatcher that records every `dispatch` call in order and lets
    /// the test pin which command ids the dispatcher should report as
    /// unrecognised (→ `dispatchFailed`).
    private struct SpyDispatcher: MacroDispatcher {
        private(set) var calls: [(id: String, args: [String: String])] = []
        /// Command ids the dispatcher should report as NOT applied.
        var failingIDs: Set<String> = []

        mutating func dispatch(command: CommandDescriptor, args: [String: String]) -> Bool {
            calls.append((command.id, args))
            return !failingIDs.contains(command.id)
        }
    }

    /// A small hermetic registry: two replayable commands, one explicitly
    /// excluded (pointer/selection-dependent), and one that defaults to
    /// excluded because it has no script verb.
    private func makeRegistry() -> CommandRegistry {
        CommandRegistry(commands: [
            CommandDescriptor(
                id: "edit.trim", title: "Trim", category: .edit,
                scriptVerb: "edit-trim"),                       // → replayable (has verb)
            CommandDescriptor(
                id: "edit.toc", title: "Insert TOC", category: .edit,
                scriptVerb: "edit-insert-toc"),                // → replayable (has verb)
            CommandDescriptor(
                id: "lsp.gotoDef", title: "Go to Definition", category: .lsp,
                scriptVerb: "editor-goto-definition",
                replayability: .excluded),                     // pointer-dependent
            CommandDescriptor(
                id: "file.open", title: "Open…", category: .file,
                scriptVerb: nil),                              // no verb → excluded by default
        ])
    }

    // MARK: - Replayability classifier

    func test_descriptor_defaultReplayability_followsScriptVerb() {
        let withVerb = CommandDescriptor(
            id: "a.b", title: "A", category: .edit, scriptVerb: "v")
        XCTAssertEqual(withVerb.replayability, .replayable)
        XCTAssertTrue(withVerb.isMacroReplayable)

        let noVerb = CommandDescriptor(
            id: "c.d", title: "C", category: .file, scriptVerb: nil)
        XCTAssertEqual(noVerb.replayability, .excluded)
        XCTAssertFalse(noVerb.isMacroReplayable)
    }

    func test_descriptor_explicitExclusion_overridesVerbDefault() {
        // A command WITH a verb can still be explicitly excluded.
        let excluded = CommandDescriptor(
            id: "lsp.goto", title: "Go", category: .lsp,
            scriptVerb: "editor-goto-definition", replayability: .excluded)
        XCTAssertEqual(excluded.replayability, .excluded)
        XCTAssertFalse(excluded.isMacroReplayable)
    }

    /// The real shipped catalog must keep the pointer/selection/prompt commands
    /// excluded — a regression here would let a macro capture a step it can't
    /// faithfully replay.
    func test_builtIn_pointerAndPromptCommands_areExcluded() {
        let r = CommandRegistry.builtIn
        for id in [
            "lsp.gotoDefinition", "lsp.gotoDeclaration", "lsp.gotoTypeDefinition",
            "lsp.gotoImplementation", "lsp.findReferences", "lsp.rename",
            "lsp.codeActions", "sidebar.selectNext", "sidebar.selectPrevious",
            "sidebar.walkUp", "view.quickOpen", "nav.showPalette",
            "find.inFolder", "find.renderedShow", "file.goToPath",
        ] {
            let cmd = r.command(id: id)
            XCTAssertNotNil(cmd, "missing command \(id)")
            XCTAssertEqual(cmd?.replayability, .excluded,
                           "\(id) must be excluded from macros")
        }
        // And the bread-and-butter text transforms stay replayable.
        for id in ["edit.trimTrailingWhitespace", "edit.insertTOC",
                   "view.toggleSidebar", "lsp.format"] {
            XCTAssertEqual(r.command(id: id)?.replayability, .replayable,
                           "\(id) should be replayable")
        }
    }

    func test_applyingOverrides_preservesReplayability() {
        // The override fold rebuilds descriptors; replayability must survive.
        let merged = CommandRegistry.builtIn.applying(
            overrides: ["lsp.gotoDefinition": Shortcut(key: "d", modifiers: [.command])])
        XCTAssertEqual(merged.command(id: "lsp.gotoDefinition")?.replayability, .excluded)
    }

    // MARK: - Recording captures the invocation list

    func test_record_capturesSafeSequenceInOrder() {
        var rec = MacroRecorder(registry: makeRegistry())
        rec.startRecording()
        XCTAssertTrue(rec.record(commandID: "edit.trim").isSuccess)
        XCTAssertTrue(rec.record(commandID: "edit.toc").isSuccess)
        XCTAssertTrue(rec.record(commandID: "edit.trim").isSuccess)

        XCTAssertEqual(rec.recorded.map(\.commandID),
                       ["edit.trim", "edit.toc", "edit.trim"])

        let macro = rec.finishRecording(name: "Tidy")
        XCTAssertEqual(macro.name, "Tidy")
        XCTAssertEqual(macro.steps.map(\.commandID),
                       ["edit.trim", "edit.toc", "edit.trim"])
        XCTAssertFalse(macro.isEmpty)
    }

    func test_record_capturesArgs() {
        var rec = MacroRecorder(registry: makeRegistry())
        rec.startRecording()
        _ = rec.record(commandID: "edit.toc", args: ["depth": "3"])
        XCTAssertEqual(rec.recorded.first?.args, ["depth": "3"])
    }

    // MARK: - Recording refuses unsafe / unknown commands

    func test_record_refusesExcludedCommand_andDoesNotCapture() {
        var rec = MacroRecorder(registry: makeRegistry())
        rec.startRecording()
        _ = rec.record(commandID: "edit.trim")

        let result = rec.record(commandID: "lsp.gotoDef")  // explicitly excluded
        XCTAssertEqual(result.rejection, .notReplayable(id: "lsp.gotoDef"))
        // The excluded step is NOT appended.
        XCTAssertEqual(rec.recorded.map(\.commandID), ["edit.trim"])
    }

    func test_record_refusesNoVerbCommand_asExcluded() {
        var rec = MacroRecorder(registry: makeRegistry())
        rec.startRecording()
        let result = rec.record(commandID: "file.open")   // no verb → excluded default
        XCTAssertEqual(result.rejection, .notReplayable(id: "file.open"))
        XCTAssertTrue(rec.recorded.isEmpty)
    }

    func test_record_refusesUnknownCommand() {
        var rec = MacroRecorder(registry: makeRegistry())
        rec.startRecording()
        let result = rec.record(commandID: "does.not.exist")
        XCTAssertEqual(result.rejection, .unknownCommand(id: "does.not.exist"))
        XCTAssertTrue(rec.recorded.isEmpty)
    }

    func test_record_whileNotRecording_isNoOpButSucceeds() {
        var rec = MacroRecorder(registry: makeRegistry())
        // Not recording: a safe command reports success but isn't captured.
        XCTAssertTrue(rec.record(commandID: "edit.trim").isSuccess)
        XCTAssertTrue(rec.recorded.isEmpty)
        // …and an excluded command is still refused even when not recording.
        XCTAssertEqual(rec.record(commandID: "lsp.gotoDef").rejection,
                       .notReplayable(id: "lsp.gotoDef"))
    }

    func test_cancelRecording_discardsSteps() {
        var rec = MacroRecorder(registry: makeRegistry())
        rec.startRecording()
        _ = rec.record(commandID: "edit.trim")
        rec.cancelRecording()
        XCTAssertTrue(rec.recorded.isEmpty)
        XCTAssertFalse(rec.isRecording)
    }

    // MARK: - Replay re-invokes each safe command in order

    func test_replay_reInvokesEachSafeCommandInOrder() {
        let rec = MacroRecorder(registry: makeRegistry())
        let macro = Macro(name: "Tidy", steps: [
            CommandInvocation(commandID: "edit.trim"),
            CommandInvocation(commandID: "edit.toc", args: ["depth": "2"]),
            CommandInvocation(commandID: "edit.trim"),
        ])
        var spy = SpyDispatcher()
        let results = rec.replay(macro: macro, on: &spy)

        // The spy saw every step, in order, with args preserved.
        XCTAssertEqual(spy.calls.map(\.id), ["edit.trim", "edit.toc", "edit.trim"])
        XCTAssertEqual(spy.calls[1].args, ["depth": "2"])
        XCTAssertEqual(results, [
            .dispatched(commandID: "edit.trim"),
            .dispatched(commandID: "edit.toc"),
            .dispatched(commandID: "edit.trim"),
        ])
    }

    func test_replay_skipsExcludedAndUnknownStepsWithoutDispatching() {
        // A macro (e.g. loaded from disk, authored against an older catalog)
        // containing an excluded + an unknown step: replay re-checks the gate
        // and skips both, never handing them to the dispatcher.
        let rec = MacroRecorder(registry: makeRegistry())
        let macro = Macro(name: "Mixed", steps: [
            CommandInvocation(commandID: "edit.trim"),
            CommandInvocation(commandID: "lsp.gotoDef"),    // excluded
            CommandInvocation(commandID: "gone.away"),      // unknown
            CommandInvocation(commandID: "edit.toc"),
        ])
        var spy = SpyDispatcher()
        let results = rec.replay(macro: macro, on: &spy)

        // Only the two safe steps reached the dispatcher.
        XCTAssertEqual(spy.calls.map(\.id), ["edit.trim", "edit.toc"])
        XCTAssertEqual(results, [
            .dispatched(commandID: "edit.trim"),
            .skippedNotReplayable(commandID: "lsp.gotoDef"),
            .skippedUnknown(commandID: "gone.away"),
            .dispatched(commandID: "edit.toc"),
        ])
    }

    func test_replay_reportsDispatchFailure() {
        let rec = MacroRecorder(registry: makeRegistry())
        let macro = Macro(name: "X", steps: [
            CommandInvocation(commandID: "edit.trim"),
            CommandInvocation(commandID: "edit.toc"),
        ])
        var spy = SpyDispatcher()
        spy.failingIDs = ["edit.toc"]
        let results = rec.replay(macro: macro, on: &spy)
        XCTAssertEqual(results, [
            .dispatched(commandID: "edit.trim"),
            .dispatchFailed(commandID: "edit.toc"),
        ])
    }

    // MARK: - Codable round-trip (persistence)

    func test_macro_codableRoundTrip() throws {
        let macro = Macro(id: "m1", name: "Tidy", steps: [
            CommandInvocation(commandID: "edit.trim"),
            CommandInvocation(commandID: "edit.toc", args: ["depth": "2"]),
        ])
        let data = try JSONEncoder().encode(macro)
        let decoded = try JSONDecoder().decode(Macro.self, from: data)
        XCTAssertEqual(decoded, macro)
    }
}

// MARK: - Result helpers (test-local)

private extension Result where Success == CommandInvocation, Failure == MacroRecordRejection {
    var isSuccess: Bool { if case .success = self { return true }; return false }
    var rejection: MacroRecordRejection? {
        if case .failure(let r) = self { return r }; return nil
    }
}
