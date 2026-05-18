import Foundation

/// Persisted "user said yes / no" to a plugin's declared capability set.
/// Per design §5.2: per-plugin, whole-capability-set grant; re-prompt
/// when the manifest's `capabilities` set changes or the user revokes.
///
/// On-disk format is a single JSON object keyed by plugin id:
///
/// ```json
/// {
///   "com.example.tv.proto": {
///     "grantedAt": "2026-05-17T12:00:00Z",
///     "capabilities": ["shell.exec", "ui.sidebar"],
///     "version": "1.2.3",
///     "decision": "granted"   // or "denied"
///   }
/// }
/// ```
///
/// **`decision`** is explicit so a "user clicked Cancel" record is
/// distinct from "we never asked." That distinction matters for the
/// re-prompt path — we don't keep nagging if the user said no, only
/// re-prompt when the manifest changes.
public final class PluginGrantStore: @unchecked Sendable {

    public enum Decision: String, Codable, Sendable {
        case granted
        case denied
    }

    public struct Grant: Codable, Sendable, Equatable {
        public let grantedAt: Date
        public let capabilities: [String]   // capability rawValues, sorted
        public let version: String           // plugin version at grant time
        public let decision: Decision

        public init(
            grantedAt: Date,
            capabilities: [String],
            version: String,
            decision: Decision
        ) {
            self.grantedAt = grantedAt
            self.capabilities = capabilities.sorted()
            self.version = version
            self.decision = decision
        }
    }

    /// On-disk model. Wrapped in a struct so we can extend the file
    /// (e.g. add a schemaVersion) without breaking old readers.
    private struct StoreFile: Codable {
        var grants: [String: Grant]
    }

    public static func defaultURL() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("com.markdownviewer.MarkdownViewer", isDirectory: true)
            .appendingPathComponent("PluginGrants", isDirectory: true)
            .appendingPathComponent("grants.json")
    }

    private let url: URL
    private let lock = NSLock()
    private var cached: StoreFile

    public init(url: URL = PluginGrantStore.defaultURL()) {
        self.url = url
        self.cached = JSONFileStore.read(StoreFile.self, from: url)
            ?? StoreFile(grants: [:])
    }

    /// Decision required for the manifest's full capability set?
    /// Returns:
    ///   - `.required` when no grant exists OR the existing grant was
    ///     for a different (or smaller) capability set than the
    ///     current manifest declares.
    ///   - `.granted` when the user previously said yes for a set
    ///     that covers the current declared set.
    ///   - `.denied` when the user said no for the current set.
    ///     Caller MUST treat this as "don't load contributions." A
    ///     fresh prompt only fires when capabilities change.
    public enum Status: Equatable {
        case required
        case granted
        case denied
    }

    public func status(
        pluginID: String,
        declaredCapabilities: [String]
    ) -> Status {
        lock.lock(); defer { lock.unlock() }
        guard let g = cached.grants[pluginID] else { return .required }
        let declared = Set(declaredCapabilities)
        let granted = Set(g.capabilities)
        // Re-prompt rule: if the declared set isn't a subset of the
        // stored set, the plugin asked for *more* than the user said
        // yes/no to. Re-ask.
        if !declared.isSubset(of: granted) { return .required }
        return g.decision == .granted ? .granted : .denied
    }

    /// Record the user's decision. The decision applies to the
    /// *current* declared capability set; future manifest changes
    /// re-prompt.
    public func record(
        pluginID: String,
        version: String,
        capabilities: [String],
        decision: Decision
    ) {
        lock.lock()
        cached.grants[pluginID] = Grant(
            grantedAt: Date(),
            capabilities: capabilities,
            version: version,
            decision: decision
        )
        let snapshot = cached
        lock.unlock()
        _ = JSONFileStore.write(snapshot, to: url)
    }

    /// Drop any stored grant for `pluginID`. Used by Settings →
    /// Plugins → "Revoke" so the next load re-prompts.
    public func revoke(pluginID: String) {
        lock.lock()
        cached.grants[pluginID] = nil
        let snapshot = cached
        lock.unlock()
        _ = JSONFileStore.write(snapshot, to: url)
    }

    /// All stored grants (read-only snapshot). Used by the Settings
    /// pane to render a list.
    public func allGrants() -> [String: Grant] {
        lock.lock(); defer { lock.unlock() }
        return cached.grants
    }
}
