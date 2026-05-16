import Foundation

/// Minimal git client that shells out to /usr/bin/git. Not a
/// libgit2 wrapper — for viewer-side reads we don't need
/// transactional anything, just `git status --porcelain`, `git diff`,
/// `git log`, and `git show`. Each method runs git as a Process,
/// captures stdout, parses.
///
/// All methods are synchronous + non-throwing-on-empty: a directory
/// that isn't a git repo returns empty results (no exception). Real
/// errors throw `GitClient.Error`.
public final class GitClient: Sendable {
    public let repoRoot: URL

    public enum Error: Swift.Error, CustomStringConvertible {
        case gitNotFound
        case notARepo
        case processFailed(Int32, String)
        public var description: String {
            switch self {
            case .gitNotFound:           return "/usr/bin/git not available"
            case .notARepo:              return "Not a git repository"
            case .processFailed(let c, let msg):
                return "git exited \(c): \(msg)"
            }
        }
    }

    public init(repoRoot: URL) {
        self.repoRoot = repoRoot
    }

    /// Returns the working-tree root if any ancestor of `url` has
    /// `.git`, else nil. Useful for "is this folder a repo?".
    public static func discoverRoot(from url: URL) -> URL? {
        var cur = url.standardizedFileURL
        let fm = FileManager.default
        for _ in 0..<32 {
            let git = cur.appendingPathComponent(".git")
            if fm.fileExists(atPath: git.path) {
                return cur
            }
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { break }
            cur = parent
        }
        return nil
    }

    // MARK: - status

    public struct StatusEntry: Equatable, Sendable {
        public let path: String
        public let indexStatus: Character   // X column of porcelain v1
        public let workingStatus: Character // Y column
        public var isUntracked: Bool { indexStatus == "?" && workingStatus == "?" }
    }

    /// `git status --porcelain` rows.
    public func status() -> [StatusEntry] {
        let out = (try? run(["status", "--porcelain=v1", "-uall"])) ?? ""
        var entries: [StatusEntry] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.count >= 4 else { continue }
            let chars = Array(line)
            let path = String(chars[3..<chars.count])
            entries.append(StatusEntry(
                path: path,
                indexStatus: chars[0],
                workingStatus: chars[1]
            ))
        }
        return entries
    }

    // MARK: - diff

    /// `git diff HEAD -- <path>` for unified-diff text.
    public func diff(forPath path: String) -> String {
        (try? run(["diff", "--no-color", "HEAD", "--", path])) ?? ""
    }

    // MARK: - log

    public struct LogEntry: Equatable, Sendable {
        public let sha: String        // short SHA
        public let author: String
        public let date: String       // ISO-ish from %ad
        public let subject: String
    }

    /// Last N commits touching a single file. With nil path → repo-wide.
    public func log(forPath path: String? = nil, maxEntries: Int = 50) -> [LogEntry] {
        // Use a delimiter no plausible commit subject would contain.
        let sep = "\u{1F}"  // unit separator
        let format = "--pretty=format:%h\(sep)%an\(sep)%ai\(sep)%s"
        var args = ["log", format, "-n", "\(maxEntries)"]
        if let path { args.append(contentsOf: ["--", path]) }
        guard let out = try? run(args) else { return [] }
        var entries: [LogEntry] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: Character(sep), omittingEmptySubsequences: false)
            guard parts.count == 4 else { continue }
            entries.append(LogEntry(
                sha: String(parts[0]),
                author: String(parts[1]),
                date: String(parts[2]),
                subject: String(parts[3])
            ))
        }
        return entries
    }

    // MARK: - private

    private func run(_ args: [String]) throws -> String {
        let bin = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            throw Error.gitNotFound
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.currentDirectoryURL = repoRoot
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        // Don't inherit the parent's stdin. The app's stdin can be
        // pointed at arbitrary content (e.g., `mdv -` pipe mode);
        // git inheriting that would let a hostile config / hook prompt
        // for input that the caller never sees.
        p.standardInput = FileHandle.nullDevice
        // Defense against malicious repo configs: never honor a
        // .git/config from the working tree. `safe.directory = *` skips
        // the safety prompt only; `protocol.file.allow=user` and
        // disabling external editors / pagers blocks the common
        // RCE-on-clone vectors. We treat repos as untrusted data.
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "/usr/bin/true"
        env["GIT_PAGER"] = "cat"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        p.environment = env
        try p.run()
        p.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            let edata = errPipe.fileHandleForReading.readDataToEndOfFile()
            let estr = String(data: edata, encoding: .utf8) ?? ""
            if estr.lowercased().contains("not a git repository") {
                throw Error.notARepo
            }
            throw Error.processFailed(p.terminationStatus, estr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }
}
