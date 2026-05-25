import Foundation

/// Thin wrapper around the system `jq` binary at `/usr/bin/jq`
/// (shipped with macOS as of 15.x; fallback path is the Homebrew
/// install at `/opt/homebrew/bin/jq`).
///
/// Used by the JSON viewer to apply a user-typed filter expression
/// to the current document. All work happens out-of-process so a
/// malformed or long-running filter can be cancelled cheaply by
/// killing the child.
public enum JQRunner {

    public enum Error: Swift.Error, CustomStringConvertible {
        /// `jq` binary not on disk at either of the probed paths.
        case notInstalled
        /// `jq` exited non-zero — stderr returned for the caller to
        /// display inline (typically "jq: error (at <stdin>:1): …").
        case filterError(exitCode: Int32, stderr: String)

        public var description: String {
            switch self {
            case .notInstalled:
                return "jq is not installed at /usr/bin/jq or /opt/homebrew/bin/jq"
            case .filterError(let code, let err):
                return "jq exited \(code): \(err)"
            }
        }
    }

    /// Resolved path to the `jq` binary on this machine, or nil if
    /// it's not installed in either of the canonical locations.
    /// Cached on first call (cheap; FileManager check).
    public static var binaryPath: String? {
        let probes = ["/usr/bin/jq", "/opt/homebrew/bin/jq"]
        return probes.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// True iff `binaryPath` resolves.
    public static var isAvailable: Bool { binaryPath != nil }

    /// Run `filter` over `json`, returning the resulting text.
    /// Throws on missing binary or filter errors. The output is the
    /// raw stdout from `jq` — typically pretty-printed JSON (with
    /// trailing newline). Caller may strip the newline.
    ///
    /// `timeoutSeconds` defaults to 10s; a runaway filter will be
    /// terminated and `filterError` thrown.
    public static func run(
        filter: String,
        json: String,
        timeoutSeconds: Double = 10
    ) throws -> String {
        guard let bin = binaryPath else { throw Error.notInstalled }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        // -e exits non-zero when the filter produces null/false (useful
        // for confirming "no match"). But that's user-hostile for a
        // viewer — drop -e so empty matches return "" cleanly.
        // --tab is too aggressive for a viewer; default 2-space indent.
        p.arguments = [filter]
        // Minimal env: no GIT_* or LANG quirks needed for jq.
        p.environment = [
            "PATH": "/usr/bin:/bin",
            "LANG": "C",
        ]
        // Drain stdout/stderr concurrently + write stdin off-thread +
        // enforce a wall-clock timeout via the shared `ProcessRunner`
        // (H, 2026-05-25). Same pipe-buffer-deadlock lesson as
        // `GitClient`.
        let result = try ProcessRunner.run(
            p,
            stdin: Data(json.utf8),
            timeout: timeoutSeconds
        )
        if result.terminationStatus != 0 {
            let err = String(data: result.stderr, encoding: .utf8) ?? ""
            throw Error.filterError(
                exitCode: result.terminationStatus,
                stderr: err.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return String(data: result.stdout, encoding: .utf8) ?? ""
    }
}
