import SwiftUI
import ViewerCore

/// Renders every registered plugin sidebar section above the Files
/// tree. Sections are pulled from `PluginRegistry.shared` at render
/// time — no observation, no Combine wiring. The intent is "the
/// registry is the source of truth; the view is a thin projection."
///
/// Why not `@ObservedObject` on the registry? Because we'd then have
/// to thread a publisher through `PluginRegistry`, which is fine but
/// premature for v1's scale (handful of plugins). Re-renders happen
/// when SwiftUI re-evaluates `SidebarView.body` for other reasons —
/// tab change, sidebar visibility toggle, etc. — and that's enough
/// granularity for v1. If users complain about stale rows after a
/// plugin update we add the publisher.
struct PluginSidebarSections: View {
    @ObservedObject var model: DocumentModel

    /// Local expand/collapse state per section, keyed by section id.
    @State private var expanded: [String: Bool] = [:]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(entries, id: \.sectionID) { entry in
                section(entry)
                Divider()
            }
        }
    }

    private var entries: [SidebarSectionRegistry.Entry] {
        PluginRegistry.shared.sidebarSections.all
    }

    private func section(_ entry: SidebarSectionRegistry.Entry) -> some View {
        let isExpanded = expanded[entry.sectionID]
            ?? !entry.collapsedByDefault
        return VStack(alignment: .leading, spacing: 0) {
            Button(action: {
                expanded[entry.sectionID] = !isExpanded
            }) {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 10)
                    if let icon = entry.icon {
                        Image(systemName: icon)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.title)
                        .font(.system(size: model.uiSize(10), weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            if isExpanded {
                let snapshot = SidebarSectionRegistry.Snapshot(
                    openFileContents: openFileContents
                )
                let rows = PluginRegistry.shared.sidebarSections.safeRows(
                    for: entry, snapshot: snapshot
                )
                ForEach(rows) { row in
                    HStack(spacing: 6) {
                        Text(row.label)
                            .font(.system(size: model.uiSize(11)))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        if let detail = row.detail {
                            Text(detail)
                                .font(.system(size: model.uiSize(10),
                                              design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)
                }
            }
        }
    }

    /// The snapshot exposed to plugin providers. v1: the URL+contents
    /// of every open tab. Plugins that don't need this (Tier B that
    /// ignores stdin) just don't read it.
    private var openFileContents: [URL: String] {
        var out: [URL: String] = [:]
        for tab in model.tabs.tabs {
            if let url = tab.url, case .loaded(let file) = tab.state {
                out[url] = file.contents
            }
        }
        return out
    }
}
