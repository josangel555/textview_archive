import Foundation

/// Adapters that map each extension subsystem's own state into the unified
/// `ExtensionsInventory.ExtensionItem` shape (TSK-338 — Merge Plugins).
///
/// These are deliberately driven by **value snapshots**, not the
/// `@MainActor PluginRegistry.shared` singleton, so the merge mapping is
/// host-testable in `ViewerCoreTests` without spinning up the live
/// registry. The view layer takes the registry's `loaded` map / a disk
/// scan, projects it to the snapshot structs below, and feeds them in.
extension ExtensionsInventory {

    /// Snapshot of one plugin the registry knows about. Mirrors the fields
    /// `PluginsSettingsView` already pulls off `PluginRegistry.LoadedPlugin`
    /// + the grant store, decoupled into a plain value type so the merge
    /// logic doesn't depend on `@MainActor` registry state.
    public struct PluginSnapshot: Sendable, Equatable {
        public let id: String
        public let name: String
        public let version: String
        public let author: String?
        public let capabilities: [String]
        public let isBundled: Bool
        public let enabled: Bool
        /// The grant decision for this plugin's declared capabilities.
        /// `nil` = no capabilities require a grant (or it's bundled).
        public let grant: Grant?

        /// Normalised grant outcome, matching
        /// `PluginGrantStore.Status` without importing that type into the
        /// snapshot vocabulary.
        public enum Grant: Sendable, Equatable {
            case granted
            case denied
            case required
        }

        public init(
            id: String,
            name: String,
            version: String,
            author: String? = nil,
            capabilities: [String] = [],
            isBundled: Bool = false,
            enabled: Bool,
            grant: Grant? = nil
        ) {
            self.id = id
            self.name = name
            self.version = version
            self.author = author
            self.capabilities = capabilities
            self.isBundled = isBundled
            self.enabled = enabled
            self.grant = grant
        }

        /// Map the plugin's enabled flag + grant decision into the unified
        /// status. Grant state dominates: an awaiting/denied grant is more
        /// important to surface than the enable toggle (the user can't even
        /// turn it on usefully until the grant resolves).
        var unifiedStatus: ExtensionsInventory.Status {
            switch grant {
            case .required: return .awaitingGrant
            case .denied:   return .denied
            case .granted, .none:
                return enabled ? .enabled : .disabled
            }
        }
    }

    /// Snapshot of one walkthrough script discovered on disk.
    public struct WalkthroughSnapshot: Sendable, Equatable {
        public let id: String
        public let title: String
        public let subtitle: String?
        public let author: String?
        public let isBundled: Bool

        public init(
            id: String,
            title: String,
            subtitle: String? = nil,
            author: String? = nil,
            isBundled: Bool = false
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.author = author
            self.isBundled = isBundled
        }
    }

    /// Project a plugin snapshot into a catalog item.
    public static func item(from p: PluginSnapshot) -> ExtensionItem {
        let detail: String?
        if p.capabilities.isEmpty {
            detail = nil
        } else {
            detail = "Capabilities: " + p.capabilities.sorted().joined(separator: ", ")
        }
        return ExtensionItem(
            rawID: p.id,
            kind: .plugin,
            name: p.name,
            version: p.version,
            author: p.author,
            detail: detail,
            status: p.unifiedStatus,
            isBundled: p.isBundled
        )
    }

    /// Project a walkthrough snapshot into a catalog item. Walkthroughs are
    /// launched on demand, so their status is always `.available` (there is
    /// no enable/disable toggle for a script on disk).
    public static func item(from w: WalkthroughSnapshot) -> ExtensionItem {
        ExtensionItem(
            rawID: w.id,
            kind: .walkthrough,
            name: w.title,
            version: nil,
            author: w.author,
            detail: w.subtitle,
            status: .available,
            isBundled: w.isBundled
        )
    }

    /// Build the merged catalog from both subsystems' snapshots. Plugins
    /// are passed ahead of walkthroughs so that, in the (impossible today
    /// but defensively handled) event of an id collision across the
    /// namespaced ids, the plugin source wins the dedupe.
    public init(
        plugins: [PluginSnapshot],
        walkthroughs: [WalkthroughSnapshot]
    ) {
        let items = plugins.map(ExtensionsInventory.item(from:))
            + walkthroughs.map(ExtensionsInventory.item(from:))
        self.init(items: items)
    }
}
