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

    var body: some View {
        Group {
            if entries.isEmpty {
                Text("No saved walkthroughs yet.")
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
                        }
                        Spacer()
                        Button("Run") { doc.runWalkthrough(at: entry.url) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("mdv.walkthroughs.run")
                    }
                    .padding(.vertical, 2)
                    // TSK-1211: right-click ▸ Delete removes the walkthrough file.
                    .contextMenu {
                        Button("Delete Walkthrough", role: .destructive) {
                            WalkthroughCatalog.delete(entry)
                            reload()
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("mdv.walkthroughs.browser")
        .onAppear { reload() }
    }

    private func reload() {
        entries = WalkthroughCatalog.entries(in: WalkthroughCatalog.defaultLibraryDirectory())
    }
}
