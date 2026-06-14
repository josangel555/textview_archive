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
        case invalidName(String) // baseName carried a path separator / traversal
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
        // Reject a base name that carries a path separator or `.`/`..`: a
        // `../x` or `a/b` base would let `appendingPathComponent` + `open`
        // create the file OUTSIDE `directory` (path traversal). The name must
        // be a single in-directory component.
        // Also reject an embedded NUL: `withCString` truncates at it, so
        // "foo\0.txt" would silently create "foo" — a confusing corruption.
        guard !baseName.isEmpty, !baseName.contains("/"), !baseName.contains("\0"),
              baseName != ".", baseName != ".." else {
            throw CreateError.invalidName(baseName)
        }
        let (stem, ext) = splitName(baseName)
        for n in 1...maxAttempts {
            let candidate = directory.appendingPathComponent(name(stem: stem, ext: ext, index: n))
            // O_EXCL: fail if it already exists — race-free "claim this name".
            // O_NOFOLLOW: if the (final) name is a pre-planted symlink, fail
            // rather than create at the link target. (The directory-component
            // symlink race is out of scope — this is a user creating a file in
            // their OWN folder, not a privileged path.)
            let fd = candidate.path.withCString {
                open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o644)
            }
            if fd >= 0 {
                close(fd)
                return candidate
            }
            // EEXIST: name taken. ELOOP: name is a symlink (O_NOFOLLOW). Either
            // way the candidate is occupied — skip to the next index.
            if errno == EEXIST || errno == ELOOP { continue }
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

/// The file types offered by the "New File ▸ …" submenus (TSK-747). Each
/// maps to a default `Untitled.<ext>` base name whose extension drives the
/// editor's language / category detection on open. Text-based types only —
/// a "blank image" needs format + dimension choices that belong in their own
/// dialog (deliberately deferred; not part of this slice). The created file
/// is empty (the user types into it), matching VS Code's "New File".
///
/// Pure data so the offered set + its name mapping is host-testable without a
/// window; the menu wiring that presents it is the VM-gated render layer.
public enum NewFileType: String, CaseIterable, Sendable {
    case text
    case markdown
    case csv
    case json

    /// Menu label.
    public var title: String {
        switch self {
        case .text: return "Text File"
        case .markdown: return "Markdown File"
        case .csv: return "CSV File"
        case .json: return "JSON File"
        }
    }

    /// Default non-colliding base name handed to `NewFileCreator.create`; the
    /// extension is what the open path uses to pick the language/category.
    public var baseName: String {
        switch self {
        case .text: return "Untitled.txt"
        case .markdown: return "Untitled.md"
        case .csv: return "Untitled.csv"
        case .json: return "Untitled.json"
        }
    }
}
