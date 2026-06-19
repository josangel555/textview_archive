import Foundation

/// TSK-963(a) — a pure, injectable SNAPSHOT of the LSP discovery +
/// configuration + status state, per supported language. This is the
/// single read the Settings "Language servers (LSP)" section and a
/// future status indicator consume, replacing the three disconnected
/// reads called out in the productionalization plan (§2.1):
/// `LSPLanguageRegistry.languageStatuses`, `LSPWorkspaceOverrides.load`,
/// and the live `LSPPool` snapshot.
///
/// It answers, for each `LSPLanguage`: *which server exists, is it
/// installed, how is it found (which search paths were probed), and is
/// there a workspace `lsp.json` override in effect — was it honoured or
/// refused, and why.*
///
/// ## Why it's a model, not a service
///
/// All I/O (binary resolution, `lsp.json` load) is **injected** through
/// closures, so `configuration(for:resolve:loadOverrides:)` is fully
/// host-testable with no `xcrun`/`which`/disk access. The app passes the
/// production defaults (`LSPLanguageRegistry.discoverServerBinary` /
/// `LSPWorkspaceOverrides.load`), which DO shell out — so callers should
/// build the snapshot OFF the main thread (the Settings view already
/// loads its status list in a `.task`).
///
/// The trust decision for an override `command` is delegated to the same
/// gate the launcher uses (`LSPLanguageRegistry.isOverrideCommandTrusted`),
/// so this model NEVER diverges from the spawn-time policy: if the model
/// says "honoured", the pool will spawn the override command verbatim; if
/// the model says "refused", the pool falls back to the discovered binary
/// with only the override's args/env. (See `LSPLanguageRegistry.overrideConfig`.)
///
/// Live pool status (`LSPServerStatus`) is intentionally NOT folded in
/// here — it is per-`(language, workspaceRoot)` runtime state owned by the
/// `actor LSPPool` and read via its async snapshot. Keeping this struct
/// free of an actor dependency is what makes the snapshot synchronous +
/// injectable; a caller that already holds a pool snapshot can join the two
/// on `language` at the call site.
public struct LSPLanguageConfig: Sendable, Equatable {

    /// The language this config describes.
    public let language: LSPLanguage

    /// True iff a server binary was resolved for this language on this
    /// machine (via the injected resolver). Mirrors
    /// `LSPLanguageRegistry.LanguageStatus.available`.
    public let available: Bool

    /// Absolute path of the resolved server binary, nil when missing.
    public let resolvedPath: String?

    /// The directory prefixes probed during discovery, in search order
    /// (`LSPDiscovery.augmentedSearchPaths()`). Surfaced so the Settings
    /// section can show *where we looked* for a missing server — the §2.1
    /// "no model the rest of the app can read" gap. Same for every
    /// language (discovery is binary-name-keyed, not language-keyed), but
    /// carried per-config so each row is self-describing.
    public let searchPathsProbed: [String]

    /// The active workspace `lsp.json` override for this language, if any.
    /// Nil when no `lsp.json` exists, it doesn't mention this language, or
    /// the entry was dropped at load time (missing `command` / unknown key).
    public let activeOverride: ActiveOverride?

    public init(
        language: LSPLanguage,
        available: Bool,
        resolvedPath: String?,
        searchPathsProbed: [String],
        activeOverride: ActiveOverride?
    ) {
        self.language = language
        self.available = available
        self.resolvedPath = resolvedPath
        self.searchPathsProbed = searchPathsProbed
        self.activeOverride = activeOverride
    }

    /// A workspace `lsp.json` override that names this language, plus the
    /// trust verdict applied to its `command`. The verdict matches the
    /// spawn-time policy exactly (`overrideConfig`): a refused command is
    /// NOT spawned — discovery's binary is used with the override's args/env.
    public struct ActiveOverride: Sendable, Equatable {
        /// The override's `command` (the binary path it asked us to spawn),
        /// verbatim from `lsp.json` — for display + diagnostics.
        public let command: String
        /// The override's `args` (verbatim from `lsp.json`).
        public let arguments: [String]
        /// Whether the override declared its own `env`. We surface the
        /// presence (not the values — env may carry secrets) so the UI can
        /// note "this workspace customises the server environment".
        public let definesEnvironment: Bool
        /// Absolute path of the `lsp.json` file the override came from.
        public let sourceFile: String
        /// True iff the override's `command` passed the trust gate and will
        /// be spawned verbatim. False ⇒ refused (untrusted) and the
        /// discovered binary is used instead (`overrideRefusedReason` set).
        public let overrideHonored: Bool
        /// Human-readable reason the override `command` was refused, or nil
        /// when honoured. Mirrors `isOverrideCommandTrusted`'s two refusal
        /// causes: in-workspace command, or group/world-writable dir.
        public let overrideRefusedReason: String?

        public init(
            command: String,
            arguments: [String],
            definesEnvironment: Bool,
            sourceFile: String,
            overrideHonored: Bool,
            overrideRefusedReason: String?
        ) {
            self.command = command
            self.arguments = arguments
            self.definesEnvironment = definesEnvironment
            self.sourceFile = sourceFile
            self.overrideHonored = overrideHonored
            self.overrideRefusedReason = overrideRefusedReason
        }
    }
}

/// Static builder for the snapshot. Namespaced under `LSPConfiguration`
/// rather than a stored type — there's no instance state; the snapshot is
/// the `[LSPLanguageConfig]` array.
public enum LSPConfiguration {

    /// Reasons a workspace `lsp.json` override command can be refused.
    /// Computed by replaying `isOverrideCommandTrusted`'s two checks so the
    /// UI can show *why* (the gate itself only returns a Bool). Order
    /// matches the gate: the writable-dir check runs first, then the
    /// in-workspace check.
    public enum RefusalReason: String, Sendable, Equatable {
        /// The command's containing directory is group/world-writable, so a
        /// non-owner could swap the binary (`isBinarySafeToSpawn` == false).
        case writableDir
        /// The command's canonical path is inside the workspace subtree —
        /// the exact RCE vector (a binary checked into / dropped under the
        /// repo).
        case insideWorkspace

        public var message: String {
            switch self {
            case .writableDir:
                return "Command's directory is group/world-writable; "
                    + "a non-owner could replace the binary."
            case .insideWorkspace:
                return "Command is inside the workspace; an untrusted repo "
                    + "could ship a malicious server binary."
            }
        }
    }

    /// Build the discovery + override + status snapshot for a workspace.
    ///
    /// - Parameters:
    ///   - workspaceRoot: the resolved workspace root used to (a) load
    ///     `lsp.json` and (b) run the in-workspace trust check against any
    ///     override command. Pass the same root the pool's launcher resolves.
    ///   - resolve: server-binary resolver per language. Injected for
    ///     host-testing; `nil` ⇒ production default
    ///     `LSPLanguageRegistry.discoverServerBinary` (shells out to
    ///     `xcrun`/`which` + probes PATH). (The internal helpers can't be
    ///     named as default-argument values from a `public` signature, so the
    ///     production defaults are filled in inside the body when an arg is nil.)
    ///   - loadOverrides: `lsp.json` loader. `nil` ⇒ `LSPWorkspaceOverrides.load`.
    ///   - searchPaths: the probed-prefix list. `nil` ⇒
    ///     `LSPDiscovery.augmentedSearchPaths` (reads `$PATH` + `$HOME`).
    ///   - isTrusted: the override-command trust gate. `nil` ⇒
    ///     `LSPLanguageRegistry.isOverrideCommandTrusted`.
    ///
    /// - Returns: one `LSPLanguageConfig` per `LSPLanguage`, in
    ///   `LSPLanguage.allCases` order. Synchronous; the default closures do
    ///   I/O, so run off the main thread in the live app.
    public static func configuration(
        for workspaceRoot: URL,
        resolve: ((LSPLanguage) -> URL?)? = nil,
        loadOverrides: ((URL) -> LSPWorkspaceOverrides?)? = nil,
        searchPaths: (() -> [String])? = nil,
        isTrusted: ((URL, URL) -> Bool)? = nil
    ) -> [LSPLanguageConfig] {
        let resolver = resolve ?? { LSPLanguageRegistry.discoverServerBinary(for: $0) }
        let loader = loadOverrides ?? { LSPWorkspaceOverrides.load(workspaceRoot: $0) }
        let pathsProbe = searchPaths ?? { LSPDiscovery.augmentedSearchPaths() }
        let trustGate = isTrusted
            ?? { LSPLanguageRegistry.isOverrideCommandTrusted($0, workspaceRoot: $1) }

        let overrides = loader(workspaceRoot)
        let probed = pathsProbe()

        return LSPLanguage.allCases.map { language in
            let resolved = resolver(language)
            let active = overrideConfig(
                for: language,
                overrides: overrides,
                workspaceRoot: workspaceRoot,
                isTrusted: trustGate)
            return LSPLanguageConfig(
                language: language,
                available: resolved != nil,
                resolvedPath: resolved?.path,
                searchPathsProbed: probed,
                activeOverride: active)
        }
    }

    /// Resolve the active-override descriptor for one language from an
    /// already-loaded overrides snapshot. Extracted so the trust verdict +
    /// refusal-reason derivation is testable in isolation and shared by the
    /// per-language map above.
    static func overrideConfig(
        for language: LSPLanguage,
        overrides: LSPWorkspaceOverrides?,
        workspaceRoot: URL,
        isTrusted: (URL, URL) -> Bool
    ) -> LSPLanguageConfig.ActiveOverride? {
        guard let overrides, let entry = overrides.servers[language] else {
            return nil
        }
        let binaryURL = URL(fileURLWithPath: entry.command)
        let honored = isTrusted(binaryURL, workspaceRoot)
        let refusedReason: String? = honored
            ? nil
            : refusalReason(for: binaryURL, workspaceRoot: workspaceRoot)?.message

        return LSPLanguageConfig.ActiveOverride(
            command: entry.command,
            arguments: entry.arguments,
            definesEnvironment: !entry.environment.isEmpty,
            sourceFile: overrides.sourceFile.path,
            overrideHonored: honored,
            overrideRefusedReason: refusedReason)
    }

    /// Recompute *which* of the trust gate's two checks failed, for the
    /// human-readable reason string. Mirrors
    /// `LSPLanguageRegistry.isOverrideCommandTrusted` check order exactly:
    /// writable-dir first, then in-workspace. Returns nil if neither check
    /// fails (i.e. the command is trusted) — callers only invoke this when
    /// the gate already returned false, so a nil here means the injected
    /// gate diverged from the real policy (test-only situation).
    static func refusalReason(
        for binaryURL: URL,
        workspaceRoot: URL
    ) -> RefusalReason? {
        let canonical = binaryURL.resolvingSymlinksInPath().standardizedFileURL
        if !LSPDiscovery.isBinarySafeToSpawn(atPath: canonical.path) {
            return .writableDir
        }
        if LSPLanguageRegistry.isPath(canonical, inSubtreeOf: workspaceRoot) {
            return .insideWorkspace
        }
        return nil
    }
}
