import SwiftUI
import ViewerCore

/// TSK-1109 — a read-only explorer for a package manifest's DECLARED dependencies
/// (npm package.json / Cargo.toml), parsed by `PackageManifestParser`. Lists each
/// dependency with its version constraint and a runtime/dev badge. The parse is
/// host-tested; this list render is the VM-validated tail. (Distinct from the
/// File ▸ Dependency Graph, which is the source-import graph.)
struct PackageExplorerView: View {
    let manifest: DependencyManifest

    var body: some View {
        if manifest.packages.isEmpty {
            ContentUnavailableView(
                "No dependencies",
                systemImage: "shippingbox",
                description: Text("This manifest declares no dependencies."))
                .accessibilityIdentifier("mdv.packageExplorer.empty")
        } else {
            List {
                Section {
                    ForEach(manifest.packages, id: \.self) { p in row(p) }
                } header: {
                    Text("\(manifest.rootName ?? "package") · \(manifest.source.rawValue) · "
                         + "\(manifest.packages.count) dependencies")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("mdv.packageExplorer.list")
        }
    }

    private func row(_ p: DependencyPackage) -> some View {
        HStack(spacing: 8) {
            Text(p.kind == .dev ? "dev" : "dep")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(p.kind == .dev ? Color.orange : Color.green,
                            in: RoundedRectangle(cornerRadius: 3))
            Text(p.name)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
            Spacer()
            Text(p.version ?? "—")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }
}
