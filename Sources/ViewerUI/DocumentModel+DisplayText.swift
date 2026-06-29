import Foundation
import ViewerCore

// Displayed-text derivation (TSK-1110 SRP slice) — resolves the text shown in the
// View-Only/.source lens: large-read-only passthrough, live dirty-buffer text
// (TSK-729), and formatted (pretty-printed) views via the format memo. Pure host
// logic, no stored state. Behavior-preserving move out of DocumentModel.swift
// (it was mis-filed under the Editable-HEX MARK).
extension DocumentModel {

    public func displayedText(for file: TextFile) -> DisplayedText {
        if file.isLargeReadOnly {
            return DisplayedText(
                text: file.contents,
                byteLength: file.byteCount,
                modifiedTime: file.modifiedTime
            )
        }
        // TSK-729: the View Only (.source) lens must show UNSAVED edits, not the
        // stale on-disk text. If the selected tab has a DIRTY editor buffer, render
        // its live text (matching the Editor path's `buf?.text ?? file.contents`
        // and the outline path at :1342). A clean/absent buffer falls through to
        // the disk path below (identical text, and the format memo still applies).
        if let selID = tabs.selected?.id,
           let buf = editor.editorBuffer(forTabID: selID), buf.isDirty {
            let live = buf.text
            // Dirty edits bypass the format memo — its cache key is the on-disk
            // (length, mtime), which no longer matches the buffer. Pretty-print
            // live when the tab is in a formatted view; otherwise raw edited text.
            if tabCoordinator.formattedTabIDs.contains(selID),
               let format = Formatter.SupportedFormat.detect(file.url) {
                let pretty = Formatter.prettyPrint(live, as: format)
                return DisplayedText(
                    text: pretty,
                    byteLength: pretty.utf8.count,
                    modifiedTime: file.modifiedTime
                )
            }
            return DisplayedText(
                text: live,
                byteLength: live.utf8.count,
                modifiedTime: file.modifiedTime
            )
        }
        guard let id = tabs.selected?.id,
              tabCoordinator.formattedTabIDs.contains(id),
              let format = Formatter.SupportedFormat.detect(file.url) else {
            // Raw path: `file.byteCount` is the utf8 length captured at
            // load — no re-walk.
            return DisplayedText(
                text: file.contents,
                byteLength: file.byteCount,
                modifiedTime: file.modifiedTime
            )
        }
        let len = file.byteCount
        if let hit = tabCoordinator.formattedHit(
            forTabID: id, sourceLength: len, modifiedTime: file.modifiedTime
        ) {
            return DisplayedText(
                text: hit.formatted,
                byteLength: hit.formattedLength,
                modifiedTime: file.modifiedTime
            )
        }
        let result = Formatter.prettyPrint(file.contents, as: format)
        let formattedLen = result.utf8.count
        tabCoordinator.cacheFormatted(
            result, forTabID: id,
            sourceLength: len, modifiedTime: file.modifiedTime,
            formattedLength: formattedLen
        )
        return DisplayedText(
            text: result,
            byteLength: formattedLen,
            modifiedTime: file.modifiedTime
        )
    }

    /// Backwards-compat string-only accessor. New callers should use
    /// `displayedText(for:)` to get the byte length + mtime for free.
    public func displayText(for file: TextFile) -> String {
        displayedText(for: file).text
    }
}
