import SwiftUI
import ViewerCore

/// TSK-1161 — the Structural Search panel. The user types a structural query (the
/// tree-sitter-inspired DSL), Search runs it over the active buffer via the host engine
/// (StructuralSearchViewModel), and the results list shows each ranged match (kind + a
/// source snippet); selecting a row jumps to the match's range in the editor.
///
/// Pure view over the host-tested `StructuralSearchViewModel`; presentation wiring
/// (DocumentModel flag + menu trigger) is the render companion. VM-validated like the
/// Script Console (TSK-698).
struct StructuralSearchView: View {
    @ObservedObject var vm: StructuralSearchViewModel
    /// Jump the editor to a match's NSRange. Nil disables row selection.
    var onJump: ((NSRange) -> Void)?
    /// Dismiss the panel. Nil hides the Close button.
    var onClose: (() -> Void)?

    /// TSK-1476 — the language-tailored examples popover.
    @State private var showExamples = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            // TSK-1476: live under-field validation — parse the query AS TYPED so
            // a syntax slip is visible BEFORE Search (the post-run errorMessage
            // still shows engine errors). Suppressed while a run-error is shown.
            if vm.errorMessage == nil,
               let liveError = StructuralSearchHelp.validationError(for: vm.query) {
                Text(liveError)
                    .foregroundStyle(.orange)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("mdv.structuralSearch.liveError")
            }
            resultsArea
        }
        .padding(12)
        .frame(minWidth: 480, minHeight: 360)
    }

    private var header: some View {
        HStack(spacing: 10) {
            TextField(StructuralSearchHelp.placeholder, text: $vm.query)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .onSubmit { vm.run() }
                .accessibilityIdentifier("mdv.structuralSearch.query")
            Button("Search") { vm.run() }
                .keyboardShortcut(.return, modifiers: [])
                .accessibilityIdentifier("mdv.structuralSearch.run")
            // TSK-1476: insertable examples so a user who's never seen the DSL can
            // run one in a click. Language-tailored off the active file's language.
            Button("Examples") { showExamples.toggle() }
                .popover(isPresented: $showExamples, arrowEdge: .bottom) { examplesList }
                .accessibilityIdentifier("mdv.structuralSearch.examplesButton")
            if let onClose {
                Button("Close") { onClose() }
                    .accessibilityIdentifier("mdv.structuralSearch.close")
            }
        }
    }

    private var examplesList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Examples — click to insert")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Divider()
            ForEach(Array(StructuralSearchHelp.examples(for: vm.language).enumerated()), id: \.offset) { _, ex in
                Button {
                    vm.query = ex.query
                    showExamples = false
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ex.label)
                            .font(.system(size: 12, weight: .medium))
                        Text(ex.query)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
        }
        .padding(12)
        .frame(width: 360)
        .accessibilityIdentifier("mdv.structuralSearch.examples")
    }

    @ViewBuilder private var resultsArea: some View {
        if let err = vm.errorMessage {
            Text(err)
                .foregroundStyle(.red)
                .font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("mdv.structuralSearch.error")
        } else if vm.matches.isEmpty {
            Text(vm.didRun ? "No matches." : "— enter a query and press Search —")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .accessibilityIdentifier("mdv.structuralSearch.empty")
        } else {
            List(vm.matches.indices, id: \.self) { i in
                let match = vm.matches[i]
                Button { onJump?(match.range) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(match.kind)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Text(snippet(for: match))
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .accessibilityIdentifier("mdv.structuralSearch.results")
        }
    }

    /// The first line of the matched node's source text (from the buffer at match.range).
    private func snippet(for match: StructuralMatch) -> String {
        let ns = vm.inputText as NSString
        guard match.range.location != NSNotFound,
              match.range.location >= 0,
              match.range.location + match.range.length <= ns.length else { return match.kind }
        let text = ns.substring(with: match.range)
        return text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? text
    }
}
