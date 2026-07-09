import SwiftUI
import ViewerCore

/// TSK-1171 — the 3-pane conflict-resolution UI. For each unresolved conflict it
/// shows the base / ours / theirs slices side by side with a picker (Ours /
/// Theirs / Both / Base); Apply becomes enabled once every conflict has a choice
/// and hands back the fully-resolved text. The choice bookkeeping + resolved-text
/// derivation live on the host-tested `ConflictResolutionModel`; this is the shell
/// (VM/owner-validated render).
struct ConflictResolutionView: View {
    @ObservedObject var model: ConflictResolutionModel
    /// Called with the fully-resolved document text when the user applies.
    var onApply: (String) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(model.conflicts.enumerated()), id: \.offset) { index, slices in
                        conflictRow(index: index, slices: slices)
                    }
                }
                .padding(.vertical, 4)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 420)
        .accessibilityIdentifier("mdv.conflictResolution.sheet")
    }

    private var header: some View {
        HStack {
            Text("Resolve Conflicts")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text(model.allResolved ? "All resolved"
                 : "\(model.unresolvedCount) unresolved")
                .font(.system(size: 11))
                .foregroundStyle(model.allResolved ? Color.green : .secondary)
            Menu("Take all…") {
                Button(model.oursLabel) { model.resolveAllRemaining(with: .ours) }
                Button(model.theirsLabel) { model.resolveAllRemaining(with: .theirs) }
            }
            .fixedSize()
        }
    }

    private func conflictRow(
        index: Int, slices: (base: [String], ours: [String], theirs: [String])
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Conflict \(index + 1)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: choiceBinding(for: index)) {
                    Text(model.oursLabel).tag(Choice.ours)
                    Text(model.theirsLabel).tag(Choice.theirs)
                    Text("Both").tag(Choice.both)
                    Text("Original").tag(Choice.base)
                    Text("—").tag(Choice.none)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("mdv.conflictResolution.picker")
            }
            HStack(alignment: .top, spacing: 8) {
                slicePane("Original", slices.base, .secondary)
                slicePane(model.oursLabel, slices.ours, .blue)
                slicePane(model.theirsLabel, slices.theirs, .purple)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
    }

    private func slicePane(_ title: String, _ lines: [String], _ accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(accent)
            Text(lines.isEmpty ? "(empty)" : lines.joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(lines.isEmpty ? .tertiary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .textBackgroundColor)))
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { onCancel() }
            Spacer()
            Button("Apply") {
                if let text = model.resolvedText { onApply(text) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.allResolved)
            .accessibilityIdentifier("mdv.conflictResolution.apply")
        }
    }

    // MARK: - Picker binding (maps the segmented control ↔ the model's Resolution)

    private enum Choice: Hashable { case none, ours, theirs, both, base }

    private func choiceBinding(for index: Int) -> Binding<Choice> {
        Binding(
            get: {
                switch model.choices[index] {
                case .ours?:            return .ours
                case .theirs?:          return .theirs
                case .bothOursFirst?:   return .both
                case .base?:            return .base
                case .bothTheirsFirst?, .custom?: return .both   // rare paths collapse to "Both"
                case nil:               return .none
                }
            },
            set: { choice in
                switch choice {
                case .ours:   model.select(.ours, at: index)
                case .theirs: model.select(.theirs, at: index)
                case .both:   model.select(.bothOursFirst, at: index)
                case .base:   model.select(.base, at: index)
                case .none:   break   // can't un-choose via the picker
                }
            })
    }
}
