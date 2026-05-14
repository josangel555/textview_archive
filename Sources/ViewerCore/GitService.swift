import Foundation

public struct GitStatusEntry: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable {
        case modified   = "M"
        case added      = "A"
        case deleted    = "D"
        case renamed    = "R"
        case copied     = "C"
        case untracked  = "?"
        case ignored    = "!"
        case conflicted = "U"
    }

    public let path: String   // relative to repo root
    public let status: Status

    public init(path: String, status: Status) {
        self.path = path
        self.status = status
    }
}

public enum GitError: Error, Equatable {
    case notARepo
    case commandFailed(exitCode: Int32, stderr: String)
}

/// Mutable Data box used by `GitService.run` to collect stdout/stderr from
/// background dispatch closures. `@unchecked Sendable` because access is
/// scoped: one closure writes, one read happens after the DispatchGroup
/// completes, no concurrent access.
private final class _DataBox: @unchecked Sendable {
    var data = Data()
}

/// Thin wrapper around `/usr/bin/git`. Pure I/O — no SwiftGit2 / libgit2.
public struct GitService: Sendable {
    public let gitBinaryPath: String

    public init(gitBinaryPath: String = "/usr/bin/git") {
        self.gitBinaryPath = gitBinaryPath
    }

    public func isGitRepo(at url: URL) -> Bool {
        let dotGit = url.appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: dotGit.path)
    }

    /// Walks up from `url` looking for a directory with a `.git` entry.
    public func repoRoot(for url: URL) -> URL? {
        var cur = url.standardizedFileURL.resolvingSymlinksInPath()
        while cur.path != "/" {
            if isGitRepo(at: cur) { return cur }
            let parent = cur.deletingLastPathComponent()
            if parent == cur { break }
            cur = parent
        }
        return nil
    }

    public func status(at repoRoot: URL) throws -> [GitStatusEntry] {
        let output = try run(["status", "--porcelain=v1"], in: repoRoot)
        return Self.parseStatus(output)
    }

    // MARK: - Private

    /// Protective `-c` flags prepended to every `git` invocation (CRIT-2).
    /// These disable common config-driven RCE vectors that fire on plain
    /// `git status` against an untrusted repo:
    /// - hooks (`pre-commit`, `post-checkout`, etc.) — disabled via /dev/null
    /// - the fsmonitor daemon — `core.fsmonitor` could spawn a binary
    /// - `core.editor` — opened on certain failures
    /// - `core.pager` — opened on certain output paths
    /// - file:// remote protocols (RCE-history in clones)
    /// We also disable C-style path quoting so paths with non-ASCII /
    /// embedded special characters round-trip as plain UTF-8 (B7).
    private static let protectiveFlags: [String] = [
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.fsmonitor=false",
        "-c", "core.editor=true",
        "-c", "core.pager=cat",
        "-c", "protocol.file.allow=user",
        "-c", "core.quotePath=false",
    ]

    /// Minimal environment for `git`. We don't trust the parent process's
    /// `GIT_*` vars (would let a user shell config or earlier code path
    /// silently change `git`'s behavior).
    private static let safeEnvironment: [String: String] = [
        "PATH": "/usr/bin:/bin",
        "HOME": NSHomeDirectory(),  // git needs HOME for global config lookups
        "LANG": "C",                // stable, locale-independent error messages
    ]

    @discardableResult
    public func run(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitBinaryPath)
        process.arguments = Self.protectiveFlags + args
        process.currentDirectoryURL = dir
        process.environment = Self.safeEnvironment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // CRIT-3: drain stdout & stderr **concurrently**. Reading them in
        // sequence after `waitUntilExit()` deadlocks when git writes more
        // than the ~64 KB pipe buffer to stderr (noisy repos with many
        // warnings on a `git status`) — the child blocks on write(2),
        // the parent blocks on wait(2).
        let stdoutBox = _DataBox()
        let stderrBox = _DataBox()
        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        group.enter()
        queue.async {
            stdoutBox.data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        queue.async {
            stderrBox.data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.wait()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errStr = String(data: stderrBox.data, encoding: .utf8) ?? ""
            throw GitError.commandFailed(
                exitCode: process.terminationStatus,
                stderr: errStr
            )
        }
        return String(data: stdoutBox.data, encoding: .utf8) ?? ""
    }

    static func parseStatus(_ output: String) -> [GitStatusEntry] {
        var entries: [GitStatusEntry] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            // porcelain v1: "XY path" (X = index, Y = worktree). "?? path"
            // for untracked. Renames/copies produce "XY old -> new" — but
            // **only** when X or Y is R/C. Plain M/A/D files can legally
            // contain the literal substring " -> " in their names, so we
            // must gate the split on the status (B6).
            guard raw.count >= 3 else { continue }
            let chars = Array(raw)
            let x = chars[0]
            let y = chars[1]
            let pathRaw = String(chars.dropFirst(3))
            let isRenameOrCopy = (x == "R" || x == "C" || y == "R" || y == "C")
            let path: String
            if isRenameOrCopy, let arrow = pathRaw.range(of: " -> ") {
                path = String(pathRaw[arrow.upperBound...])
            } else {
                path = pathRaw
            }
            let trimmed = path.trimmingCharacters(in: .whitespaces)
            guard let status = mapStatus(x: x, y: y) else { continue }
            entries.append(GitStatusEntry(path: trimmed, status: status))
        }
        return entries
    }

    private static func mapStatus(x: Character, y: Character) -> GitStatusEntry.Status? {
        if x == "?" && y == "?" { return .untracked }
        if x == "!" && y == "!" { return .ignored }
        if x == "U" || y == "U" || x == "A" && y == "A" || x == "D" && y == "D" {
            return .conflicted
        }
        // Priority: worktree state, then index state.
        for ch in [y, x] {
            switch ch {
            case "M": return .modified
            case "A": return .added
            case "D": return .deleted
            case "R": return .renamed
            case "C": return .copied
            default: break
            }
        }
        return nil
    }
}
