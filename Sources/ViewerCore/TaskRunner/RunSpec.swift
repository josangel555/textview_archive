import Foundation

/// The exact, ready-to-spawn invocation for a `RunnableTask` — the bridge
/// between pure discovery and the live process spawn (`PTYProcess`). PURE
/// builder: no spawn, no environment capture beyond what's passed in, fully
/// host-testable. Foundation slice for the task/command runner (TSK-722).
///
/// Two consumption shapes, because the codebase spawns through a shell:
///   • `shellCommandLine` — a single `/bin/sh -c`-safe string (each token
///     single-quoted). This is what a PTY-based runner pipes to the shell.
///   • `argv` — the tokenized form for a direct `posix_spawn`/`execvp` path
///     (no shell). Kept so a future non-shell spawn doesn't re-derive it.
public struct RunSpec: Equatable, Sendable {

    /// Tokenized argv (`task.command` + `task.arguments`), no shell involved.
    public let argv: [String]

    /// The same invocation as ONE shell-safe command line — every token
    /// single-quoted so spaces / metacharacters / quotes survive intact.
    public let shellCommandLine: String

    /// Absolute working directory the spawn should `chdir` into.
    public let workingDirectory: URL

    /// Environment overrides to MERGE over the inherited process environment at
    /// spawn time (e.g. `FORCE_COLOR=1`). Empty by default.
    public let environment: [String: String]

    public init(
        argv: [String],
        shellCommandLine: String,
        workingDirectory: URL,
        environment: [String: String]
    ) {
        self.argv = argv
        self.shellCommandLine = shellCommandLine
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    /// Build the run-spec for a task. `extraEnvironment` is merged over (and
    /// overrides) any per-source defaults; `extraArguments` are appended AFTER
    /// the task's own arguments (e.g. user-supplied `-- --watch`).
    public static func build(
        for task: RunnableTask,
        extraArguments: [String] = [],
        extraEnvironment: [String: String] = [:]
    ) -> RunSpec {
        let argv = task.argv + extraArguments
        let commandLine = argv.map(shellSingleQuoted).joined(separator: " ")
        return RunSpec(
            argv: argv,
            shellCommandLine: commandLine,
            workingDirectory: task.workingDirectory,
            environment: extraEnvironment
        )
    }

    /// Single-quote a token for safe embedding in `/bin/sh` — handles spaces,
    /// metacharacters, and embedded apostrophes (`'\''` splice). Matches the
    /// `CLILauncher.shellSingleQuoted` convention so quoting is consistent
    /// across the app.
    static func shellSingleQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
