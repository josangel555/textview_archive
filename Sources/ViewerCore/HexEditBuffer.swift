import Foundation
import Darwin

/// Pure, host-testable byte buffer backing the EDITABLE hex view (#234).
///
/// Hex editors **overwrite** — they never insert or delete (that would
/// renumber every following offset and is a different, far heavier
/// feature). So this buffer is fixed-length: it holds the `original`
/// bytes (as loaded) and the `edited` bytes (same count), and every edit
/// replaces a byte in place. Dirtiness is "edited diverges from original".
///
/// Two edit entry points, both overwrite:
///   * `setNibble(byte:nibble:value:)` — the hex column. A byte is two
///     nibbles; `nibble == 0` is the high nibble (top 4 bits), `1` the
///     low. The ASCII column stays in sync automatically because both
///     read the same `edited` array.
///   * `setByte(byte:value:)` — the ASCII column (typing a printable
///     char sets the whole byte) and any direct full-byte write.
///
/// Undo/redo is a flat stack of single-byte `(index, old, new)` changes.
/// Each public mutation that actually changes a byte pushes one entry and
/// clears the redo stack — standard editor semantics. Undo/redo replay
/// the recorded old/new value, so they're exact inverses regardless of
/// how the byte got its current value.
///
/// Value semantics intentional (COW arrays): cheap to copy, the owning
/// controller keeps one and replaces it on mutation. No I/O here — the
/// write-back lives in `HexBinaryWriter` so this type stays pure.
public struct HexEditBuffer: Equatable, Sendable {

    /// The bytes as originally loaded. The dirty baseline AND the
    /// "revert" source. Fixed length for the buffer's lifetime.
    public private(set) var original: [UInt8]

    /// Live edited bytes. Same count as `original`. Mutated only through
    /// `setNibble` / `setByte` / `undo` / `redo` so the undo stack and
    /// dirty flag stay coherent.
    public private(set) var edited: [UInt8]

    /// A single overwrite, recorded for undo/redo. `index` is the byte
    /// position; `old`/`new` are the full byte values before/after.
    public struct Edit: Equatable, Sendable {
        public let index: Int
        public let old: UInt8
        public let new: UInt8
        public init(index: Int, old: UInt8, new: UInt8) {
            self.index = index
            self.old = old
            self.new = new
        }
    }

    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []

    public init(original: [UInt8]) {
        self.original = original
        self.edited = original
    }

    public init(data: Data) {
        self.init(original: [UInt8](data))
    }

    public var count: Int { edited.count }

    /// True iff any edited byte diverges from its original. Cheap —
    /// equal-length array `==` short-circuits on the first mismatch and
    /// is memcmp-fast when clean.
    public var isDirty: Bool { edited != original }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// The edited bytes as `Data`, ready for `HexBinaryWriter`.
    public var data: Data { Data(edited) }

    /// Indices whose edited value differs from the original. Used by the
    /// view to paint a "modified" tint on changed bytes.
    public var dirtyByteIndices: [Int] {
        var out: [Int] = []
        out.reserveCapacity(min(edited.count, 64))
        for i in edited.indices where edited[i] != original[i] {
            out.append(i)
        }
        return out
    }

    public func byte(at index: Int) -> UInt8? {
        edited.indices.contains(index) ? edited[index] : nil
    }

    /// The originally-loaded byte at `index` (the dirty baseline).
    public func original(at index: Int) -> UInt8? {
        original.indices.contains(index) ? original[index] : nil
    }

    // MARK: - Mutations (all OVERWRITE)

    /// Overwrite one nibble of `byte`. `nibble == 0` ⇒ high (top 4 bits),
    /// `1` ⇒ low. `value` is masked to 0–15. No-op (returns `false`, no
    /// undo entry) if the resulting byte is unchanged or the index is out
    /// of range.
    @discardableResult
    public mutating func setNibble(byte index: Int, nibble: Int, value: UInt8) -> Bool {
        guard edited.indices.contains(index) else { return false }
        let v = value & 0x0F
        let old = edited[index]
        let new: UInt8 = (nibble == 0)
            ? (old & 0x0F) | (v << 4)
            : (old & 0xF0) | v
        return apply(index: index, new: new)
    }

    /// Overwrite a whole byte (ASCII-column edit, or any full-byte set).
    /// No-op if unchanged or out of range.
    @discardableResult
    public mutating func setByte(byte index: Int, value: UInt8) -> Bool {
        guard edited.indices.contains(index) else { return false }
        return apply(index: index, new: value)
    }

    /// Record + apply an overwrite. Pushes an undo entry and clears redo
    /// only when the value actually changes — a re-type of the same value
    /// is a true no-op and must not pollute the undo history.
    private mutating func apply(index: Int, new: UInt8) -> Bool {
        let old = edited[index]
        guard old != new else { return false }
        edited[index] = new
        undoStack.append(Edit(index: index, old: old, new: new))
        redoStack.removeAll(keepingCapacity: true)
        return true
    }

    /// Undo the most recent edit. Returns the index that changed (so the
    /// view can move the caret there), or `nil` if there's nothing to undo.
    @discardableResult
    public mutating func undo() -> Int? {
        guard let edit = undoStack.popLast() else { return nil }
        edited[edit.index] = edit.old
        redoStack.append(edit)
        return edit.index
    }

    /// Redo the most recently undone edit. Returns the changed index.
    @discardableResult
    public mutating func redo() -> Int? {
        guard let edit = redoStack.popLast() else { return nil }
        edited[edit.index] = edit.new
        undoStack.append(edit)
        return edit.index
    }

    /// Mark the current edited bytes as the new clean baseline (after a
    /// successful save) and drop undo/redo history — the on-disk file is
    /// now the reference, so prior edits are no longer "undoable to the
    /// loaded state". Mirrors `EditorBuffer.markSaved`.
    public mutating func markSaved() {
        original = edited
        undoStack.removeAll(keepingCapacity: false)
        redoStack.removeAll(keepingCapacity: false)
    }

    /// Discard all edits — restore `edited` to `original` and clear the
    /// stacks. Used by the "Don't Save" close branch / revert.
    public mutating func revert() {
        edited = original
        undoStack.removeAll(keepingCapacity: false)
        redoStack.removeAll(keepingCapacity: false)
    }
}

/// Hex digit ⇄ nibble-value parsing for the hex-column edit path. Pure.
public enum HexNibble {
    /// Nibble value (0–15) for an ASCII hex digit character, or `nil` if
    /// the character isn't `0-9a-fA-F`.
    public static func value(of scalar: Unicode.Scalar) -> UInt8? {
        switch scalar {
        case "0"..."9": return UInt8(scalar.value - 0x30)        // '0'
        case "a"..."f": return UInt8(scalar.value - 0x61 + 10)   // 'a'
        case "A"..."F": return UInt8(scalar.value - 0x41 + 10)   // 'A'
        default:        return nil
        }
    }

    /// True if `scalar` is a printable ASCII char (0x20–0x7E) the ASCII
    /// column accepts as a direct byte-set. Matches the dump's printable
    /// range so what you type is what the dump shows.
    public static func isPrintableASCII(_ scalar: Unicode.Scalar) -> Bool {
        (0x20...0x7E).contains(scalar.value)
    }
}

/// Errors from `HexBinaryWriter.write`.
public enum HexWriteError: Error, Equatable {
    case writeFailed(String)
    /// Target is a symlink; refused by default to avoid de-symlinking the
    /// user's setup (same posture as `EditorWriter`). Carries the resolved
    /// target so the UI can prompt.
    case targetIsSymlink(resolvedTarget: String)
}

/// Stateless binary write-back for an edited hex buffer.
///
/// The text loader / `EditorWriter` are UTF-8/encoding-aware; a hex buffer
/// is raw bytes, so it needs its own write path. This mirrors
/// `EditorWriter`'s safety posture — atomic temp-file + `rename(2)`,
/// symlink refusal by default, best-effort metadata (mode / owner / xattr)
/// preservation — but writes `Data` verbatim with no encoding step.
public enum HexBinaryWriter {
    /// Write `data` to `url` atomically. Returns the post-write
    /// `(mtime, size)` fingerprint.
    ///
    /// - Important: the hex view caps reads at 4 MB and refuses to enter
    ///   edit mode on a *truncated* file (you'd otherwise silently drop
    ///   the unread tail on save). That guard lives in the controller;
    ///   this writer writes exactly the bytes it's given.
    @discardableResult
    public static func write(
        _ data: Data,
        to url: URL,
        allowSymlink: Bool = false
    ) throws -> (mtime: Date?, size: Int?) {
        guard url.isFileURL else {
            throw HexWriteError.writeFailed("not a file URL: \(url)")
        }
        let targetPath = url.path

        // Classify symlink vs regular via an O_NOFOLLOW open (same race-
        // free approach as EditorWriter). ELOOP ⇒ it's a symlink.
        let existingFD = open(targetPath, O_RDONLY | O_NOFOLLOW)
        var existingMeta: HexFileMeta? = nil
        if existingFD >= 0 {
            defer { close(existingFD) }
            existingMeta = HexFileMeta(fd: existingFD)
        } else if errno == ELOOP {
            if !allowSymlink {
                let resolved = (try? FileManager.default
                    .destinationOfSymbolicLink(atPath: targetPath)) ?? targetPath
                throw HexWriteError.targetIsSymlink(resolvedTarget: resolved)
            }
            do {
                try data.write(to: url, options: [.atomic])
            } catch {
                throw HexWriteError.writeFailed("\(error)")
            }
            return statFingerprint(targetPath)
        }
        // ENOENT (new file) or other: nothing to preserve; fall through.

        let dir = url.deletingLastPathComponent()
        let tempURL = dir.appendingPathComponent(
            ".\(url.lastPathComponent).mdv-hex-\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: tempURL, options: [.atomic])
        } catch {
            throw HexWriteError.writeFailed("\(error)")
        }
        existingMeta?.replay(onto: tempURL.path)

        if rename(tempURL.path, targetPath) != 0 {
            let err = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: tempURL)
            throw HexWriteError.writeFailed("rename failed: \(err)")
        }
        return statFingerprint(targetPath)
    }

    private static func statFingerprint(_ path: String) -> (mtime: Date?, size: Int?) {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.modificationDate] as? Date, attrs?[.size] as? Int)
    }
}

/// Preservable file metadata snapshot — mode / owner / xattrs — captured
/// from an open fd and replayed onto the replacement temp before the
/// atomic rename. Mirror of `EditorBuffer`'s private `ExistingFileMeta`.
private struct HexFileMeta {
    let mode: mode_t
    let uid: uid_t
    let gid: gid_t
    let xattrs: [(name: String, value: Data)]

    init(fd: Int32) {
        var st = stat()
        if fstat(fd, &st) == 0 {
            mode = st.st_mode & 0o7777
            uid = st.st_uid
            gid = st.st_gid
        } else {
            mode = 0; uid = 0; gid = 0
        }
        xattrs = XattrIO.read(fd: fd)
    }

    func replay(onto path: String) {
        if uid != 0 || gid != 0 { _ = chown(path, uid, gid) }
        if mode != 0 { _ = chmod(path, mode) }
        XattrIO.apply(xattrs, toPath: path)
    }
}
