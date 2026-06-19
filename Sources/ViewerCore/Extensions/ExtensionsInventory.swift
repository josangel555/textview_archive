import Foundation

/// Unified "Extensions" catalog (TSK-338 — Merge Plugins).
///
/// The app grew several independent extension-like surfaces — installed
/// plugins (`PluginRegistry`), drop-in walkthrough scripts
/// (`WalkthroughLoader` / `WalkthroughDropTransport`) — each with its own
/// management affordance scattered across Settings sub-pages. The product
/// intent of TSK-338 is to *merge* them into one mainline "Extensions" UX:
/// a single list the user scans to see everything that extends the app,
/// regardless of which subsystem owns it.
///
/// This type is the **data backbone** of that merged surface. It is pure,
/// `Sendable`, host-testable model logic — deliberately decoupled from the
/// `@MainActor PluginRegistry.shared` singleton and from any view layer.
/// Callers build a `[ExtensionItem]` from whatever snapshots they already
/// have (the registry's `loaded` map, the on-disk walkthrough scripts) and
/// hand them in; the inventory unifies, dedupes, filters, and orders them
/// for display. The render layer (a consolidated Extensions view) is a thin
/// projection of this catalog and is validated separately.
///
/// Keeping the merge logic here — not in a SwiftUI view — is what lets the
/// host gate guard the *behaviour* (ordering, filtering, the unknown-kind
/// fallback) per the OWNER directive that every change pin its model
/// outcome on the host, with the pixel check reserved for the VM.
public struct ExtensionsInventory: Sendable, Equatable {

    /// Which subsystem an extension comes from. The merged view groups
    /// by this, but the catalog itself is a single flat ordered list so a
    /// global search/filter spans every kind at once.
    public enum Kind: String, Sendable, Equatable, CaseIterable, Comparable {
        /// A `PluginRegistry` plugin — bundled (Tier 0), Tier A static, or
        /// Tier B subprocess. The distinction is carried on the item, not
        /// the kind, so all plugins sort together.
        case plugin
        /// A walkthrough script discovered on disk (drop dir or bundled).
        case walkthrough

        /// Display order of the kind groups in the merged list: plugins
        /// first (the primary extension story), then walkthroughs.
        private var rank: Int {
            switch self {
            case .plugin:      return 0
            case .walkthrough: return 1
            }
        }

        public static func < (lhs: Kind, rhs: Kind) -> Bool {
            lhs.rank < rhs.rank
        }

        /// Human-facing group heading for the merged view.
        public var displayName: String {
            switch self {
            case .plugin:      return "Plugins"
            case .walkthrough: return "Walkthroughs"
            }
        }
    }

    /// Lifecycle/health status, normalised across the subsystems so the
    /// merged list can render one consistent status column. Each source
    /// maps its own state into this small shared vocabulary.
    public enum Status: String, Sendable, Equatable, CaseIterable {
        /// Loaded and active.
        case enabled
        /// Installed/known but switched off by the user.
        case disabled
        /// Declares capabilities the user hasn't decided on yet — the host
        /// must prompt before it contributes (plugins only).
        case awaitingGrant
        /// The user explicitly denied this extension's capabilities.
        case denied
        /// Failed to load / parse (malformed manifest, bad script).
        case failed
        /// Available to run but not a persistent "enabled" thing
        /// (walkthroughs are launched on demand, not toggled on).
        case available

        /// True when the item is contributing/usable right now. Drives the
        /// default "active first" ordering and the badge color upstream.
        public var isActive: Bool {
            switch self {
            case .enabled, .available: return true
            case .disabled, .awaitingGrant, .denied, .failed: return false
            }
        }
    }

    /// One row in the merged Extensions catalog.
    public struct ExtensionItem: Sendable, Equatable, Identifiable {
        /// Stable identity. To keep ids unique across subsystems that may
        /// reuse short slugs, it is namespaced by kind: `plugin:<id>` /
        /// `walkthrough:<id>`. Use ``rawID`` for the un-namespaced id.
        public let id: String
        /// The subsystem-local id (plugin id / walkthrough id), without the
        /// `kind:` prefix.
        public let rawID: String
        public let kind: Kind
        public let name: String
        /// Version string for plugins; nil for walkthroughs (they don't
        /// carry one).
        public let version: String?
        /// Authoring credit, when known.
        public let author: String?
        /// One-line subtitle/description for the row.
        public let detail: String?
        public let status: Status
        /// First-party / shipped-in-the-bundle. Bundled items can't be
        /// uninstalled and (for plugins) have no grants to revoke; the
        /// merged view renders a "BUNDLED" badge and hides destructive
        /// affordances.
        public let isBundled: Bool

        public init(
            rawID: String,
            kind: Kind,
            name: String,
            version: String? = nil,
            author: String? = nil,
            detail: String? = nil,
            status: Status,
            isBundled: Bool = false
        ) {
            self.id = "\(kind.rawValue):\(rawID)"
            self.rawID = rawID
            self.kind = kind
            self.name = name
            self.version = version
            self.author = author
            self.detail = detail
            self.status = status
            self.isBundled = isBundled
        }
    }

    /// The unified, de-duplicated, ordered catalog.
    public let items: [ExtensionItem]

    /// Build the catalog from raw per-subsystem items. The initializer is
    /// the single place the merge rules live:
    ///
    ///   - **Dedupe** by namespaced `id` (kind + rawID). If two snapshots
    ///     report the same extension, the FIRST occurrence wins — callers
    ///     pass higher-trust sources (the live registry) ahead of
    ///     lower-trust ones (a stale disk scan).
    ///   - **Order**: kind group first (plugins, then walkthroughs), then
    ///     active items ahead of inactive within a group, then
    ///     case-insensitive name, then `rawID` as a stable final tiebreak
    ///     so the order is deterministic for tests and for the user.
    public init(items: [ExtensionItem]) {
        var seen = Set<String>()
        var deduped: [ExtensionItem] = []
        deduped.reserveCapacity(items.count)
        for item in items where seen.insert(item.id).inserted {
            deduped.append(item)
        }
        self.items = deduped.sorted(by: Self.order)
    }

    /// Total deterministic ordering used to lay out the merged list.
    static func order(_ a: ExtensionItem, _ b: ExtensionItem) -> Bool {
        if a.kind != b.kind { return a.kind < b.kind }
        if a.status.isActive != b.status.isActive { return a.status.isActive }
        let an = a.name.lowercased(), bn = b.name.lowercased()
        if an != bn { return an < bn }
        return a.rawID < b.rawID
    }

    // MARK: - Queries

    /// Items belonging to one subsystem, preserving catalog order.
    public func items(of kind: Kind) -> [ExtensionItem] {
        items.filter { $0.kind == kind }
    }

    /// Case-insensitive substring filter across name, rawID, and author —
    /// the single search box of the merged view spans every kind. An empty
    /// (or whitespace-only) query returns the full catalog unchanged.
    public func filtered(_ query: String) -> [ExtensionItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { item in
            if item.name.lowercased().contains(q) { return true }
            if item.rawID.lowercased().contains(q) { return true }
            if let author = item.author?.lowercased(), author.contains(q) { return true }
            return false
        }
    }

    /// Count of items per kind, for section headers ("Plugins (3)").
    public func counts() -> [Kind: Int] {
        var out: [Kind: Int] = [:]
        for item in items { out[item.kind, default: 0] += 1 }
        return out
    }

    /// True when nothing is installed — the merged view shows its empty
    /// state.
    public var isEmpty: Bool { items.isEmpty }
}
