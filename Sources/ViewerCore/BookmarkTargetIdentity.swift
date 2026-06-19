import Foundation

/// Filesystem identity of a bookmark target, captured at ADD time so we can
/// detect a TOCTOU swap at OPEN time (BACKLOG "TOCTOU on bookmark symlinks",
/// TSK-309).
///
/// A bookmark stores a *path*. A path is not a stable handle: between the
/// moment a user pins a directory and the moment they open it, an attacker
/// (or an ordinary `mv`/symlink-repoint) can re-point the path at a different
/// inode. Following the path blindly at open time would silently open the
/// SWAPPED target. We instead snapshot the resolved identity at add time and
/// re-`stat(2)` at open time, refusing to follow a target whose identity no
/// longer matches.
///
/// Identity is `(device, inode)` — the canonical POSIX "same file" tuple, the
/// same one `FileRenamer` uses for its collision guard. We deliberately do NOT
/// use `URL.fileResourceIdentifierKey`: that token is opaque and explicitly
/// *not* guaranteed stable across reboots or remounts, so it can't be
/// persisted to JSON and compared on a later launch. `(st_dev, st_ino)` is
/// stable for the life of the file on a given volume.
///
/// `stat(2)` (not `lstat`) is intentional: we want the identity of the
/// RESOLVED target the user actually pinned (following any symlink in the
/// path), because that resolved file is what `openPath` will read. A swap of
/// any symlink component changes the resolved inode and trips the mismatch.
public struct BookmarkTargetIdentity: Codable, Equatable, Hashable, Sendable {
    /// `st_dev` — the volume the target lives on.
    public let device: UInt64
    /// `st_ino` — the file number within that volume.
    public let inode: UInt64
    /// Whether the resolved target was a directory at capture time. A
    /// file→dir (or dir→file) swap is a mismatch even if `(dev, ino)` somehow
    /// collide, and it lets the caller surface a clearer signal.
    public let isDirectory: Bool
    /// `realpath(3)` of the target at capture time — the fully symlink-resolved
    /// absolute path. Recorded for diagnostics/UX ("target changed: was X") and
    /// as a secondary signal; identity comparison is driven by `(dev, ino)`.
    public let resolvedPath: String

    public init(device: UInt64, inode: UInt64, isDirectory: Bool, resolvedPath: String) {
        self.device = device
        self.inode = inode
        self.isDirectory = isDirectory
        self.resolvedPath = resolvedPath
    }

    /// Snapshot the identity of whatever `url` resolves to RIGHT NOW, or nil
    /// if the path doesn't exist / can't be stat'd. `stat(2)` follows symlinks
    /// so we capture the resolved target, matching what the app would open.
    public static func capture(at url: URL) -> BookmarkTargetIdentity? {
        statIdentity(url.path)
    }

    /// `stat(2)` wrapper returning `(dev, ino, isDir)` + the realpath, or nil
    /// when the path doesn't resolve. Pure over the filesystem.
    static func statIdentity(_ path: String) -> BookmarkTargetIdentity? {
        var st = Darwin.stat()
        // Bare `stat($0, &st)` resolves to the C function (the `stat` *type*
        // is referenced via `Darwin.stat()` above) — same convention as
        // `FileRenamer.lstatOf`.
        let rc = path.withCString { stat($0, &st) }
        guard rc == 0 else { return nil }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        let resolved = realpathOf(path) ?? path
        return BookmarkTargetIdentity(
            device: UInt64(st.st_dev),
            inode: UInt64(st.st_ino),
            isDirectory: isDir,
            resolvedPath: resolved
        )
    }

    /// `realpath(3)` wrapper: fully resolves symlinks + `.`/`..` to an
    /// absolute canonical path, or nil if the path can't be resolved.
    static func realpathOf(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Verdict of re-validating a bookmark target at open time against the
/// identity captured at add time.
public enum BookmarkValidation: Equatable, Sendable {
    /// Target still resolves to the same `(dev, ino)` (and dir-ness) that was
    /// recorded — safe to open.
    case ok
    /// The path no longer exists (deleted, or the symlink dangles).
    case missing
    /// The path now resolves to a DIFFERENT inode / device, or a file where a
    /// directory was recorded (or vice-versa) — a TOCTOU swap. Carries the
    /// recorded vs. current identity for diagnostics. Refuse to follow.
    case identityChanged(was: BookmarkTargetIdentity, now: BookmarkTargetIdentity)
    /// No identity was captured for this bookmark (a legacy entry persisted
    /// before identity tracking existed). We can't prove the target is the
    /// original, but we also won't block opening pre-existing bookmarks — the
    /// caller may treat this as "open, but unverified".
    case unverified

    /// Whether opening the target is considered safe by this verdict.
    /// `identityChanged` and `missing` are unsafe; `ok` and (lenient)
    /// `unverified` are safe.
    public var isSafeToOpen: Bool {
        switch self {
        case .ok, .unverified: return true
        case .missing, .identityChanged: return false
        }
    }

    /// Validate `url` against a previously-captured `identity`. Pure over the
    /// filesystem (one `stat(2)`). Returns `.unverified` when `identity` is nil
    /// so legacy bookmarks don't get spuriously refused.
    public static func validate(url: URL, against identity: BookmarkTargetIdentity?) -> BookmarkValidation {
        guard let recorded = identity else { return .unverified }
        guard let current = BookmarkTargetIdentity.capture(at: url) else {
            return .missing
        }
        if current.device == recorded.device,
           current.inode == recorded.inode,
           current.isDirectory == recorded.isDirectory {
            return .ok
        }
        return .identityChanged(was: recorded, now: current)
    }
}
