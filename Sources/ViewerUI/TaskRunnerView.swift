import SwiftUI
import ViewerCore

/// TSK-1160 — the Task Runner panel. Lists the runnable tasks discovered from the project's
/// manifests (package.json / Cargo / Makefile), runs the selected one (off-main, bounded),
/// and shows its captured output / error.
///
/// Pure view over the host-tested `TaskRunnerViewModel`; presentation wiring (DocumentModel
/// flag + menu trigger) is the render companion. VM-validated like the Script Console (TSK-698).
struct TaskRunnerView: View {
    @ObservedObject var vm: TaskRunnerViewModel
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            taskList
            outputArea
        }
        .padding(12)
        .frame(minWidth: 520, minHeight: 400)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Task Runner").font(.headline)
            Spacer()
            Button(vm.isRunning ? "Running…" : "Run") {
                guard let id = vm.selectedTaskID,
                      let task = vm.tasks.first(where: { $0.id == id }) else { return }
                Task { await vm.run(task) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(vm.isRunning || vm.selectedTaskID == nil)
            .accessibilityIdentifier("mdv.taskRunner.run")
            if let onClose {
                Button("Close") { onClose() }
                    .accessibilityIdentifier("mdv.taskRunner.close")
            }
        }
    }

    @ViewBuilder private var taskList: some View {
        if vm.tasks.isEmpty {
            Text("No runnable tasks found (package.json scripts / Cargo / Makefile).")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("mdv.taskRunner.empty")
        } else {
            List(vm.tasks, selection: $vm.selectedTaskID) { task in
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name)
                    Text("\(task.source.rawValue) · \(task.argv.joined(separator: " "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 120, maxHeight: 180)
            .accessibilityIdentifier("mdv.taskRunner.list")
        }
    }

    @ViewBuilder private var outputArea: some View {
        ScrollView {
            if let err = vm.errorMessage, vm.output.isEmpty {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("mdv.taskRunner.error")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    if let err = vm.errorMessage {
                        Text(err).foregroundStyle(.red).font(.system(.caption, design: .monospaced))
                    }
                    Text(vm.output.isEmpty ? "— select a task and Run —" : vm.output)
                        .foregroundStyle(vm.output.isEmpty ? .secondary : .primary)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("mdv.taskRunner.output")
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity, alignment: .topLeading)
    }
}
