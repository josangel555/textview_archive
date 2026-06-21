import SwiftUI
import ViewerCore

/// TSK-1103 — a reachable list of a file's Local History versions (snapshots
/// taken on save by `LocalHistoryStore`). Each row shows when it was saved + its
/// size; "View" opens that version's content read-only. The store + snapshotting
/// are host-tested; this list render is the VM-validated tail. (Destructive
/// restore-over-current is a deliberate follow-on — viewing is non-destructive.)
struct LocalHistoryView: View {
    let versions: [LocalHistoryStore.Version]
    let fileName: String
    /// Open the given version's content (read-only).
    let onView: (LocalHistoryStore.Version) -> Void

    var body: some View {
        if versions.isEmpty {
            ContentUnavailableView(
                "No saved versions",
                systemImage: "clock.arrow.circlepath",
                description: Text("Local History records a version of \(fileName) each time you save it."))
                .accessibilityIdentifier("mdv.localHistory.empty")
        } else {
            List {
                Section {
                    ForEach(versions) { v in row(v) }
                } header: {
                    Text("\(versions.count) version\(versions.count == 1 ? "" : "s") · \(fileName)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("mdv.localHistory.list")
        }
    }

    private func row(_ v: LocalHistoryStore.Version) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(v.savedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.system(.body))
                Text(ByteCountFormatter.string(fromByteCount: Int64(v.byteSize), countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("View") { onView(v) }
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 1)
    }
}

/// A minimal read-only text viewer for an old version's content (TSK-1103).
struct LocalHistoryVersionView: View {
    let content: String

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(content)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .accessibilityIdentifier("mdv.localHistory.versionContent")
    }
}
