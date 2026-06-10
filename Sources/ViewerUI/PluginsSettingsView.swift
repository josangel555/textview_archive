import AppKit
import SwiftUI
import ViewerCore

/// Settings → Plugins pane. Lists every plugin the registry currently
/// knows about (loaded, awaiting-grant, denied), plus an "Open log"
/// button that surfaces the JSONL audit file in TextView itself.
///
/// The pane is intentionally read-only-plus-toggle in v1: enable /
/// disable + revoke. Install / uninstall / drag-drop UX is Phase 2.
public struct PluginsSettingsView: View {

    /// Snapshot of the registry, captured at render time. Re-renders
    /// after every action (toggle, revoke) by bumping `tick`.
    @State private var tick: Int = 0

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Installed plugins")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Show Log") { openAuditLog() }
                    .disabled(!auditLogExists)
                    .help("Open the plugins audit log in a new tab")
            }
            Divider()
            if plugins.isEmpty {
                Text("No plugins installed.\nDrop a folder under \(PluginRegistry.defaultPluginsDir().path) and relaunch.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(plugins, id: \.id) { row in
                            pluginRow(row)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(width: 460, height: 540)
        .id(tick)  // Force rebuild on action.
    }

    // MARK: - Rows

    private func pluginRow(_ row: PluginRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(size: 12, weight: .medium))
                    Text("v\(row.version)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if row.isBundled {
                        Text("BUNDLED")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(3)
                    }
                }
                Text(row.id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                if !row.capabilities.isEmpty {
                    Text("Capabilities: \(row.capabilities.joined(separator: ", "))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                if let warn = row.statusLine {
                    Text(warn)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                // TSK-614: bundled plugins are toggleable too — this is
                // the re-show path after "Hide Section" dismisses a
                // bundled sidebar section (e.g. ROW COUNTS). The state
                // is persisted by the registry. Revoke stays
                // third-party-only (bundled plugins have no grants).
                Toggle("", isOn: Binding(
                    get: { row.enabled },
                    set: { newValue in
                        PluginRegistry.shared.setEnabled(row.id, enabled: newValue)
                        tick += 1
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityIdentifier("mdv.pluginToggle.\(row.id)")
                if !row.isBundled {
                    Button("Revoke") { revoke(row) }
                        .font(.system(size: 10))
                        .help("Forget user decisions; the plugin will re-prompt on next load")
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(6)
    }

    // MARK: - Actions

    private func revoke(_ row: PluginRow) {
        PluginRegistry.shared.grantStore.revoke(pluginID: row.id)
        PluginRegistry.shared.setEnabled(row.id, enabled: false)
        tick += 1
    }

    private var auditLogExists: Bool {
        FileManager.default.fileExists(atPath: PluginSubprocessHost.auditLogURL().path)
    }

    private func openAuditLog() {
        let url = PluginSubprocessHost.auditLogURL()
        NSWorkspace.shared.open(url)
    }

    // MARK: - View-model

    private struct PluginRow {
        let id: String
        let name: String
        let version: String
        let capabilities: [String]
        let isBundled: Bool
        let enabled: Bool
        let statusLine: String?
    }

    private var plugins: [PluginRow] {
        PluginRegistry.shared.loaded
            .map { id, entry in
                let caps = entry.manifest.capabilities
                    .filter { $0 != .unknown }
                    .map { $0.rawValue }
                    .sorted()
                let grantStatus = PluginRegistry.shared.grantStore.status(
                    pluginID: id, declaredCapabilities: caps
                )
                let status: String?
                switch grantStatus {
                case .required:
                    status = "Awaiting permission grant"
                case .denied:
                    status = "User denied — click Revoke to re-prompt"
                case .granted:
                    status = entry.enabled ? nil : "Disabled"
                }
                return PluginRow(
                    id: id,
                    name: entry.manifest.name,
                    version: entry.manifest.version,
                    capabilities: caps,
                    isBundled: entry.folder == nil,
                    enabled: entry.enabled,
                    statusLine: status
                )
            }
            .sorted { $0.id < $1.id }
    }
}

/// First-install prompt — non-modal alert listing the capabilities
/// the user is being asked to grant. Returns the user's decision via
/// completion. Per design §5.3, we tell the user what the plugin
/// **can do**, not whether it's safe.
@MainActor
public enum PluginGrantPrompt {

    /// Show the prompt for a single plugin and persist the decision.
    /// `onDone` fires on the main queue after the grant store has
    /// been updated; the caller is expected to re-load the plugin.
    public static func present(
        manifest: PluginManifest,
        folder: URL,
        store: PluginGrantStore = PluginRegistry.shared.grantStore,
        onDone: @escaping (PluginGrantStore.Decision) -> Void
    ) {
        let caps = manifest.capabilities
            .filter { $0 != .unknown }
            .map { $0.rawValue }
            .sorted()

        let alert = NSAlert()
        alert.messageText = "Install “\(manifest.name)” (v\(manifest.version))?"
        let author = manifest.author.name
        let lines = caps.map { "  •  \(capabilityHumanLabel($0))" }
            .joined(separator: "\n")
        alert.informativeText = """
        by \(author)

        This plugin would be able to:
        \(lines.isEmpty ? "  (no capabilities declared)" : lines)

        Source: \(folder.path)
        """
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")

        let decision: PluginGrantStore.Decision
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            decision = .granted
        default:
            decision = .denied
        }
        store.record(
            pluginID: manifest.id,
            version: manifest.version,
            capabilities: caps,
            decision: decision
        )
        onDone(decision)
    }

    /// Human-readable line for the prompt. Mirrors the capability
    /// table in design §5.1 but tighter; the prompt has limited
    /// vertical real estate.
    private static func capabilityHumanLabel(_ raw: String) -> String {
        switch raw {
        case "shell.exec":
            return "Run bundled command-line tools (shell.exec)"
        case "ui.sidebar":
            return "Add a sidebar section (ui.sidebar)"
        case "ui.viewmode":
            return "Add a custom view mode (ui.viewmode)"
        case "ui.menu":
            return "Add menu items (ui.menu)"
        case "ui.palette":
            return "Add command-palette entries (ui.palette)"
        case "network.egress":
            return "Make network requests (network.egress)"
        case "file.read":
            return "Read files in the open project (file.read)"
        default:
            return raw
        }
    }
}
