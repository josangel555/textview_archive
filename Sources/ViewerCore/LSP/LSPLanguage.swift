import Foundation

/// Language descriptor used by the LSP layer. One value per LSP-supported
/// language. Adding a new language is two things:
///   1. Add a `LSPLanguage` case.
///   2. Register it in `LSPLanguageRegistry.default` with a server-spawner
///      closure and a workspace-root finder.
///
/// File-extension → language lookup goes through `LSPLanguageRegistry`,
/// not this enum, so a single language can claim multiple extensions
/// (`.swift` only for Swift; `.ts/.tsx/.js/.jsx` for the TS server).
public enum LSPLanguage: String, Sendable, Hashable, CaseIterable {
    case swift
    /// Single server (`typescript-language-server`) drives TS, TSX, JS,
    /// and JSX. Per LSP spec the `languageId` differs per file extension
    /// — handled via `languageID(for:)` which takes a file URL.
    case typescript
    case java
    case python
    // Add cases here as servers land. Each new case requires a
    // registration in `LSPLanguageRegistry.default`.

    /// LSP `languageId` string passed in `textDocument/didOpen`. Spec
    /// defines a fixed set ([LSP 3.17 §TextDocumentItem][lsp-langid]);
    /// pick the canonical name. For multi-extension languages (TS) the
    /// answer depends on the file's extension — see `languageID(for:)`.
    public var languageID: String {
        switch self {
        case .swift:      return "swift"
        case .typescript: return "typescript"
        case .java:       return "java"
        case .python:     return "python"
        }
    }

    /// Per-file `languageId` resolution. For most languages this is
    /// just `languageID` (constant). The TS server distinguishes
    /// `typescript` / `typescriptreact` / `javascript` / `javascriptreact`
    /// per file extension — semantic diagnostics differ.
    public func languageID(for fileURL: URL) -> String {
        switch self {
        case .typescript:
            switch fileURL.pathExtension.lowercased() {
            case "ts":  return "typescript"
            case "tsx": return "typescriptreact"
            case "js":  return "javascript"
            case "jsx": return "javascriptreact"
            case "mjs", "cjs": return "javascript"
            default:    return "typescript"
            }
        default:
            return languageID
        }
    }

    /// Display label for the dev diagnostics panel.
    public var displayName: String {
        switch self {
        case .swift:      return "Swift (sourcekit-lsp)"
        case .typescript: return "TypeScript / JavaScript (typescript-language-server)"
        case .java:       return "Java (jdtls)"
        case .python:     return "Python (pyright)"
        }
    }

    /// User-facing install hint when the server binary isn't found on
    /// the user's PATH. Surfaced in the Settings diagnostics panel and
    /// in toast notifications.
    public var installHint: String? {
        switch self {
        case .swift:
            // sourcekit-lsp ships with the toolchain — no install step.
            return nil
        case .typescript:
            return "npm i -g typescript-language-server typescript"
        case .java:
            return "brew install jdtls   # or download from https://download.eclipse.org/jdtls/snapshots/"
        case .python:
            return "npm i -g pyright   # or: pip install pyright"
        }
    }

    /// Binary name probed against PATH + common Homebrew dirs by
    /// `LSPDiscovery.locate(binary:)`. For Java this is the launcher
    /// wrapper script `jdtls` (community Homebrew tap) — the raw `java
    /// -jar` invocation is left out of v1; users with a custom
    /// install can wire `lsp.json` override (LSP_DESIGN.md §11) once
    /// shipped.
    public var binaryName: String? {
        switch self {
        case .swift:      return "sourcekit-lsp"
        case .typescript: return "typescript-language-server"
        case .java:       return "jdtls"
        case .python:     return "pyright-langserver"
        }
    }
}

/// Plug-point a language registers to find the workspace root for a
/// given file URL. Closure returns nil if no enclosing root is found;
/// the caller may then fall back to "single-file mode" (server spawned
/// with the file's parent dir) at its discretion.
public typealias LSPRootFinder = @Sendable (URL) -> URL?

/// Plug-point a language registers to locate + launch its server.
/// Returns a fully-configured `LSPClient.Config` ready to hand to
/// `LSPClient.init`, or nil if the server binary can't be located.
///
/// `workspaceRoot` is the already-resolved root (per `LSPRootFinder`).
public typealias LSPServerLauncher = @Sendable (_ workspaceRoot: URL) -> LSPClient.Config?

/// One entry per language we know how to drive.
public struct LSPLanguageEntry: Sendable {
    public let language: LSPLanguage
    /// Lowercased file extensions (without leading dot) that map to
    /// this language. First match wins in `LSPLanguageRegistry.language(for:)`.
    public let fileExtensions: Set<String>
    public let rootFinder: LSPRootFinder
    public let serverLauncher: LSPServerLauncher

    public init(
        language: LSPLanguage,
        fileExtensions: Set<String>,
        rootFinder: @escaping LSPRootFinder,
        serverLauncher: @escaping LSPServerLauncher
    ) {
        self.language = language
        self.fileExtensions = fileExtensions
        self.rootFinder = rootFinder
        self.serverLauncher = serverLauncher
    }
}

/// Immutable registry. The `default` static is the only one we ship;
/// `LSPPool` reads it at construction time. Tests can inject a custom
/// registry to stub a language without touching real binaries.
public struct LSPLanguageRegistry: Sendable {

    public let entries: [LSPLanguageEntry]

    public init(entries: [LSPLanguageEntry]) {
        self.entries = entries
    }

    /// Resolve a file URL to a language entry by extension. Case-insensitive.
    /// Returns nil for unknown extensions; caller should treat that as
    /// "LSP not available for this file".
    public func language(for fileURL: URL) -> LSPLanguageEntry? {
        let ext = fileURL.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        return entries.first { $0.fileExtensions.contains(ext) }
    }

    public func entry(for language: LSPLanguage) -> LSPLanguageEntry? {
        return entries.first { $0.language == language }
    }

    // MARK: - Default registry

    /// Built-in registry. One entry per supported language. New languages
    /// are added here; UI and pool layers pick them up automatically.
    ///
    /// Each `serverLauncher` first consults
    /// `LSPWorkspaceOverrides.load(workspaceRoot:)` (the per-workspace
    /// `lsp.json` file from LSP_DESIGN.md §11) for a matching entry; if
    /// present, the override wins over default discovery. When no
    /// override file exists, default discovery runs unchanged.
    public static let `default` = LSPLanguageRegistry(entries: [
        .init(
            language: .swift,
            fileExtensions: ["swift"],
            rootFinder: { fileURL in
                LSPDiscovery.swiftPackageRoot(for: fileURL)
            },
            serverLauncher: { workspaceRoot in
                if let cfg = LSPLanguageRegistry.overrideConfig(
                    for: .swift, workspaceRoot: workspaceRoot,
                    defaultArguments: []
                ) {
                    return cfg
                }
                guard let binary = LSPDiscovery.locateSourceKitLSP() else {
                    return nil
                }
                return LSPClient.Config(
                    executable: binary,
                    arguments: [],
                    workspaceRoot: workspaceRoot)
            }
        ),
        .init(
            language: .typescript,
            fileExtensions: ["ts", "tsx", "js", "jsx", "mjs", "cjs"],
            rootFinder: { fileURL in
                LSPDiscovery.tsWorkspaceRoot(for: fileURL)
            },
            serverLauncher: { workspaceRoot in
                if let cfg = LSPLanguageRegistry.overrideConfig(
                    for: .typescript, workspaceRoot: workspaceRoot,
                    defaultArguments: ["--stdio"]
                ) {
                    return cfg
                }
                guard let binary = LSPDiscovery.locate(binary: "typescript-language-server") else {
                    return nil
                }
                return LSPClient.Config(
                    executable: binary,
                    arguments: ["--stdio"],
                    workspaceRoot: workspaceRoot)
            }
        ),
        .init(
            language: .java,
            fileExtensions: ["java"],
            rootFinder: { fileURL in
                LSPDiscovery.javaWorkspaceRoot(for: fileURL)
            },
            serverLauncher: { workspaceRoot in
                // jdtls requires `-data <workspaceDir>` for default
                // discovery; if the user overrides we trust them to
                // supply any data-dir handling in their `args` (e.g.
                // they may already wrap jdtls in a launcher script).
                if let cfg = LSPLanguageRegistry.overrideConfig(
                    for: .java, workspaceRoot: workspaceRoot,
                    defaultArguments: []
                ) {
                    return cfg
                }
                // PATH/Homebrew `jdtls` first, then the `redhat.java` VS
                // Code extension's bundled launcher (TSK-797).
                guard let binary = LSPLanguageRegistry.discoverServerBinary(for: .java) else {
                    return nil
                }
                // jdtls requires `-data <workspaceDir>` — a per-workspace
                // state directory outside the project. Stash under app
                // support keyed by workspace path hash. Cold-start cost
                // is 30-90s on a typical Maven/Gradle project; user is
                // warned via the install hint surface.
                let dataDir = LSPDiscovery.jdtlsDataDirectory(for: workspaceRoot)
                return LSPClient.Config(
                    executable: binary,
                    arguments: ["-data", dataDir.path],
                    workspaceRoot: workspaceRoot)
            }
        ),
        .init(
            language: .python,
            fileExtensions: ["py", "pyi"],
            rootFinder: { fileURL in
                LSPDiscovery.pythonWorkspaceRoot(for: fileURL)
            },
            serverLauncher: { workspaceRoot in
                if let cfg = LSPLanguageRegistry.overrideConfig(
                    for: .python, workspaceRoot: workspaceRoot,
                    defaultArguments: ["--stdio"]
                ) {
                    return cfg
                }
                guard let binary = LSPDiscovery.locate(binary: "pyright-langserver") else {
                    return nil
                }
                return LSPClient.Config(
                    executable: binary,
                    arguments: ["--stdio"],
                    workspaceRoot: workspaceRoot)
            }
        ),
    ])

    /// TSK-789: a Settings-facing summary of one LSP language + whether its
    /// server binary is currently discoverable on this machine.
    public struct LanguageStatus: Equatable, Sendable {
        public let language: LSPLanguage
        public let available: Bool
        /// Absolute path of the discovered server binary (nil when missing).
        public let resolvedPath: String?
    }

    /// TSK-789: the supported-LSP-languages + availability list for the Settings
    /// "Language Servers" section. `resolve` is injected so this is host-testable
    /// without touching real binaries / running `xcrun`/`which`; the app passes
    /// the default (`discoverServerBinary`, which probes PATH + the toolchain).
    /// Synchronous — the default resolver shells out, so callers should run this
    /// OFF the main thread (the Settings view loads it in a `.task`).
    public static func languageStatuses(
        resolve: ((LSPLanguage) -> URL?)? = nil
    ) -> [LanguageStatus] {
        let resolver = resolve ?? { discoverServerBinary(for: $0) }
        return LSPLanguage.allCases.map { lang in
            let url = resolver(lang)
            return LanguageStatus(
                language: lang, available: url != nil, resolvedPath: url?.path)
        }
    }

    /// Translate a workspace-root override (LSP_DESIGN.md §11, per-
    /// workspace placement) into an `LSPClient.Config`. Returns nil
    /// when no override file is present, no entry matches the
    /// language, or the override's `command` points at a file that
    /// does not exist on disk — in the last case a warning is
    /// emitted and we fall back to default discovery so a stale
    /// override file doesn't lock the user out (matches §11's "never
    /// crash on bad config" stance).
    ///
    /// ## Interim trust hardening (SEC-001 / SEC-002)
    ///
    /// `lsp.json` lives **inside the workspace**, so a hostile repo
    /// can ship one that points `command` at an attacker-controlled
    /// binary and get arbitrary code execution the moment a file in
    /// that repo is opened. The real fix is a trust-UI ("this
    /// workspace wants to run `<x>` as its language server — allow?"),
    /// which is surface-only work tracked separately. Until that
    /// ships we apply a conservative interim policy here:
    ///
    ///   1. **`command` is only honoured if it is plausibly trusted.**
    ///      A command is trusted iff it (a) passes
    ///      `LSPDiscovery.isBinarySafeToSpawn` (its containing dir is
    ///      not group/world-writable) **and** (b) its canonical
    ///      resolved path is **outside** the `workspaceRoot` subtree.
    ///      A binary checked into / dropped under the workspace is the
    ///      exact RCE vector we refuse: `./node_modules/.bin/evil`,
    ///      `./.tools/sourcekit-lsp`, etc.
    ///   2. **When `command` is not trusted we ignore the WHOLE
    ///      override** (TSK-963) and fall back to default discovery for
    ///      this language's real server binary, spawned with ONLY the
    ///      language's `defaultArguments` and the scrubbed base env —
    ///      the override's `args`, `env`, and `initializationOptions`
    ///      are all dropped. A hostile `lsp.json` that names an
    ///      untrusted command also controls those fields, and many
    ///      servers honour args (`--require`/`--plugin`/`--tsserver`/
    ///      config-path flags) or env (`NODE_OPTIONS`-class vars are not
    ///      name-scrubbed) that load attacker-controlled code from the
    ///      workspace — so applying them would turn a trusted binary
    ///      into the injection vector even though no untrusted
    ///      executable was named. The conservative posture is "an
    ///      untrusted override contributes nothing". If discovery also
    ///      fails we return nil (no server) rather than spawn an
    ///      untrusted path.
    ///   3. **The child env is scrubbed** at this boundary
    ///      (`scrubbedLaunchEnvironment`) on BOTH paths, so the language
    ///      server never inherits the app's `*_TOKEN` / `*_SECRET` /
    ///      `AWS_*` / cloud creds. On the trusted-command path the
    ///      override's `env` is layered on top of that scrubbed base;
    ///      on the untrusted/discovered path only the scrubbed base is
    ///      used (no override env).
    ///
    /// The override's `args`/`env`/`initializationOptions` are honoured
    /// ONLY when the `command` itself passed the trust gate (the user is
    /// then knowingly taking over spawn configuration). On the
    /// untrusted/discovered path the discovered server is spawned with
    /// `defaultArguments` and the scrubbed base env exclusively.
    public static func overrideConfig(
        for language: LSPLanguage,
        workspaceRoot: URL,
        defaultArguments: [String]
    ) -> LSPClient.Config? {
        guard let overrides = LSPWorkspaceOverrides.load(
            workspaceRoot: workspaceRoot
        ) else {
            return nil
        }
        guard let entry = overrides.servers[language] else {
            return nil
        }
        let binaryURL = URL(fileURLWithPath: entry.command)
        guard FileManager.default.fileExists(atPath: binaryURL.path) else {
            LSPLog.warn(
                "LSP override command not found on disk: \(entry.command) (\(overrides.sourceFile.path))")
            return nil
        }

        // SEC-002: scrubbed base env is the floor on BOTH branches. A
        // server spawned via an override never inherits the app's
        // unscrubbed environment (no `*_TOKEN`/`*_SECRET`/`AWS_*` leak).
        // `mergedEnvironment` returns nil when the override declares no
        // env of its own; we deliberately do NOT propagate that nil
        // (which `LSPClient` treats as "inherit the full parent env").
        let baseEnv = scrubbedLaunchEnvironment()

        // SEC-001-interim: decide whether to trust the override command.
        if isOverrideCommandTrusted(binaryURL, workspaceRoot: workspaceRoot) {
            // Trusted command — the user is knowingly taking over spawn
            // config, so honour the override's args and env (env still
            // floored at the scrubbed base; the override layers on top).
            //
            // TSK-980 / M5: trusting the *command* does NOT mean trusting
            // arbitrary code-injection env vars. `mergedEnvironment`
            // strips the `NODE_OPTIONS` / `DYLD_*` / `PYTHONSTARTUP` / …
            // denylist from the override's own keys before layering, so a
            // repo can't weaponise a legitimately-trusted system server
            // binary by shipping a hostile `env` block.
            let environment = overrides.mergedEnvironment(
                for: language, parent: baseEnv) ?? baseEnv
            return LSPClient.Config(
                executable: binaryURL,
                arguments: entry.arguments,
                workspaceRoot: workspaceRoot,
                environment: environment,
                initializationOptions: entry.initializationOptions)
        }

        // Untrusted command. Refuse to spawn it; instead discover the
        // real server binary.
        //
        // SEC-001 (TSK-963): on this fallback we apply NEITHER the
        // override's `args` NOR its `env` to the trusted discovered
        // server. A hostile `lsp.json` that names an untrusted command
        // also controls those fields, and many servers honour args
        // (`--require`/`--plugin`/`--tsserver`/config-path flags) or
        // env (`NODE_OPTIONS`-class vars are not name-scrubbed) that
        // load attacker-controlled code from the workspace — turning a
        // trusted binary into the injection vector without ever naming
        // an untrusted executable. The conservative posture is "an
        // untrusted override contributes nothing": only `defaultArguments`
        // and the scrubbed base env. The override's `args`/`env`/
        // `initializationOptions` are honoured ONLY when the command
        // itself passed the trust gate (the trusted branch above).
        LSPLog.warn(
            "LSP override command refused (untrusted: inside workspace or "
            + "writable dir): \(entry.command) (\(overrides.sourceFile.path)); "
            + "falling back to discovered \(language.binaryName ?? "<server>") "
            + "with default args/env (override args/env ignored)")
        guard let discovered = discoverServerBinary(for: language) else {
            return nil
        }
        return LSPClient.Config(
            executable: discovered,
            arguments: defaultArguments,
            workspaceRoot: workspaceRoot,
            environment: baseEnv)
    }

    /// A workspace-supplied override `command` is trusted iff its
    /// containing directory is not group/world-writable AND its
    /// canonical path is not inside the workspace subtree. See
    /// `overrideConfig` for the full rationale (SEC-001 interim).
    static func isOverrideCommandTrusted(
        _ binaryURL: URL,
        workspaceRoot: URL
    ) -> Bool {
        let canonical = binaryURL.resolvingSymlinksInPath()
            .standardizedFileURL
        if !LSPDiscovery.isBinarySafeToSpawn(atPath: canonical.path) {
            return false
        }
        if isPath(canonical, inSubtreeOf: workspaceRoot) {
            return false
        }
        return true
    }

    /// True iff `path`'s canonical location is the workspace root or a
    /// descendant of it. Both sides are resolved through symlinks +
    /// standardized so `lsp.json` can't escape the check with `../` or
    /// a symlinked binary that lands back inside the tree.
    static func isPath(_ path: URL, inSubtreeOf root: URL) -> Bool {
        let canonicalRoot = root.resolvingSymlinksInPath()
            .standardizedFileURL
        let rootComponents = canonicalRoot.pathComponents
        let pathComponents = path.resolvingSymlinksInPath()
            .standardizedFileURL.pathComponents
        guard pathComponents.count >= rootComponents.count else {
            return false
        }
        // Component-wise prefix match avoids the `/foo` vs `/foobar`
        // false positive that a raw `hasPrefix(string)` would hit.
        return Array(pathComponents.prefix(rootComponents.count))
            == rootComponents
    }

    /// Discover this language's real server binary via the same path
    /// `serverLauncher` uses for default discovery (which already runs
    /// every candidate through `isBinarySafeToSpawn`). Returns nil when
    /// the server isn't installed.
    ///
    /// Order: PATH + Homebrew + npm prefixes first (an explicitly-installed
    /// server the user manages wins), then — for languages where a VS
    /// Code-family extension bundles a reusable stdio server — the
    /// editor's extensions directory (TSK-797). So a user with VS Code /
    /// Cursor installed gets LSP "for free" without a separate install.
    static func discoverServerBinary(for language: LSPLanguage) -> URL? {
        switch language {
        case .swift:
            // The Swift VS Code extension defers to the toolchain's
            // sourcekit-lsp, so `xcrun` is the right (and only) path here.
            return LSPDiscovery.locateSourceKitLSP()
        default:
            if let name = language.binaryName,
               let onPath = LSPDiscovery.locate(binary: name) {
                return onPath
            }
            // Fallback: a VS Code-family extension may ship the server.
            return LSPVSCodeExtensions.locateServer(for: language)
        }
    }

    /// Scrubbed base environment for an LSP child spawned via an
    /// override (SEC-002). Mirrors the not-passed list documented on
    /// `PluginSubprocessHost.scrubbedEnvironment` but is less strict:
    /// language servers legitimately need `PATH` (to find `node` /
    /// toolchain helpers), `HOME` (config/cache), locale, and
    /// `TMPDIR`. We pass that allowlist through and drop everything
    /// else — crucially every credential-shaped var
    /// (`*_TOKEN` / `*_SECRET` / `*_KEY` / `AWS_*` / cloud).
    ///
    /// Returned env is the *base*; the override's own `env` is layered
    /// on top by `mergedEnvironment`, so a user who genuinely needs an
    /// extra var can opt it back in explicitly per-workspace.
    static func scrubbedLaunchEnvironment(
        parent: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        // Exact-name allowlist: vars an honest server needs.
        let allowExact: Set<String> = [
            "PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "USER", "LOGNAME",
            // Toolchain locators that servers shell out through.
            "DEVELOPER_DIR", "SDKROOT", "TOOLCHAINS",
            "JAVA_HOME", "NODE_PATH", "NPM_CONFIG_PREFIX",
            "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME",
        ]
        var env: [String: String] = [:]
        for (k, v) in parent {
            // TSK-980 / M5: hard floor — a code-injection env var
            // (`NODE_OPTIONS`, `DYLD_*`, `PYTHONSTARTUP`, …) must never
            // survive into an LSP child, even if it were ever added to
            // `allowExact`. This denylist wins over the allowlist.
            if LSPWorkspaceOverrides.isDangerousEnvName(k) {
                continue
            }
            if allowExact.contains(k) || k.hasPrefix("LC_") {
                env[k] = v
            }
        }
        return env
    }
}
