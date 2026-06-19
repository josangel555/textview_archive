import Foundation

/// Live bridges that snapshot the running subsystems into the unified
/// `ExtensionsInventory` (TSK-338 — Merge Plugins).
///
/// These are the seam the consolidated Extensions view calls: they read the
/// `@MainActor PluginRegistry.shared` (and, when wired, the on-disk
/// walkthrough catalog) into the plain value-snapshot structs the pure
/// merge logic consumes. Keeping the `@MainActor` hop here — out of the
/// pure model files — means the inventory itself stays host-testable
/// without the singleton.
extension ExtensionsInventory {

    /// Snapshot every plugin the registry currently knows about, mapping
    /// each one's enable flag + grant decision into a `PluginSnapshot`.
    ///
    /// This mirrors exactly what `PluginsSettingsView` already computes for
    /// its rows, so the consolidated view and the legacy pane render the
    /// same source of truth. Capabilities exclude the `.unknown`
    /// forward-compat sentinel (a future-host capability the user shouldn't
    /// be asked about).
    @MainActor
    public static func pluginSnapshots(
        from registry: PluginRegistry = .shared
    ) -> [PluginSnapshot] {
        registry.loaded.map { id, entry in
            let caps = entry.manifest.capabilities
                .filter { $0 != .unknown }
                .map(\.rawValue)
                .sorted()
            let isBundled = entry.folder == nil
            // Bundled plugins have no grants; only third-party plugins
            // route through the grant store.
            let grant: PluginSnapshot.Grant?
            if isBundled {
                grant = nil
            } else {
                switch registry.grantStore.status(
                    pluginID: id, declaredCapabilities: caps
                ) {
                case .granted:  grant = .granted
                case .denied:   grant = .denied
                case .required: grant = .required
                }
            }
            return PluginSnapshot(
                id: id,
                name: entry.manifest.name,
                version: entry.manifest.version,
                author: entry.manifest.author.name,
                capabilities: caps,
                isBundled: isBundled,
                enabled: entry.enabled,
                grant: grant
            )
        }
    }

    /// Build the merged catalog from the live registry. Walkthroughs are
    /// passed in by the caller (the on-disk catalog is loaded off-main in
    /// the view), so this bridge stays focused on the `@MainActor`
    /// registry read.
    @MainActor
    public static func live(
        registry: PluginRegistry = .shared,
        walkthroughs: [WalkthroughSnapshot] = []
    ) -> ExtensionsInventory {
        ExtensionsInventory(
            plugins: pluginSnapshots(from: registry),
            walkthroughs: walkthroughs
        )
    }
}
