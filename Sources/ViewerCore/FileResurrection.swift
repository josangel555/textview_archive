import Foundation

/// TSK-1500 — resurrect a DELETED file from Local History. The normal
/// restore path (`restoreLocalHistoryVersion`) deliberately fails fast when
/// the file no longer exists on disk (its write-free open-then-apply design
/// cannot create files) — but Local History RETAINS versions for deleted
/// paths, so "bring back the file I deleted" is a legitimate recovery the
/// timeline already has the bytes for. This is that missing primitive, built
/// to the data-safety rules:
///
///   * ATOMIC CREATE, NEVER OVERWRITE — `open(2)` with `O_CREAT|O_EXCL`. If
///     anything re-appeared at the path (a race: the user re-created it, a
///     sync tool restored it), we REFUSE and the caller re-routes to the
///     normal buffer-restore instead — the existing file's content is never
///     touched.
///   * WORKSPACE-FENCED — recreation is refused outside `workspaceRoot`
///     (standardized-path prefix check), so a stale history entry can never
///     write outside the tree the user is working in.
///   * PARENT RECREATION — a deleted file often went down with its folder;
///     intermediate directories are recreated (directories are inert — the
///     O_EXCL guard is what protects data).
public enum FileResurrection {

    /// The outcome, Equatable so host tests pin the exact branch.
    public enum Outcome: Equatable, Sendable {
        /// The file was recreated with the version's content.
        case created
        /// Something exists at the path (re-created/raced) — refused; the
        /// caller should offer the NORMAL restore against the live file.
        case refusedExists
        /// The path is outside the workspace root — refused.
        case refusedOutsideWorkspace
        /// An IO failure (open/write) with the errno-derived description.
        case failed(String)
    }

    /// Recreate `path` with `content` under the rules above.
    public static func recreate(
        content: String, atPath path: String, workspaceRoot: String
    ) -> Outcome {
        // Workspace fence: standardized absolute paths, prefix-with-separator
        // so "/ws-evil" can't pass as inside "/ws".
        let root = URL(fileURLWithPath: workspaceRoot).standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        guard target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            return .refusedOutsideWorkspace
        }
        guard target != root else { return .refusedExists } // the root itself is a dir

        // Recreate intermediate directories (inert; O_EXCL guards the file).
        let parent = URL(fileURLWithPath: target).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true)
        } catch {
            return .failed("create parent: \(error.localizedDescription)")
        }

        // O_CREAT|O_EXCL: fails with EEXIST if ANYTHING is at the path —
        // the atomic never-overwrite guarantee (no TOCTOU window).
        let fd = Darwin.open(target, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        if fd < 0 {
            if errno == EEXIST { return .refusedExists }
            return .failed(String(cString: strerror(errno)))
        }
        defer { Darwin.close(fd) }
        let bytes = Array(content.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(fd, base + off, bytes.count - off)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return .failed(String(cString: strerror(errno)))
            }
            if n == 0 { return .failed("short write") }
            off += n
        }
        return .created
    }
}
