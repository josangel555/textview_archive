import XCTest
@testable import ViewerUI
import ViewerCore

/// TSK-1176 — the TerminalModel ↔ command-history WIRING (the accumulator's deep
/// command-boundary logic is covered by `TerminalInputLineAccumulatorTests`). Proves
/// input sent to the terminal is recorded as commands via the real send path.
/// Host-safe: the PTY is never started, so `pty.write`/`writeString` no-op
/// (`guard masterFD >= 0`); no shell, no window.
@MainActor
final class TerminalModelHistoryTests: XCTestCase {

    private func freshHistory() -> TerminalCommandHistory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tmhist-\(UUID().uuidString).json")
        return TerminalCommandHistory(storeURL: url)
    }

    func test_sendString_typedCommand_isRecorded() {
        let hist = freshHistory()
        let model = TerminalModel(commandHistory: hist)
        model.sendString("ls -la\r")
        XCTAssertEqual(hist.all, ["ls -la"])
    }

    func test_sendString_multipleCommands_recordedMRU() {
        let hist = freshHistory()
        let model = TerminalModel(commandHistory: hist)
        model.sendString("first\r")
        model.sendString("second\r")
        XCTAssertEqual(hist.all, ["second", "first"])   // MRU, newest first
    }

    func test_sendInputData_isRecorded() {
        let hist = freshHistory()
        let model = TerminalModel(commandHistory: hist)
        model.sendInput(Data("echo hi\r".utf8))
        XCTAssertEqual(hist.all, ["echo hi"])
    }

    func test_perKeystroke_thenEnter_recordsExactlyOnce() {
        let hist = freshHistory()
        let model = TerminalModel(commandHistory: hist)
        for ch in "pwd" { model.sendString(String(ch)) }
        XCTAssertEqual(hist.all, [], "must not record until Enter")
        model.sendString("\r")
        XCTAssertEqual(hist.all, ["pwd"])
    }

    func test_escapeEditedLine_notRecorded() {
        let hist = freshHistory()
        let model = TerminalModel(commandHistory: hist)
        // Up-arrow recall mid-line → untrackable → dropped, no garbage recorded.
        model.sendString("ls\u{1b}[A\r")
        XCTAssertEqual(hist.all, [])
    }
}
