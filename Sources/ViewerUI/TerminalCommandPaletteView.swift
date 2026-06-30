import SwiftUI
import ViewerCore

/// TSK-1176 — the Terminal Command Palette panel. A live query field over the unified
/// favorites-first command list (`TerminalCommandPaletteViewModel`); each row shows a
/// pin/clock badge + label. Selecting a row (tap, or Enter on the top match) inserts the
/// command at the terminal prompt (no trailing newline — the user reviews + Returns).
///
/// Pure view over the host-tested view-model; presentation wiring (DocumentModel flag +
/// trigger + PTY-insert) is the render companion. VM-validated like the Script Console (TSK-698).
struct TerminalCommandPaletteView: View {
    @ObservedObject var vm: TerminalCommandPaletteViewModel
    /// Insert the chosen command at the terminal prompt.
    var onInsert: ((String) -> Void)?
    /// Dismiss the palette.
    var onClose: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            resultsArea
        }
        .padding(12)
        .frame(minWidth: 480, minHeight: 360)
    }

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Search commands…", text: $vm.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { insertSelected() }
                .accessibilityIdentifier("mdv.terminalPalette.query")
            if let onClose {
                Button("Close") { onClose() }
                    .accessibilityIdentifier("mdv.terminalPalette.close")
            }
        }
    }

    @ViewBuilder private var resultsArea: some View {
        if vm.results.isEmpty {
            Text("No matching commands.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .accessibilityIdentifier("mdv.terminalPalette.empty")
        } else {
            List(vm.results.indices, id: \.self) { i in
                let result = vm.results[i]
                Button { onInsert?(result.command) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: result.isFavorite ? "star.fill" : "clock")
                            .foregroundStyle(result.isFavorite ? .yellow : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(result.displayLabel)
                                .font(.system(.body, design: .monospaced))
                            if !result.title.isEmpty {
                                Text(result.command)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .accessibilityIdentifier("mdv.terminalPalette.results")
        }
    }

    private func insertSelected() {
        if let command = vm.selectedCommand { onInsert?(command) }
    }
}
