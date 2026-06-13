import Foundation
import Darwin

/// Pure, headless-testable rename of a file or folder on disk for the
/// "rename from the file nav" feature (owner ask "Enter to rename",
/// TSK-283). The UI (sidebar context menu + the F2 key) calls this; this
/// type owns only the disk side so it's testable without a window.
///
/// **Never clobbers.** A rename whose target name is already taken by a
/// *different* file throws `targetExists` rather than overwriting it —
/// POSIX `rename(2)` would silently replace the destination, so we guard
/// it with an inode pre-check. A *case-only* rename on a case-insensitive
/// filesystem (`Foo.txt` → `foo.txt`, where the destination resolves to
/// the SAME inode as the source) is allowed through — that's a legitimate
/// rename, not a collision.
public enum FileRenamer {

    public enum RenameError: Error, Equatable {
        case sourceMissing(String)
        /// New name is empty, contains a path separator / NUL, or is `.`/`..`.
        case invalidName(String)
        /// New name equals the existing name — nothing to do.
        case unchanged
        /// A different file already occupies the target name (no overwrite).
        case targetExists(String)
        case failed(String)
    }

    /// Rename the item at `url` to `newName` (a single in-directory
    /// component) within the SAME parent directory. Returns the new URL.
    ///
    /// - `newName` must be one in-directory component — a `/` or `..` is
    ///   rejected so a rename can't move the item out of its folder
    ///   (path traversal).
    /// - Works for files AND directories (`rename(2)` handles both).
    @discardableResult
    public static func rename(at url: URL, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject a name that carries a path separator or `.`/`..`: an `a/b`
        // or `../x` name would let `appendingPathComponent` + `rename` move
        // the item OUTSIDE its directory. The name must be a single
        // in-directory component. Reject an embedded NUL too: `withCString`
        // truncates at it, so "foo\0" would silently rename to "foo".
        guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains("\0"),
              trimmed != ".", trimmed != ".." else {
            throw RenameError.invalidName(newName)
        }
        guard let srcStat = lstatOf(url.path) else {
            throw RenameError.sourceMissing(url.path)
        }
        let dest = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        // Identical name → nothing to rename. (Compared by the raw component
        // so a case-only change like `foo`→`Foo` is NOT treated as a no-op.)
        guard trimmed != url.lastPathComponent else {
            throw RenameError.unchanged
        }
        // Collision guard: a destination that exists AND is a DIFFERENT file
        // (inode) must not be overwritten. `lstat` (not `stat`) so a symlink
        // sitting at the target name counts as an occupant rather than being
        // followed to whatever it points at. A case-only rename resolves the
        // destination to the source's own inode — allowed through.
        if let destStat = lstatOf(dest.path),
           !(destStat.st_dev == srcStat.st_dev && destStat.st_ino == srcStat.st_ino) {
            throw RenameError.targetExists(dest.path)
        }
        let rc = url.path.withCString { s in
            dest.path.withCString { d in Darwin.rename(s, d) }
        }
        guard rc == 0 else {
            throw RenameError.failed(String(cString: strerror(errno)))
        }
        return dest
    }

    /// `lstat(2)` wrapper: returns the stat for `path` without following a
    /// final symlink, or nil if the path doesn't exist.
    private static func lstatOf(_ path: String) -> stat? {
        var st = stat()
        let rc = path.withCString { lstat($0, &st) }
        return rc == 0 ? st : nil
    }
}
