import XCTest
@testable import ViewerUI
import ViewerCore

/// TSK-698 slice 3 (host core) — the Script Console controller. Pins the run/error/
/// timeout state machine the (render-tail) SwiftUI panel binds to. The on-screen panel
/// + menu trigger + apply-to-new-tab are the VM/owner tail.
@MainActor
final class ScriptConsoleViewModelTests: XCTestCase {

    func test_run_validExpression_setsOutput_clearsError() async {
        let vm = ScriptConsoleViewModel(inputContent: "[1,2,3]")
        vm.expression = "input.map(x => x * 2)"
        await vm.run()
        XCTAssertEqual(vm.output, "[\n  2,\n  4,\n  6\n]")
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isRunning)
    }

    func test_run_badExpression_setsError_clearsOutput() async {
        let vm = ScriptConsoleViewModel(inputContent: "{}")
        vm.expression = "input.nope.boom"   // TypeError: reading .boom of undefined
        await vm.run()
        XCTAssertEqual(vm.output, "")
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertFalse(vm.isRunning)
    }

    func test_run_linesFormat_filtersLog() async {
        let vm = ScriptConsoleViewModel(inputContent: "INFO a\nERROR b\nINFO c\n")
        vm.inputFormat = .lines
        vm.expression = #"input.filter(l => l.startsWith("ERROR"))"#
        await vm.run()
        XCTAssertEqual(vm.output, "[\n  \"ERROR b\"\n]")
        XCTAssertNil(vm.errorMessage)
    }

    func test_run_runawayScript_reportsTimeout_clearsOutput() async {
        let vm = ScriptConsoleViewModel(inputContent: "0")
        // Bounded CPU loop that exceeds the 0.1s deadline (no permanent thread leak).
        vm.expression = "(function(){ let s = 0; for (let i = 0; i < 5e8; i++) { s += i; } return s; })()"
        await vm.run(timeout: 0.1)
        XCTAssertEqual(vm.output, "")
        XCTAssertTrue(vm.errorMessage?.contains("timed out") ?? false,
                      "a runaway script should surface a timeout message, got \(String(describing: vm.errorMessage))")
    }

    func test_describe_coversEveryErrorCase() {
        XCTAssertTrue(ScriptConsoleViewModel.describe(.invalidJSON).contains("JSON"))
        XCTAssertTrue(ScriptConsoleViewModel.describe(.jsException("boom")).contains("boom"))
        XCTAssertTrue(ScriptConsoleViewModel.describe(.unserializableResult).contains("serialize"))
        XCTAssertTrue(ScriptConsoleViewModel.describe(.timedOut(2)).contains("timed out"))
    }
}
