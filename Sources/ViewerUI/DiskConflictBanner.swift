import SwiftUI
import ViewerCore

/// Stub conflict banner (TSK-768 foundation slice): surfaced above the editor
/// when `DiskConflictResolver.classify` returns `.conflict`. Presents the three
/// resolution intents — Keep Mine / Take Disk / Merge — each wired straight to
/// a `DiskConflictIntent` callback so the owning coordinator can drive the
/// resolver's buffer side-effect. No merge UI yet (the Merge button captures
/// the baseline for a future three-way merge surface).
///
/// Render/visibility validation is VM-only (per the project's UI-test rules);
/// the host-testable contract here is the button→intent mapping, exercised by
/// driving `onResolve` directly.
struct DiskConflictBanner: View {
    /// File name shown in the banner copy.
    let fileName: String
    /// Invoked with the user's chosen resolution intent.
    let onResolve: (DiskConflictIntent) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(fileName) changed on disk")
                    .font(.system(size: 12, weight: .semibold))
                Text("You have unsaved edits. Choose how to resolve the conflict.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("Keep Mine") { onResolve(.keepMine) }
                .help("Keep your unsaved edits and ignore the on-disk change.")
            Button("Take Disk") { onResolve(.takeDisk) }
                .help("Discard your edits and reload the file from disk.")
            Button("Merge…") { onResolve(.merge) }
                .help("Capture both versions for a three-way merge (coming soon).")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        // Own layer ordered above any sibling NSViewRepresentable (CM6 editor):
        // an opaque representable composites over earlier-painted SwiftUI
        // siblings (CLAUDE.md compositor-occlusion rule), so the banner needs
        // its own group with a higher z-index wherever it shares a container
        // with the editor surface.
        .compositingGroup()
        .zIndex(1)
    }
}
