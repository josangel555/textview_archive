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
///     // key may also be "javascript" — maps to the same TS server
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
///   - `typescript` / `typescriptlanguageserver` / `javascript`
///     (JS overrides the same TS server entry)
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
///   - `initializationOptions` from §11 is parsed here and forwarded:
///     `overrideConfig` threads it into `LSPClient.Config`, and
///     `LSPClient.makeInitializeParams` injects it (verbatim, when
///     well-formed) into the `initialize` request (TSK-465).
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

    // MARK: - Dangerous env-var denylist (TSK-980 / M5)

    /// Environment-variable names that turn an *otherwise-trusted* binary
    /// into a code-execution vector by injecting attacker-controlled code
    /// at process start. `lsp.json` lives **inside the workspace**, so a
    /// hostile repo can name a perfectly-trusted SYSTEM server binary
    /// (e.g. `/opt/homebrew/bin/typescript-language-server` — passes the
    /// command trust gate) yet ship an `env` block that loads code from
    /// the repo: `NODE_OPTIONS=--require ./.evil/pwn.js`,
    /// `DYLD_INSERT_LIBRARIES=./.evil/lib.dylib`, `PYTHONSTARTUP=...`, etc.
    /// The command trust gate (SEC-001) only vets *which binary* is
    /// spawned — it cannot see these. They are name-based and so MUST be
    /// stripped from any repo-supplied `env` before it reaches the child
    /// (M5: "untrusted repo args/env reach the trusted discovered server").
    ///
    /// This is a DENYLIST of the canonical loader/interpreter hooks across
    /// the runtimes our servers use (node, python, ruby, java, perl) plus
    /// the dynamic-linker injection vars (`DYLD_*` on macOS, `LD_*` for
    /// any Linux-built tools a user wires in). It is intentionally
    /// conservative — these vars are NEVER legitimately set per-repo to
    /// configure a language server (the server's own `args` /
    /// `initializationOptions` are the supported tuning surface). A user
    /// who genuinely needs one can set it in their *shell* (it then flows
    /// through the discovered-binary path under their own trust), not via
    /// a repo-checked-in `lsp.json`.
    ///
    /// Matching is by exact uppercased name OR by the `DYLD_` / `LD_`
    /// prefix (those families have many members — `DYLD_FRAMEWORK_PATH`,
    /// `DYLD_LIBRARY_PATH`, `LD_PRELOAD`, `LD_LIBRARY_PATH`, …).
    public static let dangerousEnvNames: Set<String> = [
        // Node.js: `--require`/`--import` arbitrary modules at startup.
        "NODE_OPTIONS",
        // Python: import path + startup-script + site hooks.
        "PYTHONPATH", "PYTHONSTARTUP", "PYTHONHOME",
        "PYTHONEXECUTABLE", "PYTHONUSERBASE",
        // Ruby: `-r` arbitrary libs at startup.
        "RUBYOPT", "RUBYLIB",
        // Perl: include path + `-M` modules.
        "PERL5LIB", "PERL5OPT", "PERLLIB",
        // JVM: `-javaagent`, classpath injection, tool options.
        "JAVA_TOOL_OPTIONS", "_JAVA_OPTIONS", "JDK_JAVA_OPTIONS",
        "CLASSPATH",
        // Generic loader / linker (also covered by prefix match below,
        // listed for clarity).
        "DYLD_INSERT_LIBRARIES", "LD_PRELOAD",
    ]

    /// True iff `name` is a code-injection env var that must never be
    /// honoured from a repo-supplied `lsp.json`. Case-insensitive on the
    /// exact set; prefix-matches the `DYLD_` and `LD_` linker families.
    public static func isDangerousEnvName(_ name: String) -> Bool {
        let upper = name.uppercased()
        if dangerousEnvNames.contains(upper) { return true }
        // The dynamic-linker families have many members; block the whole
        // namespace rather than enumerate every variant.
        if upper.hasPrefix("DYLD_") || upper.hasPrefix("LD_") {
            return true
        }
        return false
    }

    /// Strip every code-injection env var (see `isDangerousEnvName`) from
    /// `env`, emitting one `LSPLog.warn` per dropped key so a refused
    /// `lsp.json` env is visible in diagnostics. Used to sanitize a
    /// repo-supplied override `env` before it is layered onto the trusted
    /// child environment.
    public static func sanitizedOverrideEnv(
        _ env: [String: String],
        sourceFile: URL? = nil
    ) -> [String: String] {
        var safe: [String: String] = [:]
        for (k, v) in env {
            if isDangerousEnvName(k) {
                let where_ = sourceFile.map { " (\($0.path))" } ?? ""
                LSPLog.warn(
                    "LSP override env var refused (code-injection vector): "
                    + "\(k)\(where_)")
                continue
            }
            safe[k] = v
        }
        return safe
    }

    // MARK: - Env merge

    /// Merge override env atop the parent process env. Override keys
    /// win on conflict; parent keys not mentioned in the override are
    /// preserved. Used by the registry's launcher to translate an
    /// override into an `LSPClient.Config.environment` payload.
    ///
    /// TSK-980 / M5: the override's own keys are first run through
    /// `sanitizedOverrideEnv`, so a repo-supplied `NODE_OPTIONS` /
    /// `DYLD_*` / `PYTHONSTARTUP` / … can NEVER be layered onto a trusted
    /// server's environment. The command trust gate (SEC-001) vets only
    /// *which binary* is spawned; these name-based code-injection vectors
    /// are orthogonal and must be stripped here regardless of how the
    /// command was vetted.
    ///
    /// Returns nil if the override's (sanitized) env is empty — signals
    /// "no env changes; let the LSPClient inherit the parent env normally"
    /// (avoids forcing a full env materialisation when the user only
    /// overrode the binary path, or every override key was denylisted).
    public func mergedEnvironment(
        for language: LSPLanguage,
        parent: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String]? {
        guard let override = servers[language],
              !override.environment.isEmpty else {
            return nil
        }
        let safeOverride = Self.sanitizedOverrideEnv(
            override.environment, sourceFile: sourceFile)
        guard !safeOverride.isEmpty else {
            // Every override key was a denylisted injection vector → no
            // net env change.
            return nil
        }
        var merged = parent
        for (k, v) in safeOverride {
            merged[k] = v
        }
        return merged
    }
}

/// Minimal logging seam for the LSP override layer. Warnings now flow
/// through the process-wide `Obs.shared` observability sink (subsystem
/// `"lsp"`), which ring-buffers them and optionally fans out to
/// `os_log` — but the legacy behaviour is preserved: each warning is
/// still written to stderr (cheap; override files are rare), and the
/// `captured()`/`resetCaptured()` test seam still works.
///
/// `captured()` reads from an in-process mirror buffer maintained here
/// rather than from `Obs.shared`, so tests that assert on LSP warnings
/// don't have to install or introspect a `RingBufferSink`. The mirror
/// is deliberately tiny and bounded to avoid the unbounded-growth /
/// content-leak surface the design flags for any message buffer.
public enum LSPLog {
    nonisolated(unsafe) private static var _captured: [String] = []
    private static let lock = NSLock()

    /// Bound on the test-mirror buffer. Override files are parsed rarely;
    /// a real session emits a handful of warnings, but a pathological
    /// loop must not grow this without limit. Drop-oldest on overflow.
    private static let captureCap = 1_000

    public static func warn(_ message: String) {
        // Route to the unified sink (ring buffer + optional os_log).
        Obs.shared.emit(.warn, "lsp", message)

        lock.lock()
        _captured.append(message)
        if _captured.count > captureCap {
            _captured.removeFirst(_captured.count - captureCap)
        }
        lock.unlock()

        // Surface to stderr for live-app debugging. Cheap; one line
        // per malformed config and override files are rare. Preserved
        // verbatim so existing `[LSP] WARN ...` grep habits keep working.
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
