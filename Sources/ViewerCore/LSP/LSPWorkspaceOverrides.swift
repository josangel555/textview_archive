import Foundation

/// Per-workspace LSP server overrides loaded from `lsp.json` at the
/// workspace root. Implements `LSP_DESIGN.md` §11 (the design draft
/// names a single user-level file under
/// `~/Library/Application Support/TextView/lsp.json`; this loader
/// addresses the per-workspace placement variant called out in the
/// follow-up work item — same JSON shape, different on-disk location).
///
/// Schema (subset of §11 that has live language entries; unknown
/// language keys are ignored so adding new entries to §11 doesn't
/// require touching this loader):
///
/// ```jsonc
/// {
///   "servers": {
///     "swift": {
///       "command": "/Users/me/swift-toolchain/usr/bin/sourcekit-lsp",
///       "args": [],
///       "env": { "SOURCEKIT_LOGGING": "1" }
///     },
///     "typescript": {
///       "command": "/opt/homebrew/bin/typescript-language-server",
///       "args": ["--stdio"]
///     }
///   }
/// }
/// ```
///
/// Language keys recognised (case-insensitive):
///   - `swift` / `sourcekitlsp`
///   - `typescript` / `typescriptlanguageserver`
///   - `python` / `pyright`
///   - `java` / `jdtls`
///
/// Behaviour:
///   - File missing → returns nil. Default discovery is used unchanged.
///   - File present but malformed JSON → returns nil + logs a single
///     warning line via `LSPLog.warn`. Default discovery is used.
///   - Entries missing required `command` field are dropped silently
///     (matching §11: "Missing required fields → reject that entry.
///     Never crash on bad config.").
///   - `args` defaults to `[]` when absent.
///   - `env` defaults to `[:]` when absent; an empty env means the
///     child inherits the parent env unchanged. A non-empty env is
///     **merged on top of** the current process environment when the
///     override fires (see `mergedEnvironment(parent:)`).
///   - `initializationOptions` from §11 is currently parsed but not
///     forwarded — `LSPClient.initialize()` ignores per-server
///     init options today. Field is kept on the model so a future
///     wiring change is local. (TODO: thread through `LSPClient.Config`.)
///
/// Loader is **synchronous + cheap** — one file read per workspace
/// resolution. The pool calls per-launcher (per cold-spawn), which is
/// already a rare event; no caching needed. Matching §11's "read once
/// on app startup" guidance is harder for per-workspace files because
/// the workspace set is open-ended, so we accept the per-launch read.
public struct LSPWorkspaceOverrides: Sendable, Equatable {

    /// File name searched at the workspace root.
    public static let fileName = "lsp.json"

    /// One server-override entry. All fields except `command` are
    /// optional in the JSON; defaults match the §11 description.
    public struct ServerOverride: Sendable, Equatable {
        public let command: String
        public let arguments: [String]
        public let environment: [String: String]
        public let initializationOptions: Data?

        public init(
            command: String,
            arguments: [String] = [],
            environment: [String: String] = [:],
            initializationOptions: Data? = nil
        ) {
            self.command = command
            self.arguments = arguments
            self.environment = environment
            self.initializationOptions = initializationOptions
        }
    }

    /// Resolved overrides keyed by `LSPLanguage`. Unknown / invalid
    /// entries are dropped at load time so callers only see live data.
    public let servers: [LSPLanguage: ServerOverride]

    /// Absolute path of the loaded file (useful for diagnostics /
    /// logging — included so a stale override file's location is
    /// obvious in dev-panel output).
    public let sourceFile: URL

    public init(
        servers: [LSPLanguage: ServerOverride],
        sourceFile: URL
    ) {
        self.servers = servers
        self.sourceFile = sourceFile
    }

    // MARK: - Loader

    /// Read `<workspaceRoot>/lsp.json` and parse it. Returns nil when:
    ///   - the file does not exist (the common case — no override),
    ///   - the file is unreadable,
    ///   - the JSON is malformed at the top level,
    ///   - no recognised server entries survive validation.
    ///
    /// Never throws — the design (§11) mandates "never crash on bad
    /// config". Bad files degrade to "default discovery".
    public static func load(workspaceRoot: URL) -> LSPWorkspaceOverrides? {
        let file = workspaceRoot.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: file) else {
            LSPLog.warn("LSP override unreadable: \(file.path)")
            return nil
        }
        return parse(data: data, sourceFile: file)
    }

    /// JSON-level parse exposed for tests. Same nil semantics as
    /// `load(workspaceRoot:)`.
    public static func parse(
        data: Data, sourceFile: URL
    ) -> LSPWorkspaceOverrides? {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(
                with: data, options: [.fragmentsAllowed]
            )
        } catch {
            LSPLog.warn("LSP override malformed JSON: \(sourceFile.path): \(error)")
            return nil
        }
        guard let obj = root as? [String: Any] else {
            LSPLog.warn(
                "LSP override root is not an object: \(sourceFile.path)")
            return nil
        }
        guard let serversObj = obj["servers"] as? [String: Any] else {
            // `servers` missing or wrong type → no recognisable
            // overrides. Treat as absent rather than as an error.
            return nil
        }

        var resolved: [LSPLanguage: ServerOverride] = [:]
        for (rawKey, rawValue) in serversObj {
            guard let language = languageFor(key: rawKey) else {
                // Unknown server key — design §11: "Unknown server
                // name → ignore that entry."
                continue
            }
            guard let entryObj = rawValue as? [String: Any] else {
                LSPLog.warn(
                    "LSP override entry for \"\(rawKey)\" is not an object")
                continue
            }
            guard let command = entryObj["command"] as? String,
                  !command.isEmpty else {
                LSPLog.warn(
                    "LSP override entry for \"\(rawKey)\" missing \"command\"")
                continue
            }
            let args: [String] = (entryObj["args"] as? [String]) ?? []
            let env: [String: String] =
                (entryObj["env"] as? [String: String]) ?? [:]
            let initOpts: Data?
            if let initObj = entryObj["initializationOptions"] {
                initOpts = try? JSONSerialization.data(
                    withJSONObject: initObj,
                    options: [.sortedKeys])
            } else {
                initOpts = nil
            }
            // First entry wins on duplicate language coverage (e.g.
            // a file specifying both "swift" and "sourcekitLSP" —
            // both map to .swift). Dictionary insertion order is
            // not guaranteed across JSON keys, but the duplicate
            // case is user-error and either entry is correct.
            if resolved[language] == nil {
                resolved[language] = ServerOverride(
                    command: command,
                    arguments: args,
                    environment: env,
                    initializationOptions: initOpts)
            }
        }
        guard !resolved.isEmpty else { return nil }
        return LSPWorkspaceOverrides(
            servers: resolved, sourceFile: sourceFile)
    }

    // MARK: - Language-key resolution

    /// Map a server JSON key to its `LSPLanguage`. Case-insensitive.
    /// Accepts both the §11 "camelCase server name" (`sourcekitLSP`,
    /// `typescriptLanguageServer`) and the more obvious language tag
    /// (`swift`, `typescript`). Unknown keys return nil.
    static func languageFor(key: String) -> LSPLanguage? {
        switch key.lowercased() {
        case "swift", "sourcekitlsp", "sourcekit-lsp":
            return .swift
        case "typescript", "typescriptlanguageserver",
             "typescript-language-server", "javascript":
            return .typescript
        case "python", "pyright", "pyright-langserver":
            return .python
        case "java", "jdtls":
            return .java
        default:
            return nil
        }
    }

    // MARK: - Env merge

    /// Merge override env atop the parent process env. Override keys
    /// win on conflict; parent keys not mentioned in the override are
    /// preserved. Used by the registry's launcher to translate an
    /// override into an `LSPClient.Config.environment` payload.
    ///
    /// Returns nil if the override's env is empty — signals "no env
    /// changes; let the LSPClient inherit the parent env normally"
    /// (avoids forcing a full env materialisation when the user only
    /// overrode the binary path).
    public func mergedEnvironment(
        for language: LSPLanguage,
        parent: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String]? {
        guard let override = servers[language],
              !override.environment.isEmpty else {
            return nil
        }
        var merged = parent
        for (k, v) in override.environment {
            merged[k] = v
        }
        return merged
    }
}

/// Minimal logging seam. The LSP layer does not currently use OSLog
/// (the dev-diagnostics panel is the canonical surface), so this
/// keeps overrides from pulling in a new dependency. Tests can read
/// `LSPLog.captured` to assert that warnings fired.
public enum LSPLog {
    nonisolated(unsafe) private static var _captured: [String] = []
    private static let lock = NSLock()

    public static func warn(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        _captured.append(message)
        // Surface to stderr for live-app debugging. Cheap; one line
        // per malformed config and override files are rare.
        FileHandle.standardError.write(
            Data("[LSP] WARN \(message)\n".utf8))
    }

    /// Snapshot of warnings captured this process. Test-only seam.
    public static func captured() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return _captured
    }

    /// Reset the capture log. Tests call this in `setUp`.
    public static func resetCaptured() {
        lock.lock(); defer { lock.unlock() }
        _captured.removeAll()
    }
}
