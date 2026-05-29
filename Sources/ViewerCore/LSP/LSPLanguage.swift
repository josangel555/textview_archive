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
                guard let binary = LSPDiscovery.locate(binary: "jdtls") else {
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

    /// Translate a workspace-root override (LSP_DESIGN.md §11, per-
    /// workspace placement) into an `LSPClient.Config`. Returns nil
    /// when no override file is present, no entry matches the
    /// language, or the override's `command` points at a file that
    /// does not exist on disk — in the last case a warning is
    /// emitted and we fall back to default discovery so a stale
    /// override file doesn't lock the user out (matches §11's "never
    /// crash on bad config" stance).
    ///
    /// `defaultArguments` are accepted for forward-compat — today the
    /// override's `args` array is honoured verbatim (an absent JSON
    /// key parses as `[]`, so we can't distinguish "omitted" from
    /// "deliberately empty"; the conservative choice for an explicit
    /// override is "user is taking over spawn configuration").
    public static func overrideConfig(
        for language: LSPLanguage,
        workspaceRoot: URL,
        defaultArguments: [String]
    ) -> LSPClient.Config? {
        _ = defaultArguments
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
        return LSPClient.Config(
            executable: binaryURL,
            arguments: entry.arguments,
            workspaceRoot: workspaceRoot,
            environment: overrides.mergedEnvironment(for: language))
    }
}
