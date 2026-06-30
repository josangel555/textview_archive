import SwiftUI
import ViewerCore

/// TSK-1107 — File ▸ Walkthroughs: a browser of saved walkthroughs from the
/// `WalkthroughCatalog` library, each shown by title + last-modified date with a
/// Run action. Delete / rename / history-resume are tracked follow-ons.
///
/// The catalog listing (`WalkthroughCatalog.entries`) is pure + host-tested in
/// ViewerCore; this view paints the rows and routes Run to
/// `DocumentModel.runWalkthrough`. Opened as a hosted tab via
/// `showWalkthroughsBrowser()`.
struct WalkthroughsBrowserView: View {
    @ObservedObject var doc: DocumentModel
    @State private var entries: [WalkthroughCatalog.Entry] = []
    @State private var renaming: WalkthroughCatalog.Entry?
    @State private var renameText = ""

    var body: some View {
        VStack(spacing: 0) {
            // TSK-1326: a discoverable authoring entry point — "New Walkthrough"
            // seeds a copy-and-edit starter into the library and opens it for
            // editing (the owner's "authoring is opaque" fix; pairs with the
            // docs/WALKTHROUGH_AUTHORING.md guide).
            HStack {
                Text("Walkthroughs").font(.headline)
                Spacer()
                Button { newWalkthrough() } label: {
                    Label("New Walkthrough", systemImage: "plus")
                }
                .accessibilityIdentifier("mdv.walkthroughs.new")
            }
            .padding(8)
            Divider()
            content
        }
        .accessibilityIdentifier("mdv.walkthroughs.browser")
        .onAppear { reload() }
        .alert("Rename Walkthrough", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") { performRename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Rename the walkthrough file (the .json extension is kept).")
        }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if entries.isEmpty {
                Text("No saved walkthroughs yet. Click “New Walkthrough” to start from a sample.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("mdv.walkthroughs.empty")
            } else {
                List(entries) { entry in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).font(.body)
                            if let modified = entry.modifiedAt {
                                Text(modified.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.url.lastPathComponent)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Run") { doc.runWalkthrough(at: entry.url) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("mdv.walkthroughs.run")
                    }
                    .padding(.vertical, 2)
                    // TSK-1211: right-click ▸ Resume / Rename / Delete.
                    .contextMenu {
                        Button("Resume") { doc.resumeWalkthrough(at: entry.url) }
                        Button("Rename…") {
                            renaming = entry
                            renameText = entry.url.deletingPathExtension().lastPathComponent
                        }
                        Button("Delete Walkthrough", role: .destructive) {
                            WalkthroughCatalog.delete(entry)
                            reload()
                        }
                    }
                }
            }
        }
    }

    /// TSK-1326 — seed a starter walkthrough into the library + open it for editing.
    private func newWalkthrough() {
        guard let url = WalkthroughCatalog.create(
            in: WalkthroughCatalog.defaultLibraryDirectory()
        ) else { return }
        reload()
        doc.open(url: url)
    }

    private func performRename() {
        if let entry = renaming {
            _ = WalkthroughCatalog.rename(entry, toBaseName: renameText)
        }
        renaming = nil
        reload()
    }

    private func reload() {
        entries = WalkthroughCatalog.entries(in: WalkthroughCatalog.defaultLibraryDirectory())
    }
}
