import Foundation
import Darwin

/// In-memory editable text buffer backing a tab in `.editor` view
/// mode. PoC scope: plain UTF-8 strings, no undo history beyond what
/// `NSTextView` provides natively, no syntax highlighting.
///
/// Lifecycle:
///   1. Constructed from disk by `EditorBuffer.load(url:)` (or from a
///      pre-loaded `TextFile` via `init(url:original:encoding:)`).
///   2. The view binds to `text`; every keystroke flips `isDirty` once
///      the buffer diverges from `originalText`.
///   3. `save()` writes `text` back to `url`, then calls
///      `markSaved(diskMTime:diskSize:)` to clear dirt + capture the
///      new disk fingerprint.
///   4. An external write detected by `FileWatcher` compares its post-
///      write `(mtime, size)` against `lastSavedMTime / lastSavedSize`
///      via `hasExternalEdit(currentMTime:size:)`; mismatch + dirty
///      buffer = conflict, which the UI surfaces as a prompt.
///
/// Value semantics intentional — the buffer is cheap to copy (a String
/// is COW). The owning `DocumentModel` stores one per tab id and
/// replaces the slot on every mutation; SwiftUI gets normal diffing.
public struct EditorBuffer: Sendable, Equatable {
    public let url: URL
    /// What the buffer started as. Used as the dirty-flag reference
    /// AND to support a "revert" action (not wired in v1 but cheap).
    public private(set) var originalText: String
    /// Live edited contents. Mutate via `setText(_:)` so `isDirty`
    /// stays in sync.
    public private(set) var text: String
    public let encoding: String.Encoding
    /// Fingerprint of the file on disk as of the last successful read
    /// or save. Compared against the watcher-observed values to detect
    /// external edits. `nil` means we never captured one (rare — only
    /// when the file was unreadable at load time).
    public private(set) var lastSavedMTime: Date?
    public private(set) var lastSavedSize: Int?

    /// TSK-1204: a read-only buffer — an extracted view of a binary source
    /// (.docx/.rtf/.ods/.xlsx). `saveEditor` REFUSES to write a read-only buffer
    /// so the user can't overwrite the source with the displayed extracted text.
    /// Default false; set from `TextFile.isExtractedReadOnly` at buffer creation.
    public let isReadOnly: Bool

    public init(
        url: URL,
        original: String,
        encoding: String.Encoding = .utf8,
        lastSavedMTime: Date? = nil,
        lastSavedSize: Int? = nil,
        isReadOnly: Bool = false
    ) {
        self.url = url
        self.originalText = original
        self.text = original
        self.encoding = encoding
        self.lastSavedMTime = lastSavedMTime
        self.lastSavedSize = lastSavedSize
        self.isReadOnly = isReadOnly
    }

    /// True iff the buffer diverges from the last-saved contents.
    /// String equality is O(N) worst case but Swift fast-paths
    /// equal-length identity and length mismatches, so common-case
    /// "user typed one char" returns false at the length check.
    public var isDirty: Bool {
        text != originalText
    }

    /// Replace the buffered text. Pure mutation; persisting to disk is
    /// the caller's job (`save()` or `DocumentModel.saveActiveEditor`).
    public mutating func setText(_ newText: String) {
        text = newText
    }

    /// Mark the buffer clean. Called after a successful disk write —
    /// captures the new on-disk fingerprint so subsequent watcher
    /// events compare against the right baseline.
    public mutating func markSaved(diskMTime: Date?, diskSize: Int?) {
        originalText = text
        lastSavedMTime = diskMTime
        lastSavedSize = diskSize
    }

    /// Refresh ONLY the on-disk fingerprint without touching
    /// `originalText`. Used by the "Keep My Edits" branch of the
    /// external-edit conflict prompt: we want to silence the next
    /// (duplicate) watcher event for this write but keep the dirty
    /// baseline intact so `isDirty` still reflects the user's diff
    /// against the pre-conflict text — and a future Revert can still
    /// reach the pre-conflict baseline.
    public mutating func refreshSavedFingerprint(diskMTime: Date?, diskSize: Int?) {
        lastSavedMTime = diskMTime
        lastSavedSize = diskSize
    }

    /// True when the file on disk has been modified by another process
    /// since our last read/save. The watcher provides the current
    /// fingerprint; we compare against our cached one. Either mtime or
    /// size mismatch counts (mtime alone misses some Finder-copy
    /// flows; size alone misses same-length edits).
    ///
    /// **Caution:** a `false` here does NOT mean "the file is unchanged"
    /// — it can also mean "we can't tell" (a needed operand is nil; see
    /// `hasUnknownDiskState`). Callers that would *destroy unsaved work*
    /// on a `false` (e.g. silently reload over a dirty buffer) must
    /// first consult `hasUnknownDiskState` and treat "can't tell" as a
    /// conflict, not as "safe to reload". (EDIT-nil-fp / FW-8.)
    public func hasExternalEdit(currentMTime: Date?, currentSize: Int?) -> Bool {
        if let saved = lastSavedMTime, let cur = currentMTime, saved != cur { return true }
        if let saved = lastSavedSize, let cur = currentSize, saved != cur { return true }
        return false
    }

    /// True when we lack enough information to *prove* the file on disk
    /// is unchanged — i.e. any operand the comparison needs is `nil`.
    /// This happens when the buffer never captured a baseline (file was
    /// unreadable at load), or when the watcher couldn't stat the file
    /// for the current event (deleted / permission-stripped / racing a
    /// rename).
    ///
    /// `hasExternalEdit` returns `false` in all of these cases — it only
    /// returns `true` on a *proven* mismatch. That asymmetry is fine for
    /// the "should I re-prompt for a duplicate watcher event" path, but
    /// dangerous for the "should I reload over the user's edits" path:
    /// there, "can't tell" must be treated as a conflict so we prompt
    /// instead of silently discarding unsaved work. Decision table for
    /// the reload-branch caller (see `DocumentModel.reloadCurrentFile`):
    ///
    ///     dirty?  hasExternalEdit  hasUnknownDiskState  action
    ///     -----   ---------------  -------------------  ------
    ///     no      *                *                    reload (no work to lose)
    ///     yes     true             *                    prompt (definite conflict)
    ///     yes     false            true                 prompt (can't tell — be safe)
    ///     yes     false            false                reload (proven unchanged)
    public func hasUnknownDiskState(currentMTime: Date?, currentSize: Int?) -> Bool {
        // We can prove "unchanged" only if at least one fingerprint
        // dimension has both a saved baseline and a current reading and
        // they match — AND no dimension that has both readings mismatches
        // (that's `hasExternalEdit`'s job). If neither dimension can be
        // compared (every needed operand nil), state is unknown.
        let canCompareMTime = lastSavedMTime != nil && currentMTime != nil
        let canCompareSize = lastSavedSize != nil && currentSize != nil
        return !(canCompareMTime || canCompareSize)
    }
}

public extension EditorBuffer {
    /// Read a fresh buffer from disk. Wraps `TextFileLoader` so we
    /// share the BOM-sniff / encoding fallback path with the read-only
    /// `Source` view. Throws `FileLoadError` unchanged so the caller
    /// can route to the same error surface.
    ///
    /// EDIT-path cap is deliberately conservative (32 MiB) and does NOT
    /// inherit the read/view path's raised 512 MiB ceiling: editing a
    /// few-hundred-MB file is out of scope (the CM6/WKWebView editor JS
    /// heap can't take it — see `codeMirrorEditorMaxBytes`), and the
    /// read-only Source view is the right surface for files that big.
    static func load(
        url: URL,
        loader: TextFileLoader = TextFileLoader(maxBytes: 32 * 1024 * 1024)
    ) throws -> EditorBuffer {
        let file = try loader.load(url: url)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date
        let size = attrs?[.size] as? Int
        return EditorBuffer(
            url: url, original: file.contents, encoding: file.encoding,
            lastSavedMTime: mtime, lastSavedSize: size
        )
    }

    /// Construct a buffer from an already-loaded `TextFile` (avoids a
    /// second read when the tab is being upgraded from `.source` to
    /// `.editor` mode). The mtime/size fingerprint is captured fresh
    /// from disk so the conflict check has a baseline.
    init(from file: TextFile) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: file.url.path)
        let mtime = attrs?[.modificationDate] as? Date
        let size = attrs?[.size] as? Int
        self.init(
            url: file.url, original: file.contents, encoding: file.encoding,
            lastSavedMTime: mtime, lastSavedSize: size,
            isReadOnly: file.isExtractedReadOnly
        )
    }
}

/// Errors raised by `EditorWriter.save(_:to:encoding:)`. Distinguish
/// "encoding can't represent these characters" (user-recoverable —
/// could prompt to switch encoding) from a generic write failure
/// (permissions, disk full, sandbox).
public enum EditorWriteError: Error, Equatable {
    case encodingFailed(String.Encoding)
    case writeFailed(String)
    /// The target path is a symlink. `Data.write(.atomic)` would
    /// rename over the link, replacing it with the file contents and
    /// silently de-symlinking the user's setup. Surfaces as a
    /// recoverable error so the UI can prompt "follow the link?"
    /// (S5.1, 2026-05-25 review). Carries the resolved target path
    /// for the prompt.
    case targetIsSymlink(resolvedTarget: String)
}

/// Stateless on-disk writer for `EditorBuffer.text`. Lives separately
/// from `EditorBuffer` so the value type stays pure (no I/O) and
/// tests can substitute a fake writer if we ever need one.
public enum EditorWriter {
    /// Write `text` to `url` using `encoding`, atomically so a crash
    /// mid-write doesn't leave a half-written file. Returns the
    /// post-write `(mtime, size)` fingerprint so the caller can stamp
    /// the `EditorBuffer` via `markSaved`.
    ///
    /// **Metadata preservation (EDIT-attrs):** `Data.write(.atomic)`
    /// renames a brand-new temp file over the target, so the saved
    /// file inherits the *temp file's* identity — default umask
    /// permissions, the writing process's owner, and an empty xattr
    /// set. That silently drops the original file's mode bits
    /// (e.g. an executable script loses `+x`, a `0600` secret becomes
    /// world-readable), owner/group, ACL, extended attributes, and the
    /// `com.apple.quarantine` flag. We do the atomic-rename ourselves so
    /// we can stat the original first and replay its mode / owner /
    /// xattrs onto the replacement before the rename commits.
    ///
    /// **Symlink safety (S5.1, 2026-05-25; TOCTOU EDIT-S3-SYMLINK):**
    /// if `url` is a symbolic link, renaming over it would replace the
    /// symlink with a regular file and break the user's setup.
    /// `allowSymlink: false` (the default) throws `.targetIsSymlink` so
    /// the caller can prompt; `true` opts into the legacy "write
    /// through, de-symlinking" behavior. The symlink classification is
    /// done via an `O_NOFOLLOW | O_SYMLINK` open of the target so the
    /// decision is made against the same inode we then write next to —
    /// closing the stat-then-write gap of the prior `attributesOfItem`
    /// approach.
    /// Prepend the byte-order mark for explicit-endianness UTF-16 (TSK-861).
    /// `data(using: .utf16LittleEndian/.utf16BigEndian)` is BOM-less, but the
    /// read path (`TextDecoder.decodeViaBOM`) relies on the BOM to re-detect
    /// the encoding — and its BOM-less UTF-16 fallback needs ≥32 bytes + an
    /// 80% NUL-parity signal, which short files fail. `.utf16`/`.unicode`
    /// already carry a BOM, and every other encoding takes none, so only the
    /// two explicit-endianness cases need the marker added.
    static func withByteOrderMark(_ data: Data, encoding: String.Encoding) -> Data {
        switch encoding {
        case .utf16LittleEndian:
            return Data([0xFF, 0xFE]) + data
        case .utf16BigEndian:
            return Data([0xFE, 0xFF]) + data
        default:
            return data
        }
    }

    @discardableResult
    public static func save(
        _ text: String,
        to url: URL,
        encoding: String.Encoding = .utf8,
        allowSymlink: Bool = false
    ) throws -> (mtime: Date?, size: Int?) {
        guard let body = text.data(using: encoding) else {
            throw EditorWriteError.encodingFailed(encoding)
        }
        // TSK-861: re-emit the byte-order mark for explicit-endianness UTF-16.
        // `TextDecoder` strips the BOM on read and records `.utf16LittleEndian`
        // / `.utf16BigEndian`, but `data(using:)` for those encodings produces
        // BOM-LESS bytes — so a re-saved UTF-16 file loses its BOM, and a SHORT
        // file (below the read side's ≥32-byte BOM-less UTF-16 heuristic) then
        // mis-decodes as CP1252/Latin-1 on reopen (garbled). `.utf16`/`.unicode`
        // already include a BOM; UTF-8 / CP1252 / Latin-1 take none.
        let data = Self.withByteOrderMark(body, encoding: encoding)
        guard url.isFileURL else {
            throw EditorWriteError.writeFailed("not a file URL: \(url)")
        }

        // Open the existing target *without following symlinks* so the
        // classify-and-snapshot step races nothing: O_SYMLINK opens the
        // link itself (and lets us reject), O_NOFOLLOW opens a regular
        // file but fails with ELOOP on a symlink. We try a normal
        // (no-follow) open first; on ELOOP we know it's a symlink.
        let targetPath = url.path
        var existingMeta: ExistingFileMeta? = nil
        let existingFD = open(targetPath, O_RDONLY | O_NOFOLLOW)
        if existingFD >= 0 {
            defer { close(existingFD) }
            existingMeta = ExistingFileMeta(fd: existingFD)
        } else {
            let err = errno
            if err == ELOOP {
                // Target is a symlink. Refuse (default) or fall through
                // to the legacy write-through path (allowSymlink: true).
                if !allowSymlink {
                    let resolved = (try? FileManager.default
                        .destinationOfSymbolicLink(atPath: targetPath)) ?? targetPath
                    throw EditorWriteError.targetIsSymlink(resolvedTarget: resolved)
                }
                // Opt-in legacy behavior: write through the link,
                // de-symlinking it (matches the documented contract +
                // existing test). Use Data.write so we hit the resolved
                // target the same way the old code did.
                do {
                    try data.write(to: url, options: [.atomic])
                } catch {
                    throw EditorWriteError.writeFailed("\(error)")
                }
                return statFingerprint(targetPath)
            }
            if err == EACCES {
                // The file EXISTS but we can't open it for reading
                // (0200/0600-but-ACL-denied secret, root-owned file
                // writable via group/ACL, a read-restricting ACL). This
                // is NOT a new file — treating it as one would let the
                // temp file's umask mode (0644) + the writer's owner ride
                // over the rename, silently downgrading a 0600 secret to
                // world-readable and dropping owner/group. Recover the
                // security-critical mode + owner via lstat (no read access
                // needed, and — like our O_NOFOLLOW classify — it does not
                // follow symlinks) so `replay` still re-applies them.
                //
                // Xattrs (quarantine / ACL-as-xattr) genuinely can't be
                // read without an fd we were denied, so they are NOT
                // preserved on this path — but mode/owner, the bits whose
                // loss is a privilege downgrade, are. If even lstat fails
                // (e.g. the file vanished, or directory perms changed
                // under us), refuse the save rather than silently
                // downgrade: a recoverable error beats a permission leak.
                guard let meta = ExistingFileMeta(eaccesAtPath: targetPath) else {
                    throw EditorWriteError.writeFailed(
                        "cannot preserve permissions of unreadable file (EACCES): \(targetPath)"
                    )
                }
                existingMeta = meta
            }
            // ENOENT (new file) or any other error: no existing metadata
            // to preserve. Fall through to the temp-write path; a
            // genuine permission problem surfaces on the rename below.
        }

        // Write the new bytes to a temp sibling in the *same* directory
        // so the final rename(2) is atomic (same volume) and the temp
        // file inherits the target dir's volume semantics.
        let dir = url.deletingLastPathComponent()
        let tempURL = dir.appendingPathComponent(
            ".\(url.lastPathComponent).mdv-\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: tempURL, options: [.atomic])
        } catch {
            throw EditorWriteError.writeFailed("\(error)")
        }

        // Replay the original file's identity onto the temp before the
        // rename commits. Best-effort: a failure to chown (common — only
        // root can change owner) must not abort the save, but a failure
        // to set mode is worth preserving silently too (the file is
        // still written). We deliberately swallow these — the user's
        // bytes are the contract; metadata is a courtesy.
        if let meta = existingMeta {
            meta.replay(onto: tempURL.path)
        }

        // Atomic rename temp → target. POSIX rename(2) replaces the
        // destination in one step. If the destination *became* a symlink
        // between our O_NOFOLLOW classify and now, rename still replaces
        // the link itself (not its target) — which is the safe outcome
        // for the refuse path: we never write through a link's target.
        if rename(tempURL.path, targetPath) != 0 {
            let err = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: tempURL)
            throw EditorWriteError.writeFailed("rename failed: \(err)")
        }
        return statFingerprint(targetPath)
    }

    /// Post-write `(mtime, size)` fingerprint via FileManager attrs.
    private static func statFingerprint(_ path: String) -> (mtime: Date?, size: Int?) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.modificationDate] as? Date, attrs?[.size] as? Int)
    }
}

/// Snapshot of an existing file's preservable metadata, captured from
/// an open fd so it can't race a concurrent rename/symlink swap.
/// Replayed onto the replacement temp file before the atomic rename.
private struct ExistingFileMeta {
    let mode: mode_t
    let uid: uid_t
    let gid: gid_t
    let xattrs: [(name: String, value: Data)]

    init(fd: Int32) {
        var st = stat()
        if fstat(fd, &st) == 0 {
            mode = st.st_mode & 0o7777   // permission + setuid/setgid/sticky bits
            uid = st.st_uid
            gid = st.st_gid
        } else {
            mode = 0; uid = 0; gid = 0
        }
        xattrs = XattrIO.read(fd: fd)
    }

    /// Recover mode/owner for an existing file we were DENIED read access
    /// to (open(O_RDONLY) returned EACCES). `lstat` needs only directory
    /// traversal/search permission — not read permission on the file — and
    /// does not follow symlinks (consistent with the writer's O_NOFOLLOW
    /// classify; the symlink case is handled earlier via ELOOP, so a
    /// regular file is expected here). Returns nil if even lstat fails
    /// (file vanished / dir perms changed), so the caller can refuse the
    /// save rather than silently downgrade permissions. Xattrs are
    /// unreadable without an fd, so they are left empty on this path.
    init?(eaccesAtPath path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        mode = st.st_mode & 0o7777
        uid = st.st_uid
        gid = st.st_gid
        xattrs = []
    }

    /// Best-effort replay onto `path`. Each step is independent — a
    /// failure to set one attribute must not block the others.
    func replay(onto path: String) {
        // Owner/group first (chown can clear setuid/setgid bits on some
        // systems, so set mode *after*).
        if uid != 0 || gid != 0 {
            _ = chown(path, uid, gid)
        }
        if mode != 0 {
            _ = chmod(path, mode)
        }
        XattrIO.apply(xattrs, toPath: path)
    }
}
