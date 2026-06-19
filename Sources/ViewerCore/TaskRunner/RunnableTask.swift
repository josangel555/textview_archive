import Foundation

/// A normalized, runnable command discovered from a project's manifests
/// (npm `package.json` scripts, `Cargo.toml` bins/test, `Makefile` targets,
/// common ad-hoc test commands). PURE data — discovery (`RunnableTaskDiscovery`)
/// and the run-spec builder (`RunSpec`) are host-testable; the actual spawn into
/// a PTY output panel (`PTYProcess`) is the live/VM tail and is NOT modelled here.
///
/// Foundation slice for the task/command runner (TSK-722).
public struct RunnableTask: Equatable, Hashable, Sendable, Identifiable {

    /// Where this task was discovered. Drives the icon/grouping in the (future)
    /// picker UI and the run-spec's invocation strategy (e.g. `npm run <name>`
    /// vs `cargo test` vs `make <target>`).
    public enum Source: String, Equatable, Hashable, Sendable, CaseIterable {
        case packageJson         // package.json "scripts" entry
        case cargo               // Cargo.toml [[bin]] / `cargo test`
        case makefile            // Makefile target
        case commonTestCommand   // heuristic fallback (e.g. a bare `pytest`)
    }

    /// Stable identity within a discovery pass: `"<source>:<name>"`. Two tasks
    /// with the same source+name from different manifests would collide, which
    /// is the correct dedupe key (the same logical task).
    public var id: String { "\(source.rawValue):\(name)" }

    /// Human-facing label shown in the picker (e.g. `"test"`, `"build"`,
    /// `"app (bin)"`, `"check"`). NOT necessarily the literal subcommand.
    public let name: String

    /// The driver program the task runs through (NOT shell-resolved here):
    /// `"npm"`, `"cargo"`, `"make"`, or a bare command like `"pytest"`. The
    /// run-spec builder combines this with `arguments`.
    public let command: String

    /// Arguments handed to `command` (already tokenized — no shell splitting).
    /// E.g. `["run", "test"]` for an npm script, `["test"]` for cargo,
    /// `["build"]` for a make target.
    public let arguments: [String]

    /// Working directory the task should run in (the manifest's directory).
    public let workingDirectory: URL

    public let source: Source

    public init(
        name: String,
        command: String,
        arguments: [String],
        workingDirectory: URL,
        source: Source
    ) {
        self.name = name
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.source = source
    }

    /// The fully-tokenized argv the task represents (`command` prepended to
    /// `arguments`) — what a direct `execvp`-style spawn would use, no shell.
    public var argv: [String] { [command] + arguments }
}
