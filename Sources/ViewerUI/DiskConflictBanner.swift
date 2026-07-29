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

            // Every option keeps the version it sets aside: the discarded side
            // is captured into Local History first, so any of these is
            // reversible from File ▸ Local History.
            Button("Keep Mine") { onResolve(.keepMine) }
                .help("Keep your unsaved edits. The on-disk version is saved to "
                      + "Local History first, so you can still get it back.")
            Button("Take Disk") { onResolve(.takeDisk) }
                .help("Reload the file from disk. Your unsaved edits are saved to "
                      + "Local History first, so you can still get them back.")
            Button("Merge…") { onResolve(.merge) }
                .help("Open a three-way merge: resolve each conflicting region "
                      + "yourself, keeping work from both sides.")
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
