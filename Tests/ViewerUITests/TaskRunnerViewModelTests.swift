import XCTest
import ViewerCore
@testable import ViewerUI

/// TSK-1160 — the Task Runner controller. Pins discover (package.json scripts) + the
/// run-with-captured-output path (real subprocess via ProcessRunner). The SwiftUI panel is
/// the render companion (VM-validated separately).
@MainActor
final class TaskRunnerViewModelTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TaskRunnerVMTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tmpDir { try? FileManager.default.removeItem(at: tmpDir) }
    }

    func test_discover_findsPackageJsonScripts_andAutoSelectsFirst() throws {
        try #"{"scripts":{"test":"echo hi","build":"echo b"}}"#
            .write(to: tmpDir.appendingPathComponent("package.json"),
                   atomically: true, encoding: .utf8)
        let vm = TaskRunnerViewModel()
        vm.discover(at: tmpDir)
        XCTAssertFalse(vm.tasks.isEmpty, "should discover the package.json scripts")
        XCTAssertTrue(vm.tasks.contains { $0.name.contains("test") })
        XCTAssertEqual(vm.selectedTaskID, vm.tasks.first?.id, "first task auto-selected")
    }

    func test_run_capturesOutput() async {
        let task = RunnableTask(name: "echo", command: "echo",
                                arguments: ["task-runner-ok"], workingDirectory: tmpDir,
                                source: .commonTestCommand)
        let vm = TaskRunnerViewModel()
        await vm.run(task)
        XCTAssertFalse(vm.isRunning)
        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(vm.output.contains("task-runner-ok"), "captured stdout; got \(vm.output)")
    }

    func test_run_nonZeroExit_setsError() async {
        let task = RunnableTask(name: "false", command: "false",
                                arguments: [], workingDirectory: tmpDir,
                                source: .commonTestCommand)
        let vm = TaskRunnerViewModel()
        await vm.run(task)
        XCTAssertNotNil(vm.errorMessage, "a non-zero exit must surface an error")
    }
}
