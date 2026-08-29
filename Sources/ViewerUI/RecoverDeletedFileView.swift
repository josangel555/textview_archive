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
                Text("No recoverable files. Files that were deleted but still have Local History appear here — including ones deleted long ago.")
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
            // Owner 2026-08-29: BROWSE the deleted file's history without
            // recreating anything — the unified viewer works for a gone
            // path (diff-vs-current just has no current side). This was the
            // missing link: every other entry to the viewer (File menu,
            // sidebar context) needs a live tab or file row.
            Button("History") {
                model.openLocalHistory(for: url)
                onClose?()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .help("Browse this file's Local History versions without recreating it")
            .accessibilityIdentifier("mdv.recover.history")
            // TSK-1573: the primary click recreates the LATEST version; the
            // dropdown picks a SPECIFIC older version (date · size). Both route
            // through the host-tested `resurrectFile(at:version:)`.
            let versions = model.recoverableVersions(for: url)
            Menu {
                ForEach(versions) { v in
                    Button(versionLabel(v)) { recreate(url, version: v) }
                }
            } label: {
                Text("Recreate")
            } primaryAction: {
                recreate(url, version: nil)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(versions.isEmpty)
            .help(versions.count > 1
                  ? "Recreate the latest version — or ▾ to pick an older one"
                  : "Recreate from Local History")
            .accessibilityIdentifier("mdv.recover.recreate")
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recreate(_ url: URL, version: LocalHistoryStore.Version?) {
        let outcome = model.resurrectFile(at: url, version: version)
        // Refresh the list (a recreated file drops off); a created / reappeared
        // file also opens, so dismiss to reveal it.
        files = model.recoverableDeletedFiles()
        if outcome == .created || outcome == .refusedExists { onClose?() }
    }

    /// "Jul 9, 2026 at 2:34 PM · 1.2 KB" — the label for a version menu row.
    private func versionLabel(_ v: LocalHistoryStore.Version) -> String {
        let when = v.savedAt.formatted(date: .abbreviated, time: .shortened)
        let size = ByteCountFormatter.string(fromByteCount: Int64(v.byteSize), countStyle: .file)
        return "\(when) · \(size)"
    }
}
