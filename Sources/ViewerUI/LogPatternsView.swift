import SwiftUI
import ViewerCore

/// TSK-1153 — a "Patterns" panel summarizing the active log's repeated lines
/// (from `LogPatternClusterer`): each masked template, how many lines matched,
/// and a representative example, ranked by frequency. The clustering is
/// host-tested; this list render is the VM-validated tail.
struct LogPatternsView: View {
    let result: LogPatternClusterer.Result

    var body: some View {
        if result.clusters.isEmpty {
            ContentUnavailableView(
                "No patterns",
                systemImage: "list.bullet.indent",
                description: Text("No repeated line patterns were found in this file."))
                .accessibilityIdentifier("mdv.logPatterns.empty")
        } else {
            List {
                Section {
                    ForEach(result.clusters) { c in row(c) }
                } header: {
                    Text("\(result.distinctPatterns) patterns · \(result.totalLines) lines")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("mdv.logPatterns.list")
        }
    }

    private func row(_ c: LogPatternClusterer.Cluster) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("\(c.count)×")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.blue, in: RoundedRectangle(cornerRadius: 3))
                Text(c.template)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
            }
            Text(c.example)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 1)
    }
}
