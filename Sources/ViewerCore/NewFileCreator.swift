import Foundation
import Darwin

/// Pure, headless-testable creation of a new file on disk for the "File ▸ New"
/// / right-click-folder ▸ New File feature (owner ask 2026-06-04). The UI
/// (menu item + sidebar context menu + the in-place rename) calls this; this
/// type owns only the disk side so it's testable without a window.
///
/// **Never clobbers.** Uses `open(2)` with `O_CREAT | O_EXCL` — an atomic
/// create-if-absent — and walks a collision-safe name sequence
/// (`Untitled.txt`, `Untitled 2.txt`, `Untitled 3.txt`, …) until one wins.
/// That closes the TOCTOU window a `fileExists`-then-`createFile` check leaves
/// open, so two near-simultaneous "New File" calls can't stomp each other or
/// an existing file's contents.
public enum NewFileCreator {

    public enum CreateError: Error, Equatable {
        case notADirectory(String)
        case exhausted          // couldn't find a free name within the cap
        case writeFailed(String)
    }

    /// Create an empty file in `directory`, deriving a non-colliding name from
    /// `baseName` (default `Untitled.txt`). Returns the created file's URL.
    ///
    /// - The numbering is inserted before the extension: `notes.md` →
    ///   `notes 2.md`; an extension-less base (`README`) → `README 2`.
    /// - `directory` must exist and be a directory.
    @discardableResult
    public static func create(
        in directory: URL,
        baseName: String = "Untitled.txt",
        maxAttempts: Int = 10_000
    ) throws -> URL {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw CreateError.notADirectory(directory.path)
        }
        let (stem, ext) = splitName(baseName)
        for n in 1...maxAttempts {
            let candidate = directory.appendingPathComponent(name(stem: stem, ext: ext, index: n))
            // O_EXCL: fail if it already exists — race-free "claim this name".
            let fd = candidate.path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, 0o644) }
            if fd >= 0 {
                close(fd)
                return candidate
            }
            if errno == EEXIST { continue }        // taken — try the next index
            throw CreateError.writeFailed(String(cString: strerror(errno)))
        }
        throw CreateError.exhausted
    }

    /// The candidate filename for the n-th attempt. n==1 is the bare base
    /// (`Untitled.txt`); n>1 inserts ` n` before the extension.
    static func name(stem: String, ext: String, index n: Int) -> String {
        let suffix = n == 1 ? "" : " \(n)"
        return ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
    }

    /// Split a filename into (stem, extension-without-dot). A leading-dot
    /// dotfile (`.gitignore`) is treated as an all-stem name (no extension),
    /// matching Foundation's `pathExtension`.
    static func splitName(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return (name, "")
        }
        return (String(name[name.startIndex..<dot]),
                String(name[name.index(after: dot)...]))
    }
}
