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
    @Environment(\.sidebarSectionBodyHeight) private var bodyHeight

    /// Local expand/collapse state per section, keyed by section id.
    @State private var expanded: [String: Bool] = [:]

    /// Bumped after a registry mutation (Hide Section) so the body
    /// re-reads `entries` — the registry itself is unobserved by
    /// design (see header comment). Same pattern as
    /// `PluginsSettingsView.tick`.
    @State private var registryTick = 0

    var body: some View {
        VStack(spacing: 0) {
            ForEach(entries, id: \.sectionID) { entry in
                section(entry)
                    .sidebarSectionContainer()
            }
        }
        .id(registryTick)
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
                    SidebarSectionHeaderLabel(
                        title: entry.title,
                        isExpanded: isExpanded,
                        uiSize: model.uiSize
                    )
                    if let icon = entry.icon {
                        Image(systemName: icon)
                            .font(.system(size: model.uiSize(10)))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .sidebarHeaderRow(uiSize: model.uiSize)
            }
            .buttonStyle(.plain)
            // TSK-614: the dismiss affordance the always-on section
            // lacked. Hiding disables the contributing plugin (state
            // PERSISTED by the registry); re-enable lives in
            // Settings → Plugins.
            .contextMenu {
                Button("Hide Section") {
                    PluginRegistry.shared.setEnabled(entry.pluginID, enabled: false)
                    registryTick += 1
                }
                Text("Re-enable in Settings → Plugins")
            }
            if isExpanded {
                let snapshot = SidebarSectionRegistry.Snapshot(
                    openFileContents: openFileContents
                )
                let rows = PluginRegistry.shared.sidebarSections.safeRows(
                    for: entry, snapshot: snapshot
                )
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if rows.isEmpty {
                            SidebarEmptyPlaceholder(message: "(empty)")
                        }
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
                            .padding(.horizontal, model.uiSize(14))
                            .padding(.vertical, model.uiSize(2))
                        }
                    }
                }
                .frame(height: bodyHeight)
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
