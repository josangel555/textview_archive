import SwiftUI
import ViewerCore

/// TSK-698 slice 3b — the Script Console panel. A query/transform console over the active
/// buffer: pick the input format (JSON / log lines / CSV), type a JS expression
/// (`input` / `$` = the parsed buffer), Run it (off-main with a soft timeout via the
/// view-model), and see pretty-printed output or a one-line error. "Apply →" hands the
/// output to the presenter (opens it in a new tab).
///
/// Pure view over the host-tested `ScriptConsoleViewModel`; the presentation wiring
/// (DocumentModel flag + menu/command trigger) is the companion slice. Validated on the VM.
struct ScriptConsoleView: View {
    @ObservedObject var vm: ScriptConsoleViewModel
    /// Hand the current output to the app (e.g. open it in a new tab). Nil disables Apply.
    var onApply: ((String) -> Void)?
    /// Dismiss the console. Nil hides the Close button (e.g. when hosted in a sheet's chrome).
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            TextField("expression — input / $ is the parsed buffer", text: $vm.expression, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("mdv.scriptConsole.expression")
            resultArea
        }
        .padding(12)
        .frame(minWidth: 480, minHeight: 360)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("Input", selection: $vm.inputFormat) {
                Text("JSON").tag(JSTransform.InputFormat.json)
                Text("Lines").tag(JSTransform.InputFormat.lines)
                Text("CSV").tag(JSTransform.InputFormat.csv)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 240)
            .accessibilityIdentifier("mdv.scriptConsole.formatPicker")

            Spacer()

            Button(vm.isRunning ? "Running…" : "Run") { Task { await vm.run() } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(vm.isRunning)
                .accessibilityIdentifier("mdv.scriptConsole.run")

            Button("Apply →") { onApply?(vm.output) }
                .disabled(vm.output.isEmpty || onApply == nil)
                .accessibilityIdentifier("mdv.scriptConsole.apply")

            if let onClose {
                Button("Close") { onClose() }
                    .accessibilityIdentifier("mdv.scriptConsole.close")
            }
        }
    }

    @ViewBuilder private var resultArea: some View {
        ScrollView {
            if let err = vm.errorMessage {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("mdv.scriptConsole.error")
            } else {
                Text(vm.output.isEmpty ? "— run an expression to see output —" : vm.output)
                    .foregroundStyle(vm.output.isEmpty ? .secondary : .primary)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("mdv.scriptConsole.output")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity, alignment: .topLeading)
    }
}
