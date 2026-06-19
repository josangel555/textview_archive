import Foundation

/// How an editor buffer relates to the file underneath it once the file
/// watcher reports an external write. This is the three-way decision model
/// that generalizes `EditorCoordinator`'s old binary keepEdits/discardAndReload
/// prompt (TSK-768): we want to distinguish a *safe auto-reload* (the file
/// changed but the user has no unsaved edits to lose) from a genuine *conflict*
/// (both sides diverged), and to keep a captured baseline around so a future
/// three-way merge UI has the common ancestor to work from.
///
/// Orthogonal to `Tab.DiskState`: `DiskState` is the per-tab *display* signal
/// the tab strip reads (fresh / staleVsDisk / deleted); `DiskConflictState` is
/// the *resolution* classification the editor uses to decide what to do with
/// the buffer when disk and buffer may both have moved.
public enum DiskConflictState: String, Sendable, Equatable {
    /// Buffer is clean AND we can prove the file on disk is unchanged. No
    /// action needed — nothing diverged.
    case inSync
    /// The file on disk changed but the buffer has NO unsaved edits — there
    /// is nothing to lose, so this is a safe auto-reload candidate. The UI can
    /// quietly take the disk bytes (or surface a "reloaded" toast) rather than
    /// blocking the user with a conflict prompt.
    case externalChangeNoLocalEdits
    /// Both sides moved: the buffer is dirty AND the file on disk changed (or
    /// we can't *prove* it is unchanged while the buffer is dirty — treated as
    /// a conflict so we never silently discard unsaved work; mirrors
    /// `EditorBuffer.hasUnknownDiskState`'s "can't tell ⇒ be safe" rule). The
    /// UI must prompt for a resolution intent.
    case conflict

    /// Whether this state requires the user to choose a resolution intent
    /// (i.e. show the conflict banner / prompt). Only `.conflict` does.
    public var requiresResolution: Bool { self == .conflict }

    /// Whether the file may be reloaded from disk WITHOUT losing unsaved work.
    /// True for `.inSync` (no-op reload) and `.externalChangeNoLocalEdits`
    /// (the safe auto-reload case); false for `.conflict` (would clobber edits).
    public var isSafeToAutoReload: Bool { self != .conflict }
}

/// The user's chosen resolution for a `.conflict` (or the implicit choice for
/// `.externalChangeNoLocalEdits`). Carries no payload — `DiskConflictResolver`
/// applies the side-effect against the buffer + on-disk fingerprint.
public enum DiskConflictIntent: String, Sendable, Equatable {
    /// Keep the in-buffer edits, silencing the (duplicate) watcher event by
    /// re-fingerprinting WITHOUT touching the dirty baseline. `isDirty` stays
    /// true and a later Revert can still reach the pre-conflict baseline.
    case keepMine
    /// Discard the buffer's edits and take the file's on-disk contents,
    /// re-fingerprinting against the freshly-read bytes (buffer becomes clean).
    case takeDisk
    /// Defer the decision and capture a merge baseline (the common ancestor +
    /// both sides) for a future three-way merge UI. No buffer mutation yet.
    case merge
}

/// Immutable snapshot of the inputs the conflict classifier needs, plus the
/// captured pre-conflict baseline. A value type so it is cheap to copy, trivial
/// to test, and free of I/O — the owning coordinator does the disk read and
/// hands the fingerprints in.
///
/// The baseline (`baselineText` + the saved fingerprint) is what a future merge
/// UI uses as the common ancestor, AND what `revert` restores to. It is the
/// `EditorBuffer.originalText` at the moment the conflict was captured — i.e.
/// the last-saved contents, NOT the live edited text.
public struct DiskConflictResolver: Sendable, Equatable {
    /// The pre-conflict baseline text: `EditorBuffer.originalText` at capture
    /// time. The common ancestor for a three-way merge and the target a Revert
    /// restores exactly.
    public let baselineText: String
    /// The buffer's live edited text at capture time ("mine").
    public let localText: String
    /// The on-disk fingerprint baseline (mtime/size) the buffer was carrying.
    public let baselineMTime: Date?
    public let baselineSize: Int?

    /// Construct directly from already-snapshotted values (tests / non-buffer
    /// callers).
    public init(
        baselineText: String,
        localText: String,
        baselineMTime: Date?,
        baselineSize: Int?
    ) {
        self.baselineText = baselineText
        self.localText = localText
        self.baselineMTime = baselineMTime
        self.baselineSize = baselineSize
    }

    /// Capture the pre-conflict baseline from a live `EditorBuffer`. Records
    /// the last-saved text + fingerprint as the merge ancestor / revert target.
    public init(capturing buffer: EditorBuffer) {
        self.baselineText = buffer.originalText
        self.localText = buffer.text
        self.baselineMTime = buffer.lastSavedMTime
        self.baselineSize = buffer.lastSavedSize
    }

    /// Classify the situation from the buffer's dirty state and the on-disk
    /// fingerprint observed by the watcher. Pure — no I/O.
    ///
    /// Decision table (mirrors `EditorBuffer`'s reload-branch contract so the
    /// classifier and the lower-level buffer helpers can't drift):
    ///
    ///     dirty?  externalEdit  unknownDiskState  →  state
    ///     -----   ------------  ----------------     ----------------------------
    ///     no      false         false                inSync (proven unchanged)
    ///     no      false         true                 inSync (clean; nothing to lose)
    ///     no      true          *                    externalChangeNoLocalEdits
    ///     yes     true          *                    conflict (both moved)
    ///     yes     false         true                 conflict (can't tell — be safe)
    ///     yes     false         false                inSync (proven unchanged; just dirty)
    ///
    /// - Note: a *clean* buffer with an unknown disk state is `inSync`, not a
    ///   conflict: there are no edits to lose, so a (possibly redundant) reload
    ///   is harmless. Only a *dirty* buffer escalates "can't tell" to a conflict.
    public static func classify(
        dirty: Bool,
        hasExternalEdit: Bool,
        hasUnknownDiskState: Bool
    ) -> DiskConflictState {
        if dirty {
            // Unsaved edits present: a proven external edit OR an unprovable
            // disk state both mean we cannot safely auto-reload.
            if hasExternalEdit || hasUnknownDiskState { return .conflict }
            return .inSync
        } else {
            // No edits to lose. A proven external edit is a safe reload
            // candidate; otherwise nothing diverged worth acting on.
            return hasExternalEdit ? .externalChangeNoLocalEdits : .inSync
        }
    }

    /// Convenience: classify directly against a live `EditorBuffer` and the
    /// watcher-observed current fingerprint.
    public static func classify(
        buffer: EditorBuffer,
        currentMTime: Date?,
        currentSize: Int?
    ) -> DiskConflictState {
        classify(
            dirty: buffer.isDirty,
            hasExternalEdit: buffer.hasExternalEdit(
                currentMTime: currentMTime, currentSize: currentSize),
            hasUnknownDiskState: buffer.hasUnknownDiskState(
                currentMTime: currentMTime, currentSize: currentSize)
        )
    }

    // MARK: - Resolution intents (buffer side-effects)

    /// `keepMine`: silence the (duplicate) watcher event for the external write
    /// by re-fingerprinting the buffer against the disk bytes — WITHOUT
    /// touching `originalText`. The buffer stays dirty (the user keeps their
    /// edits) and a later `revert` can still reach the pre-conflict baseline.
    /// Returns the mutated buffer (value semantics — the caller stores it back).
    public func applyKeepMine(
        to buffer: EditorBuffer, diskMTime: Date?, diskSize: Int?
    ) -> EditorBuffer {
        var out = buffer
        out.refreshSavedFingerprint(diskMTime: diskMTime, diskSize: diskSize)
        return out
    }

    /// `takeDisk`: discard the buffer's edits and adopt the file's on-disk
    /// contents, re-fingerprinting against them so the buffer becomes clean.
    /// The caller supplies the freshly-read disk text + its fingerprint (the
    /// resolver does no I/O). Returns the mutated buffer.
    public func applyTakeDisk(
        to buffer: EditorBuffer, diskText: String, diskMTime: Date?, diskSize: Int?
    ) -> EditorBuffer {
        var out = buffer
        out.setText(diskText)
        // markSaved snaps originalText to the new (disk) text + stamps the
        // fingerprint, so the buffer is clean and matches disk.
        out.markSaved(diskMTime: diskMTime, diskSize: diskSize)
        return out
    }

    /// Undo-able "revert to pre-conflict baseline": restore the buffer's text
    /// to the captured `baselineText` exactly. The buffer's `originalText`
    /// baseline is left intact, so `isDirty` reflects whether the restored text
    /// differs from the last-saved baseline (typically clean, since we revert
    /// *to* that baseline) — and the operation is undo-able by re-applying the
    /// previously-edited text (the caller drives the undo stack; this is a pure
    /// text replacement, which NSTextView/CM6 undo wraps as one coalesced edit).
    /// Returns the mutated buffer.
    public func applyRevert(to buffer: EditorBuffer) -> EditorBuffer {
        var out = buffer
        out.setText(baselineText)
        return out
    }
}
