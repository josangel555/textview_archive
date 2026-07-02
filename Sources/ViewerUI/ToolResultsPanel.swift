import SwiftUI
import ViewerCore

/// The shared tool-results panel (TSK-1434): a floating, NON-modal panel
/// (palette/cross-search pattern) listing a tool's results — severity dot,
/// optional line badge (click → goto line, panel stays open), optional rule
/// tag, Copy-all, Esc/✕ dismiss. Replaces the four modal alerts.
struct ToolResultsPanel: View {
    @ObservedObject var model: DocumentModel
    let results: ToolResults

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            rowList
        }
        .frame(width: 560)
        .frame(maxHeight: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
        .shadow(radius: 18, y: 6)
        .accessibilityIdentifier("mdv.toolResults.panel")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(results.title)
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button {
                Pasteboard.copy(results.plainText)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .help("Copy all results")
            .accessibilityIdentifier("mdv.toolResults.copy")
            Button {
                model.dismissToolResults()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.cancelAction)   // Esc dismisses
            .help("Close")
            .accessibilityIdentifier("mdv.toolResults.close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var rowList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(results.rows) { row in
                    rowView(row)
                    Divider().opacity(0.35)
                }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: ToolResultRow) -> some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(color(for: row.severity))
                .frame(width: 8, height: 8)
                .padding(.top, 2)
            if let line = row.line {
                Text("line \(line)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            Text(row.message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
            if let tag = row.tag {
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)

        if row.line != nil {
            Button {
                model.activateToolResultRow(row)
            } label: {
                content.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to line \(row.line ?? 0)")
        } else {
            content
        }
    }

    private func color(for severity: ToolResultRow.Severity) -> Color {
        switch severity {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}
