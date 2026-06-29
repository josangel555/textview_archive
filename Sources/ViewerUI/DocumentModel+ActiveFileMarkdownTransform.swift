import Foundation
import ViewerCore

// Active-file Markdown structural transforms (TSK-1110 SRP slice; TSK-675) — the
// write-through Markdown commands that rewrite the active file in place: shift every
// ATX heading up/down a level, and insert/refresh a `<!-- toc -->`-fenced table of
// contents built from the file's own headings. Both route through the internal
// `applyTextTransformToActiveFile` seam (encoding + line endings preserved). The
// read-only export/lint Markdown commands live in DocumentModel+ActiveFileMarkdownExport.swift.
// Behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// True when the Markdown heading-shift commands can act — active Markdown file.
    public var canShiftMarkdownHeadings: Bool { canInsertTableOfContents }

    /// Promote (`delta < 0`, fewer `#`) / demote (`delta > 0`, more `#`) every
    /// ATX heading in the active Markdown file. Encoding + line endings preserved.
    @discardableResult
    public func shiftActiveMarkdownHeadings(by delta: Int) -> Bool {
        applyTextTransformToActiveFile { MarkdownHeadingShift.shift($0, by: delta) }
    }

    /// True when "Insert Table of Contents" can act — an active Markdown text file.
    public var canInsertTableOfContents: Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        guard ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
        else { return false }
        return activeTextWithEncoding != nil
    }

    /// TSK-675 — insert/refresh a Markdown table of contents (from the file's own
    /// headings) wrapped in `<!-- toc -->` markers, so a re-run regenerates in
    /// place. Encoding + line endings preserved via the shared write-through.
    @discardableResult
    public func insertTableOfContents() -> Bool {
        applyTextTransformToActiveFile { text in
            MarkdownTOC.insert(into: text, headings: MarkdownOutline.headings(in: text))
        }
    }
}
