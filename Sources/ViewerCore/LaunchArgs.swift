import Foundation

/// Parsed command-line launch arguments (TSK-926/927). Extracted from the
/// AppDelegate's inline argv loop so the parsing is host-testable — the actual
/// file/folder open + the `mdv` CLI shim (`scripts/install-mdv-cli.sh`, which
/// delegates to `open -a`, including `mdv -` for stdin → temp file → open) sit
/// on top of this.
///
/// Flags are parsed positionally for simplicity. `--auto-snapshot`, `--script`,
/// and `--walkthrough` consume the following token as their value; every other
/// `--`-prefixed token is ignored here (e.g. `--mcp-stdio` / `--claude-monitor`
/// are handled at the top level before the app delegate runs). Non-`--` tokens
/// are positional paths, opened in order.
public struct LaunchArgs: Equatable, Sendable {
    public var diagnose: Bool = false
    public var forceSource: Bool = false
    public var autoSnapshotDelay: Double = -1
    public var scriptPath: String? = nil
    public var walkthroughPath: String? = nil
    public var paths: [String] = []

    public init() {}

    /// Parse argv with argv[0] already dropped (i.e. `CommandLine.arguments.dropFirst()`).
    public static func parse(_ rawArgs: [String]) -> LaunchArgs {
        var out = LaunchArgs()
        out.diagnose = rawArgs.contains("--diagnose")
        out.forceSource = rawArgs.contains("--source")
        var skipNext = false
        for (i, a) in rawArgs.enumerated() {
            if skipNext { skipNext = false; continue }
            if a == "--auto-snapshot" {
                if i + 1 < rawArgs.count, let s = Double(rawArgs[i + 1]) {
                    out.autoSnapshotDelay = s
                    skipNext = true
                }
                continue
            }
            if a == "--script" {
                if i + 1 < rawArgs.count {
                    out.scriptPath = rawArgs[i + 1]
                    skipNext = true
                }
                continue
            }
            if a == "--walkthrough" {
                if i + 1 < rawArgs.count {
                    out.walkthroughPath = rawArgs[i + 1]
                    skipNext = true
                }
                continue
            }
            if a.hasPrefix("--") { continue }
            out.paths.append(a)
        }
        return out
    }
}
