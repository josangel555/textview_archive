import Foundation
import ViewerCore

/// TSK-1160 — controller for the Task Runner panel (the UI over the host-built discovery +
/// run-spec, TSK-722). Discovers runnable tasks from a project's manifests
/// (package.json / Cargo / Makefile), lists them, and runs a selected one with captured
/// output. The run goes through `ProcessRunner` (bounded: output cap + timeout + resource
/// limits) off the main thread, so a long/runaway task never hangs the UI.
///
/// Host-tested model layer; the SwiftUI panel + DocumentModel wiring + trigger are the
/// render companions (VM-validated like the Script Console, TSK-698).
@MainActor
public final class TaskRunnerViewModel: ObservableObject {

    /// Discovered runnable tasks (manifest order).
    @Published public private(set) var tasks: [RunnableTask] = []
    /// The selected task's id (drives the list selection + which task Run executes).
    @Published public var selectedTaskID: RunnableTask.ID?
    /// Captured stdout+stderr of the last run.
    @Published public private(set) var output: String = ""
    /// True while a task is executing (drives the spinner / disables Run).
    @Published public private(set) var isRunning = false
    /// A human error (spawn failure, non-zero exit, timeout) from the last run, or nil.
    @Published public private(set) var errorMessage: String?

    /// The project root tasks were discovered from (nil before discovery).
    public private(set) var projectRoot: URL?

    public init(projectRoot: URL? = nil) {
        if let projectRoot { discover(at: projectRoot) }
    }

    /// Discover runnable tasks under `root` (package.json scripts / Cargo / Makefile / …).
    public func discover(at root: URL) {
        projectRoot = root
        tasks = RunnableTaskDiscovery.discover(projectRoot: root)
        if selectedTaskID == nil { selectedTaskID = tasks.first?.id }
    }

    /// Run `task` (via env-PATH-resolved spawn through the bounded ProcessRunner) off-main,
    /// publishing combined output + a non-zero/timeout error. Output is capped at 1 MiB.
    public func run(_ task: RunnableTask, timeout: TimeInterval = 120) async {
        isRunning = true
        errorMessage = nil
        output = ""
        let argv = task.argv
        let cwd = task.workingDirectory
        // ProcessRunner.Result is Sendable; an Error is not — surface it as a String.
        let outcome: (result: ProcessRunner.Result?, error: String?) = await Task.detached {
            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = argv
                process.currentDirectoryURL = cwd
                let r = try ProcessRunner.run(process, timeout: timeout, maxOutputBytes: 1 << 20)
                return (r, nil)
            } catch {
                return (nil, "\(error)")
            }
        }.value
        isRunning = false
        guard let r = outcome.result else {
            errorMessage = "Failed to run: \(outcome.error ?? "unknown error")"
            return
        }
        let out = String(data: r.stdout, encoding: .utf8) ?? ""
        let err = String(data: r.stderr, encoding: .utf8) ?? ""
        output = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
        if r.timedOut {
            errorMessage = "Task timed out after \(Int(timeout))s."
        } else if r.terminationStatus != 0 {
            errorMessage = "Task exited with status \(r.terminationStatus)."
        }
    }
}
