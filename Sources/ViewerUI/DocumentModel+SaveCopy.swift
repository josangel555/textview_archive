import Foundation
import Combine
import SwiftUI
import ViewerKit
import ViewerCore

// MARK: - Save a Copy + close-dirty forwarder (file-lifecycle)
//
// Carved out of DocumentModel.swift (TSK-1110 — DocumentModel SRP split).
// "Save a Copy" (TSK-300) is the headless/automation core of a side write
// that leaves the open tab untouched; the close-dirty forwarder is the other
// file-lifecycle escape hatch. The HEX-dirty content source is read through
// the vended `dirtyHexBytes(forTabID:)` accessor so this file never touches
// the HEX section's private `hexDirtyBytes` storage directly.
extension DocumentModel {

    public enum SaveCopyError: Error, Equatable {
        case noTab          // index out of range
        case emptyTab       // nothing to copy (no URL and no editable buffer)
        case encodingFailed // editor text couldn't be encoded
    }

    /// Write a COPY of the tab at `index` to `target`, leaving the open tab
    /// fully untouched (URL, dirty state, editor/HEX buffers, the file
    /// watcher — a copy is a side write, NOT a save of the active document).
    ///
    /// Captures the tab's CURRENT effective content so unsaved edits are
    /// included, most-specific first:
    ///   1. editable-HEX dirty bytes (#234), else
    ///   2. the editor buffer's live text (when dirty), else
    ///   3. a verbatim copy of the file on disk.
    ///
    /// (3) streams via `FileManager.copyItem` (no slurp into memory, preserves
    /// attributes); the dirty cases write atomically. Overwrite is supported
    /// (the SavePanel confirms it) without a data-loss window: case (3) copies
    /// to a temp sibling then `replaceItemAt`, and the dirty cases use atomic
    /// writes. This is the headless/automation core (`save-copy` verb); the
    /// menu + `NSSavePanel` that pick `target` are a thin live follow-up.
    @discardableResult
    public func saveCopy(ofTabAt index: Int, to target: URL) throws -> Bool {
        guard tabs.tabs.indices.contains(index) else { throw SaveCopyError.noTab }
        let tab = tabs.tabs[index]

        // 1. HEX-dirty bytes win (most specific live edit).
        if let bytes = dirtyHexBytes(forTabID: tab.id) {
            try bytes.write(to: target, options: .atomic)
            return true
        }
        // 2. Editor-dirty text, encoded with the buffer's own encoding.
        // Encode with the buffer's OWN encoding only — do NOT silently fall
        // back to UTF-8 (the old `?? buf.text.data(using: .utf8)` made
        // `SaveCopyError.encodingFailed` dead code, since UTF-8 represents
        // any String). A silent re-encode is data corruption: a "Save a
        // Copy" of a Shift-JIS / Latin-1 buffer that the user expects to
        // round-trip would land as UTF-8 with a different byte stream and a
        // mismatched declared encoding. Mirror `EditorWriter.save`: surface
        // the failure so the caller can prompt to switch encoding.
        if let buf = editor.editorBuffer(forTabID: tab.id), buf.isDirty {
            guard let data = buf.text.data(using: buf.encoding) else {
                throw SaveCopyError.encodingFailed
            }
            try data.write(to: target, options: .atomic)
            return true
        }
        // 3. Verbatim copy of the on-disk file (streamed, attribute-preserving).
        guard let src = tab.url else { throw SaveCopyError.emptyTab }
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent(".mdv-savecopy-\(UUID().uuidString).tmp")
        try FileManager.default.copyItem(at: src, to: tmp)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        return true
    }

    /// Convenience: save a copy of the currently-selected tab. Returns false
    /// if there is no selection; rethrows write failures.
    @discardableResult
    public func saveCopyOfCurrentTab(to target: URL) throws -> Bool {
        guard let i = tabs.selectedIndex else { return false }
        return try saveCopy(ofTabAt: i, to: target)
    }

    /// Whether "Save a Copy…" has anything to write for the current tab —
    /// drives the File-menu item's `validateMenuItem`. True when a tab is
    /// selected AND it has on-disk content, a non-empty editor buffer, or
    /// pending HEX-dirty bytes (the three sources `saveCopy` draws from). A
    /// blank Untitled tab with no edits has nothing to copy → disabled.
    public var canSaveCopyOfCurrentTab: Bool {
        guard let tab = tabs.selected else { return false }
        if tab.url != nil { return true }
        if let buf = editor.editorBuffer(forTabID: tab.id), !buf.text.isEmpty { return true }
        return dirtyHexBytes(forTabID: tab.id) != nil
    }

    /// A suggested filename for the Save-a-Copy panel: the current tab's own
    /// name, else a generic default. Pure so the menu layer doesn't reach
    /// into tab internals.
    public var saveCopySuggestedName: String {
        tabs.selected?.url?.lastPathComponent ?? "Untitled.txt"
    }

    /// Forwarder. New code should call `editor.confirmCloseIfDirty(at:)`.
    public func confirmCloseIfDirty(at index: Int) -> DirtyClosePrompt? {
        editor.confirmCloseIfDirty(at: index)
    }
}
