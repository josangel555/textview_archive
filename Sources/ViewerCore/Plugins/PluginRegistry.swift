import Foundation

/// Plugin host runtime — discovery + lifecycle + per-extension-point
/// registries. v1 supports three plugin shapes:
///
///   - **Bundled (Tier 0).** Swift code compiled into the main bundle.
///     Registers synchronously via `registerBundledSidebarSection`.
///     Used for first-party plugins where typed access to host model
///     types is wanted (e.g. `RowCounterPlugin`). Third-party authors
///     cannot ship bundled-Swift code — design §3.4.
///   - **Tier A** — JSON-only, host-owned data. The contribution is a
///     sidebar section whose rows come from a host-supplied source
///     keyed by plugin id. (Open work: §2.1 "static-bind" expression.)
///   - **Tier B** — `plugin.json` plus an executable. Each row pull
///     spawns the plugin's `bin` and pipes a JSON envelope; the
///     plugin returns rows on stdout. See `PluginSubprocessHost`.
///
/// Each plugin loads independently — a malformed manifest in folder A
/// does NOT prevent folder B from loading. This is our v1 "fail
/// isolation" story at load time. Runtime fail isolation for Tier B
/// comes from the subprocess boundary; for Tier 0/Tier A see the
/// `safeRows` seam.
@MainActor
public final class PluginRegistry {
    public static let shared = PluginRegistry()

    public let sidebarSections = SidebarSectionRegistry()

    /// The Tier B host. Tests can substitute via `_setSubprocessHost`.
    private var subprocessHost: PluginSubprocessHost = PluginSubprocessHost()

    /// Grant store. Required-but-undecided grants block contribution
    /// registration; the host UI must call `recordGrant` before the
    /// contributions become visible. `internal(set)` so tests can
    /// redirect to a temp file without affecting the real grants.json.
    public internal(set) var grantStore: PluginGrantStore

    /// Outcome of one plugin load attempt. The host renders failed
    /// plugins in Settings → Plugins — they're not silently dropped.
    public struct LoadResult: Sendable {
        public enum Status: Sendable, Equatable {
            case loaded
            /// Manifest parsed but contained no usable contributions
            /// for this host version (e.g. Tier C only, or capability
            /// gate failed).
            case loadedWithWarnings([String])
            case failed(reason: String)
            /// Manifest parsed and declares capabilities the user
            /// hasn't decided on yet. UI must prompt and call
            /// `recordGrant` + `reloadOne` to complete the load.
            case awaitingGrant(capabilities: [String])
        }
        public let folder: URL
        public let pluginID: String?  // nil if manifest couldn't be parsed
        public let status: Status
    }

    /// Stable record of what's currently registered. Indexed by plugin
    /// id so `unload(_:)` doesn't have to scan registries.
    public struct LoadedPlugin {
        public let manifest: PluginManifest
        public let folder: URL?  // nil = bundled (in-process)
        public var enabled: Bool
    }
    private(set) public var loaded: [String: LoadedPlugin] = [:]

    public init(
        grantStore: PluginGrantStore = PluginGrantStore(),
        defaults: UserDefaults = .standard
    ) {
        self.grantStore = grantStore
        self.defaults = defaults
    }

    // MARK: - Persisted disabled set (TSK-614)

    /// Backing store for the persisted disabled-plugin set. Injectable
    /// so tests use a throwaway suite instead of `.standard`.
    private let defaults: UserDefaults

    private static let disabledIDsKey = "MarkdownViewer.disabledPluginIDs"

    /// Plugin ids the user has disabled, surviving relaunch. Drives the
    /// "Hide Section" dismiss affordance for bundled plugins (TSK-614 —
    /// the always-on ROW COUNTS section had no way off the screen).
    public var persistedDisabledIDs: Set<String> {
        Set(defaults.stringArray(forKey: Self.disabledIDsKey) ?? [])
    }

    private func persistDisabled(_ id: String, disabled: Bool) {
        var ids = persistedDisabledIDs
        if disabled { ids.insert(id) } else { ids.remove(id) }
        defaults.set(ids.sorted(), forKey: Self.disabledIDsKey)
    }

    /// A bundled plugin's sections, parked while the plugin is disabled
    /// so `setEnabled(true)` can re-register them without re-running the
    /// plugin's launch hook.
    private var dormantSidebarEntries: [String: [SidebarSectionRegistry.Entry]] = [:]

    /// Test seam: swap the subprocess host with a fixture (e.g. one
    /// that returns canned rows without spawning).
    /// `internal` (not `public`): tests reach it via `@testable import`;
    /// keeping it off the public surface avoids handing third parties a
    /// way to swap the subprocess host. See LESSONS.md
    /// "internal-for-testing hooks".
    func _setSubprocessHost(_ host: PluginSubprocessHost) {
        self.subprocessHost = host
    }

    // MARK: - Bundled plugin seam

    /// Register a bundled-Swift plugin. Used by `BundledPlugins/*` at
    /// app launch. Bundled plugins bypass the grant store — they're
    /// first-party code in the host bundle, not third-party plugins.
    public func registerBundledSidebarSection(
        manifest: PluginManifest,
        entry: SidebarSectionRegistry.Entry
    ) {
        // TSK-614: honor a persisted user dismissal across relaunch —
        // the plugin still appears in Settings → Plugins (so it can be
        // re-enabled) but its section stays off the sidebar.
        if persistedDisabledIDs.contains(manifest.id) {
            loaded[manifest.id] = LoadedPlugin(manifest: manifest, folder: nil, enabled: false)
            dormantSidebarEntries[manifest.id, default: []].append(entry)
            return
        }
        loaded[manifest.id] = LoadedPlugin(manifest: manifest, folder: nil, enabled: true)
        sidebarSections.register(entry)
    }

    // MARK: - On-disk discovery

    /// Default plugins root. Matches the bundle id used elsewhere in
    /// the app (TCC-stable per `CLAUDE.md`).
    public static func defaultPluginsDir() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("com.markdownviewer.MarkdownViewer", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
    }

    /// Scan `pluginsDir`, load each plugin folder. Returns a per-
    /// plugin load result. Idempotent — repeated calls do not
    /// double-register, because each load drops the previous plugin's
    /// entries first.
    @discardableResult
    public func loadAll(from pluginsDir: URL = PluginRegistry.defaultPluginsDir()) -> [LoadResult] {
        var results: [LoadResult] = []
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: pluginsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return results  // Missing dir is fine — no plugins installed.
        }
        for folder in folders {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            results.append(loadOne(folder: folder))
        }
        return results
    }

    /// Per-folder load. Parses the manifest, checks grants, then
    /// registers contributions. The grant check is the gate: if the
    /// user hasn't decided on the declared capability set,
    /// contributions don't register and the caller (UI) is told to
    /// prompt.
    public func loadOne(folder: URL) -> LoadResult {
        let manifestURL = folder.appendingPathComponent("plugin.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return LoadResult(folder: folder, pluginID: nil,
                              status: .failed(reason: "missing plugin.json at \(manifestURL.path)"))
        }
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            return LoadResult(folder: folder, pluginID: nil,
                              status: .failed(reason: "manifest parse error: \(error)"))
        }

        // v1: manifestVersion must be exactly 1. Future bumps are
        // breaking and the host must reject unknown majors.
        guard manifest.manifestVersion == 1 else {
            return LoadResult(folder: folder, pluginID: manifest.id,
                              status: .failed(reason: "unsupported manifestVersion \(manifest.manifestVersion)"))
        }

        // Drop any prior registration for this id before re-adding —
        // makes hot-reload (future) and repeated `loadAll` calls safe.
        unload(manifest.id)

        // Grant check. We compute the declared set off the manifest's
        // `capabilities` list (not the union-of-contribution-requireds)
        // so a plugin that declares more than it currently uses still
        // needs explicit grant for the broader set.
        let declared = manifest.capabilities
            .filter { $0 != .unknown }
            .map { $0.rawValue }
            .sorted()
        if !declared.isEmpty {
            let status = grantStore.status(
                pluginID: manifest.id,
                declaredCapabilities: declared
            )
            switch status {
            case .required:
                // Record placeholder so Settings → Plugins can list it
                // (disabled) before the user has chosen.
                loaded[manifest.id] = LoadedPlugin(
                    manifest: manifest, folder: folder, enabled: false
                )
                return LoadResult(folder: folder, pluginID: manifest.id,
                                  status: .awaitingGrant(capabilities: declared))
            case .denied:
                loaded[manifest.id] = LoadedPlugin(
                    manifest: manifest, folder: folder, enabled: false
                )
                return LoadResult(folder: folder, pluginID: manifest.id,
                                  status: .loadedWithWarnings(["user denied capabilities: \(declared.joined(separator: ", "))"]))
            case .granted:
                break
            }
        }

        var warnings: [String] = []
        var registeredAny = false

        for contribution in manifest.contributes {
            switch contribution {
            case .sidebarSection(let s):
                if let warning = registerSidebarSection(
                    section: s, manifest: manifest, folder: folder
                ) {
                    warnings.append(warning)
                } else {
                    registeredAny = true
                }
            case .unknown(let type):
                warnings.append("unknown contribution type '\(type)' — skipped")
            }
        }

        loaded[manifest.id] = LoadedPlugin(
            manifest: manifest, folder: folder, enabled: true
        )

        if registeredAny && warnings.isEmpty {
            return LoadResult(folder: folder, pluginID: manifest.id, status: .loaded)
        }
        return LoadResult(folder: folder, pluginID: manifest.id,
                          status: .loadedWithWarnings(warnings))
    }

    /// Returns nil on success, a warning string on skip.
    private func registerSidebarSection(
        section s: PluginManifest.SidebarSectionContribution,
        manifest: PluginManifest,
        folder: URL
    ) -> String? {
        // Capability gate (no silent escalation — design §5).
        let required = PluginManifest.Contribution.sidebarSection(s).requiredCapabilities
        guard required.isSubset(of: Set(manifest.capabilities)) else {
            let missing = required.subtracting(Set(manifest.capabilities))
                .map { $0.rawValue }.sorted().joined(separator: ", ")
            return "sidebar_section '\(s.id)' missing capability: \(missing)"
        }

        switch s.provider {
        case .a:
            // Tier A static-bind isn't implemented in v1 (see design
            // doc §2.1 follow-up). We emit a placeholder row so the
            // section is visibly registered.
            let entry = SidebarSectionRegistry.Entry(
                pluginID: manifest.id,
                sectionID: s.id,
                title: s.title,
                icon: s.icon,
                order: s.order ?? 100,
                collapsedByDefault: s.collapsedByDefault ?? false,
                provider: { _ in
                    [SidebarSectionRegistry.Row(
                        id: "\(s.id).placeholder",
                        label: "(Tier A static-bind not yet implemented)",
                        detail: nil
                    )]
                }
            )
            sidebarSections.register(entry)
            return nil

        case .b(let bin, let args, let timeoutMs):
            let pluginID = manifest.id
            let sectionID = s.id
            let host = self.subprocessHost
            let entry = SidebarSectionRegistry.Entry(
                pluginID: pluginID,
                sectionID: sectionID,
                title: s.title,
                icon: s.icon,
                order: s.order ?? 100,
                collapsedByDefault: s.collapsedByDefault ?? false,
                provider: { _ in
                    // Synchronous wait on the subprocess. OK because
                    // the timeout cap is small (5s default) and the
                    // sidebar registry's contract is "snapshot → rows".
                    // If real plugins prove the wait visibly janks the
                    // UI we move to async refresh.
                    let result = host.call(
                        pluginID: pluginID,
                        pluginFolder: folder,
                        bin: bin,
                        args: args,
                        timeoutMs: timeoutMs,
                        request: .init(kind: "listRows")
                    )
                    switch result.outcome {
                    case .ok(let resp):
                        return (resp.rows ?? []).map {
                            SidebarSectionRegistry.Row(
                                id: $0.id, label: $0.label, detail: $0.detail
                            )
                        }
                    case .timedOut:
                        return [SidebarSectionRegistry.Row(
                            id: "\(sectionID).err",
                            label: "(plugin timed out)", detail: nil)]
                    case .stdoutOverflow:
                        return [SidebarSectionRegistry.Row(
                            id: "\(sectionID).err",
                            label: "(plugin output too large)", detail: nil)]
                    case .nonZeroExit(let code, _):
                        return [SidebarSectionRegistry.Row(
                            id: "\(sectionID).err",
                            label: "(plugin exited \(code))", detail: nil)]
                    case .spawnFailed(let msg):
                        return [SidebarSectionRegistry.Row(
                            id: "\(sectionID).err",
                            label: "(plugin failed to launch)", detail: msg)]
                    case .decodeFailed:
                        return [SidebarSectionRegistry.Row(
                            id: "\(sectionID).err",
                            label: "(plugin returned invalid JSON)", detail: nil)]
                    }
                }
            )
            sidebarSections.register(entry)
            return nil

        case .c:
            return "sidebar_section '\(s.id)' uses tier C (WebView) — not supported in v1"
        case .unknown(let t):
            return "sidebar_section '\(s.id)' uses unknown tier '\(t)' — skipped"
        }
    }

    public func unload(_ id: String) {
        sidebarSections.dropAll(forPlugin: id)
        dormantSidebarEntries[id] = nil
        loaded[id] = nil
    }

    /// Re-load a single plugin after a grant decision. Used by the
    /// Settings UI prompt.
    @discardableResult
    public func reloadOne(folder: URL) -> LoadResult {
        return loadOne(folder: folder)
    }

    /// Toggle enabled state. Disabled plugins keep their grant but
    /// drop their contributions. Used by Settings → Plugins and the
    /// sidebar section header's "Hide Section" (TSK-614). The decision
    /// is PERSISTED so a dismissal survives relaunch.
    public func setEnabled(_ id: String, enabled: Bool) {
        guard var entry = loaded[id] else { return }
        if entry.enabled == enabled { return }
        persistDisabled(id, disabled: !enabled)
        if enabled {
            guard let folder = entry.folder else {
                // Bundled: re-register the sections parked when the
                // plugin was disabled (or registered-while-disabled).
                for parked in dormantSidebarEntries.removeValue(forKey: id) ?? [] {
                    sidebarSections.register(parked)
                }
                entry.enabled = true
                loaded[id] = entry
                return
            }
            // Third-party: re-register by re-loading the folder.
            _ = reloadOne(folder: folder)
        } else {
            // Bundled sections are parked (not lost) so enable can
            // restore them without re-running the launch hook.
            if entry.folder == nil {
                dormantSidebarEntries[id, default: []]
                    .append(contentsOf: sidebarSections.entries(forPlugin: id))
            }
            sidebarSections.dropAll(forPlugin: id)
            entry.enabled = false
            loaded[id] = entry
        }
    }

    /// Test seam — reset all state between unit tests.
    /// `internal` (not `public`): see `_setSubprocessHost`.
    func _resetForTests() {
        for id in Array(loaded.keys) { unload(id) }
    }
}
