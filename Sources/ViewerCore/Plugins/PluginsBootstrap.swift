import Foundation

/// App-launch entry point for plugin discovery. Wraps two steps that
/// the AppDelegate would otherwise have to coordinate:
///
///   1. Register all bundled (Tier 0 / first-party Swift) plugins.
///   2. Scan the on-disk Plugins dir, collect any plugins that need a
///      grant decision, and return them to the caller.
///
/// The caller (AppDelegate) is the one with access to NSAlert / the
/// main window, so it owns the "show prompt" step; we just hand it
/// the list. Keeping the UI hop out of ViewerCore keeps this module
/// pure-logic (no AppKit dependency).
@MainActor
public enum PluginsBootstrap {

    public struct PendingGrant: Sendable {
        public let folder: URL
        public let manifest: PluginManifest
    }

    /// Load everything we can without UI, return the plugins that
    /// still need a user decision. The AppDelegate calls `prompt` for
    /// each and then `PluginRegistry.shared.reloadOne(folder:)` after
    /// the user decides.
    @discardableResult
    public static func loadAtLaunch(
        pluginsDir: URL = PluginRegistry.defaultPluginsDir()
    ) -> [PendingGrant] {
        // 1. Bundled plugins. Each owns its own register call so we
        //    don't have to hardcode them here — the bootstrap just
        //    lists them. v1 has one.
        RowCounterPlugin.register()

        // 2. On-disk plugins. Each result either loaded, was warned
        //    about, or is awaiting a grant. We surface the awaiting-
        //    grant ones so the UI can prompt.
        let results = PluginRegistry.shared.loadAll(from: pluginsDir)
        var pending: [PendingGrant] = []
        for r in results {
            switch r.status {
            case .awaitingGrant:
                if let id = r.pluginID,
                   let entry = PluginRegistry.shared.loaded[id] {
                    pending.append(PendingGrant(
                        folder: r.folder, manifest: entry.manifest
                    ))
                }
            case .loaded, .loadedWithWarnings, .failed:
                continue
            }
        }
        return pending
    }
}
