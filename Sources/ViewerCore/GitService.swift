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

    @discardableResult
    public func run(_ args: [String], in dir: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gitBinaryPath)
        process.arguments = args
        process.currentDirectoryURL = dir
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw GitError.commandFailed(
                exitCode: process.terminationStatus,
                stderr: errStr
            )
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func parseStatus(_ output: String) -> [GitStatusEntry] {
        var entries: [GitStatusEntry] = []
        for raw in output.split(separator: "\n", omittingEmptySubsequences: true) {
            // porcelain v1: "XY path" (X = index, Y = worktree). "?? path" for
            // untracked. Renamed: "R  old -> new" (we keep `new`).
            guard raw.count >= 3 else { continue }
            let chars = Array(raw)
            let x = chars[0]
            let y = chars[1]
            // Path begins after the single space at index 2 (porcelain v1).
            let pathRaw = String(chars.dropFirst(3))
            let path: String
            if let arrow = pathRaw.range(of: " -> ") {
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
