import SwiftUI

// TSK-1436 — renders `ToastCenter` state bottom-trailing over the content
// pane: in-flight operation rows (spinner/bar + optional Cancel) above
// transient toast capsules (error/success/info + optional action, e.g. Undo).
// Mounted once in `ContentView` with `.compositingGroup().zIndex(...)` per the
// LESSONS compositor-occlusion rule (an opaque WebView sibling would otherwise
// composite over it).

struct ToastOverlayView: View {
    @ObservedObject var center: ToastCenter

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(center.operations) { op in
                operationRow(op)
            }
            ForEach(center.toasts) { toast in
                toastCapsule(toast)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .allowsHitTesting(!(center.toasts.isEmpty && center.operations.isEmpty))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mdv.toastOverlay")
        // Expiry is scheduled by the center itself (one Task per post) — no
        // view-side timer, so a re-rendering parent can't starve the sweep.
        .animation(.easeInOut(duration: 0.15),
                   value: center.toasts.map(\.id) + center.operations.map(\.id))
    }

    // MARK: - Rows

    @ViewBuilder
    private func operationRow(_ op: OperationProgress) -> some View {
        HStack(spacing: 8) {
            if let fraction = op.fraction {
                ProgressView(value: fraction)
                    .frame(width: 120)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(op.title)
                .font(.callout)
                .lineLimit(1)
            if op.isCancellable {
                Button("Cancel") { center.requestCancel(op.id) }
                    .buttonStyle(.plain)
                    .pointingCursor()   // I-07
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("mdv.progress.cancel")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mdv.progress.row")
    }

    @ViewBuilder
    private func toastCapsule(_ toast: Toast) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon(for: toast.kind))
                .foregroundStyle(color(for: toast.kind))
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.message)
                    .font(.callout)
                    .lineLimit(2)
                if let detail = toast.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            if let label = toast.actionLabel {
                Button(label) { center.runAction(for: toast.id) }
                    .accessibilityIdentifier("mdv.toast.action")
            }
            Button {
                center.dismiss(toast.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .pointingCursor()   // I-07
            .accessibilityIdentifier("mdv.toast.dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(color(for: toast.kind).opacity(0.35))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mdv.toast.\(toast.kind.rawValue)")
    }

    private func icon(for kind: Toast.Kind) -> String {
        switch kind {
        case .info:    return "info.circle"
        case .success: return "checkmark.circle"
        case .error:   return "exclamationmark.triangle"
        }
    }

    private func color(for kind: Toast.Kind) -> Color {
        switch kind {
        case .info:    return .blue
        case .success: return .green
        case .error:   return .orange
        }
    }
}

