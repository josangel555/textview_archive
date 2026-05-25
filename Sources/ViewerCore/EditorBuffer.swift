import Foundation

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

    public init(
        url: URL,
        original: String,
        encoding: String.Encoding = .utf8,
        lastSavedMTime: Date? = nil,
        lastSavedSize: Int? = nil
    ) {
        self.url = url
        self.originalText = original
        self.text = original
        self.encoding = encoding
        self.lastSavedMTime = lastSavedMTime
        self.lastSavedSize = lastSavedSize
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
    public func hasExternalEdit(currentMTime: Date?, currentSize: Int?) -> Bool {
        if let saved = lastSavedMTime, let cur = currentMTime, saved != cur { return true }
        if let saved = lastSavedSize, let cur = currentSize, saved != cur { return true }
        return false
    }
}

public extension EditorBuffer {
    /// Read a fresh buffer from disk. Wraps `TextFileLoader` so we
    /// share the BOM-sniff / encoding fallback path with the read-only
    /// `Source` view. Throws `FileLoadError` unchanged so the caller
    /// can route to the same error surface.
    static func load(url: URL, loader: TextFileLoader = TextFileLoader()) throws -> EditorBuffer {
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
            lastSavedMTime: mtime, lastSavedSize: size
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
    /// **Symlink safety (S5.1, 2026-05-25):** if `url` is a symbolic
    /// link, `Data.write(.atomic)` would rename the new file over the
    /// link, replacing the symlink with the file contents and
    /// breaking the user's setup. `allowSymlink: false` (the default)
    /// throws `.targetIsSymlink` so the caller can prompt; pass
    /// `true` to opt into the legacy "write through, de-symlinking"
    /// behavior. The UI hasn't been updated yet to surface the
    /// prompt — the throw becomes a save error that the user sees,
    /// which is strictly better than silently breaking their dotfile.
    @discardableResult
    public static func save(
        _ text: String,
        to url: URL,
        encoding: String.Encoding = .utf8,
        allowSymlink: Bool = false
    ) throws -> (mtime: Date?, size: Int?) {
        guard let data = text.data(using: encoding) else {
            throw EditorWriteError.encodingFailed(encoding)
        }
        // Symlink check. Use destinationOfSymbolicLink which throws
        // when the path is NOT a symlink — that's the "safe" case.
        if !allowSymlink {
            // `attributesOfItem(atPath:)` reports the *link's* type
            // when the path is itself a symlink — does NOT follow.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let type = attrs[.type] as? FileAttributeType,
               type == .typeSymbolicLink {
                let target = (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: url.path
                )) ?? url.path
                throw EditorWriteError.targetIsSymlink(resolvedTarget: target)
            }
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw EditorWriteError.writeFailed("\(error)")
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let mtime = attrs?[.modificationDate] as? Date
        let size = attrs?[.size] as? Int
        return (mtime, size)
    }
}
