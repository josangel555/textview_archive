import Foundation
import ViewerCore

// Active-file format conversions (TSK-1110 SRP slice; TSK-352/675) — re-encode,
// re-line-end, or re-indent the active file in place: write-through (preserving
// unsaved edits) then drop+reload so the app re-detects it. Indent-convert routes
// through the internal `applyTextTransformToActiveFile` seam; encoding/line-ending
// convert write directly via `EditorWriter` (encoding is a property of the write,
// not a pure text transform). The `activeTextWithEncoding` / `reloadCurrentFile`
// seams stay on DocumentModel. Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// The active tab's current text (live editor buffer if present, else the
    /// loaded-from-disk contents), or nil for a non-text tab. Used by
    /// encoding-convert (TSK-352).
    private var activeTextForEncodingConvert: (text: String, tabID: UUID, url: URL)? {
        guard let tab = tabs.selected, let url = tab.url else { return nil }
        if let buf = editor.editorBuffers[tab.id] { return (buf.text, tab.id, url) }
        if case .loaded(let f) = tab.state { return (f.contents, tab.id, url) }
        return nil
    }

    /// True when "Convert Encoding" can act — there's an active text file.
    public var canConvertActiveFileEncoding: Bool { activeTextForEncodingConvert != nil }

    /// True when "Convert Line Endings" can act — there's an active text file.
    public var canConvertActiveFileLineEnding: Bool { activeTextWithEncoding != nil }

    /// TSK-1480 — the active file's detected format facets (encoding / line
    /// ending / indent) for the Convert submenus' current-value markers, so the
    /// user isn't converting blind. Reads the live editor buffer if present.
    /// nil for a non-text tab. Computed on menu-open (cold path), not the body.
    public var activeFileFormatFacets:
        (encoding: String.Encoding, lineEnding: LineEnding, indent: IndentStyleDetector.Style)? {
        guard let a = activeTextWithEncoding else { return nil }
        return (a.encoding,
                LineEndingDetector.detect(in: a.text),
                IndentStyleDetector.detect(in: a.text))
    }

    /// TSK-675 — convert the active file's LEADING indentation between tabs and
    /// spaces, using the editor's configured indent width. Leading whitespace
    /// only (alignment after the first non-space is untouched); line endings +
    /// encoding preserved.
    @discardableResult
    public func convertActiveFileIndentation(toSpaces: Bool) -> Bool {
        let width = editorIndentation.size
        return applyTextTransformToActiveFile { text in
            toSpaces
                ? IndentConverter.tabsToSpaces(text, width: width)
                : IndentConverter.spacesToTabs(text, width: width)
        }
    }

    /// TSK-675 (robust plain-text editing) — normalize the active file's line
    /// endings to `target` (LF/CRLF/CR), preserving its encoding and any unsaved
    /// edits. Write-through then drop+reload (same mechanism as
    /// `convertActiveFileEncoding`). Returns false (no change) when there's no
    /// active text file or the file already uses `target` — the on-disk file is
    /// left untouched in that case.
    @discardableResult
    public func convertActiveFileLineEnding(to target: LineEnding) -> Bool {
        guard let ctx = activeTextWithEncoding else { return false }
        let converted = LineEndingConverter.convert(ctx.text, to: target)
        guard converted != ctx.text else { return false }
        do {
            _ = try EditorWriter.save(converted, to: ctx.url, encoding: ctx.encoding)
        } catch {
            Obs.shared.emit(.warn, "files",
                            "Convert line endings failed: \(String(describing: error))")
            return false
        }
        editor.discardEditorBuffer(forTabID: ctx.tabID)
        reloadCurrentFile()
        return true
    }

    /// TSK-352 — re-save the active file's current text (including any unsaved
    /// edits) in `target` encoding, then reload so the app re-detects it.
    /// `EditorBuffer.encoding` is immutable, so we write-through then drop +
    /// reload the buffer (the reload re-seeds it from disk with the new
    /// encoding). Returns false (no change) when there's no active text file or
    /// the text isn't representable in `target` (e.g. emoji → Latin-1) — the
    /// on-disk file is left untouched in that case.
    @discardableResult
    public func convertActiveFileEncoding(to target: String.Encoding) -> Bool {
        guard let ctx = activeTextForEncodingConvert else { return false }
        do {
            _ = try EditorWriter.save(ctx.text, to: ctx.url, encoding: target)
        } catch {
            Obs.shared.emit(.warn, "files",
                            "Convert encoding failed: \(String(describing: error))")
            return false
        }
        editor.discardEditorBuffer(forTabID: ctx.tabID)
        reloadCurrentFile()
        return true
    }
}
