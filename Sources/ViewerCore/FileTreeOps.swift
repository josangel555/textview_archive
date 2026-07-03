import Foundation
import Darwin

// TSK-1463 — pure, headless-testable disk primitives for the file-tree
// operations (New Folder / Move), plus the URL-rebase used to retarget open
// tabs after a rename or move. Siblings of `FileRenamer` / `NewFileCreator`
// and copies of their guard discipline: never clobber, reject path-traversal
// names, race-free claims via the syscall's own exclusivity.

/// Create a new, non-colliding folder ("untitled folder", "untitled folder 2",
/// …) in a directory. `mkdir(2)` itself is the race-free claim — `EEXIST`
/// advances to the next candidate, so two concurrent creates can't share a
/// name and nothing existing is ever touched.
public enum FolderCreator {

    public enum CreateError: Error, Equatable {
        case notADirectory(String)
        /// Base name is empty, contains `/` or NUL, or is `.`/`..`.
        case invalidName(String)
        /// All numbered candidates were taken (pathological).
        case exhausted
        case failed(String)
    }

    @discardableResult
    public static func create(
        in directory: URL,
        baseName: String = "untitled folder",
        maxAttempts: Int = 10_000
    ) throws -> URL {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw CreateError.notADirectory(directory.path)
        }
        // Same traversal guards as NewFileCreator: the name must be a single
        // in-directory component (no `/`, no `..`, no embedded NUL).
        guard !baseName.isEmpty, !baseName.contains("/"), !baseName.contains("\0"),
              baseName != ".", baseName != ".." else {
            throw CreateError.invalidName(baseName)
        }
        for n in 1...maxAttempts {
            let name = n == 1 ? baseName : "\(baseName) \(n)"
            let candidate = directory.appendingPathComponent(name, isDirectory: true)
            let rc = candidate.path.withCString { mkdir($0, 0o755) }
            if rc == 0 { return candidate }
            if errno == EEXIST { continue }   // taken → next number
            throw CreateError.failed(String(cString: strerror(errno)))
        }
        throw CreateError.exhausted
    }
}

/// Move a file or folder into another directory, keeping its name.
/// **Never clobbers:** an occupant at the destination name fails the move
/// (`lstat` pre-check plus `FileManager.moveItem`, which itself refuses to
/// overwrite — belt and suspenders). Cross-volume moves work (`moveItem`
/// falls back to copy+delete where `rename(2)` would EXDEV).
public enum FileMover {

    public enum MoveError: Error, Equatable {
        case sourceMissing(String)
        case destinationNotADirectory(String)
        /// Destination directory == source's parent — nothing to do.
        case sameLocation
        /// Can't move a folder into itself or its own descendant.
        case intoItself
        /// A different item already occupies the destination name.
        case targetExists(String)
        case failed(String)
    }

    /// Move `url` into `directory` (keeping `url.lastPathComponent`).
    /// Returns the new URL.
    @discardableResult
    public static func move(_ url: URL, into directory: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MoveError.sourceMissing(url.path)
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw MoveError.destinationNotADirectory(directory.path)
        }
        let src = url.standardizedFileURL
        let destDir = directory.standardizedFileURL
        guard destDir.path != src.deletingLastPathComponent().path else {
            throw MoveError.sameLocation
        }
        // A folder must not move into itself/descendant (rename(2) would
        // EINVAL, moveItem's copy fallback could recurse) — reject up front.
        if destDir.path == src.path
            || destDir.path.hasPrefix(src.path + "/") {
            throw MoveError.intoItself
        }
        let dest = destDir.appendingPathComponent(src.lastPathComponent)
        var st = stat()
        if dest.path.withCString({ lstat($0, &st) }) == 0 {
            throw MoveError.targetExists(dest.path)
        }
        do {
            try FileManager.default.moveItem(at: src, to: dest)
        } catch {
            throw MoveError.failed(String(describing: error))
        }
        return dest
    }
}

/// URL rebasing after a rename/move: where does `url` point once `oldURL`
/// became `newURL`? Exact match → `newURL`; a descendant of a renamed FOLDER
/// → the same relative path under `newURL`; anything else → nil (unaffected).
/// Pure — this is the seam open tabs / bookmarks retarget through.
public enum PathRebase {

    public static func rebased(_ url: URL, from oldURL: URL, to newURL: URL) -> URL? {
        let path = url.standardizedFileURL.path
        let old = oldURL.standardizedFileURL.path
        if path == old { return newURL.standardizedFileURL }
        let prefix = old.hasSuffix("/") ? old : old + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let relative = String(path.dropFirst(prefix.count))
        return newURL.standardizedFileURL.appendingPathComponent(relative)
    }
}
