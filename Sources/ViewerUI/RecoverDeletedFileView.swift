import SwiftUI
import ViewerCore

/// TSK-1500 — the "Recover Deleted File" picker: a list of recently-opened files
/// that are gone from disk but still have Local History versions. Each row
/// recreates the file from its latest version (atomic, never-overwrite — the
/// host-tested `FileResurrection` primitive) and opens it. The enumeration +
/// recreate logic live on the host-tested DocumentModel; this is the shell.
struct RecoverDeletedFileView: View {
    @ObservedObject var model: DocumentModel
    var onClose: (() -> Void)?

    @State private var files: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recover Deleted File")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(files.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Divider()
            if files.isEmpty {
                Text("No recoverable files. Recently-opened files that were deleted but still have Local History appear here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("mdv.recover.empty")
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(files, id: \.self) { url in
                            row(url)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Done") { onClose?() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 440, minHeight: 320)
        .onAppear { files = model.recoverableDeletedFiles() }
        .accessibilityIdentifier("mdv.recover.sheet")
    }

    private func row(_ url: URL) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.badge.clock")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(url.deletingLastPathComponent().path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Button("Recreate") {
                let outcome = model.resurrectFile(at: url)
                // Refresh the list (the recreated file drops off); a created /
                // reappeared file also opens, so dismiss to reveal it.
                files = model.recoverableDeletedFiles()
                if outcome == .created || outcome == .refusedExists { onClose?() }
            }
            .accessibilityIdentifier("mdv.recover.recreate")
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
