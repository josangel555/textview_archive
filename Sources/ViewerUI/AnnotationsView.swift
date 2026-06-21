import SwiftUI
import ViewerCore

/// TSK-1121 — a navigable list of the active file's TODO/FIXME/HACK/XXX/NOTE/BUG
/// markers (from `SourceAnnotationScanner`). Tapping a row jumps to that line.
/// The scan + jump model are host-tested; this list render is the VM-validated tail.
struct AnnotationsView: View {
    let annotations: [SourceAnnotation]
    /// Jump to a 1-based line in the source file.
    let onJump: (Int) -> Void

    var body: some View {
        if annotations.isEmpty {
            ContentUnavailableView(
                "No annotations",
                systemImage: "checklist",
                description: Text("No TODO / FIXME / HACK / XXX / NOTE / BUG markers in this file."))
                .accessibilityIdentifier("mdv.annotations.empty")
        } else {
            List(Array(annotations.enumerated()), id: \.offset) { _, a in
                Button { onJump(a.line) } label: {
                    HStack(spacing: 8) {
                        Text(a.kind.rawValue)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(color(for: a.kind), in: RoundedRectangle(cornerRadius: 3))
                        Text(a.message.isEmpty ? "—" : a.message)
                            .lineLimit(1)
                        Spacer()
                        Text("\(a.line)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .accessibilityIdentifier("mdv.annotations.list")
        }
    }

    private func color(for kind: SourceAnnotation.Kind) -> Color {
        switch kind {
        case .fixme, .bug, .xxx: return .red
        case .hack:             return .orange
        case .todo:             return .blue
        case .note:             return .gray
        }
    }
}
