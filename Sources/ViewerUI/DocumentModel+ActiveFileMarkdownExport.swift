import Foundation
import ViewerCore

// Active-file Markdown export / lint commands (TSK-1110 SRP slice; TSK-675/966/997) —
// the read-only Markdown operations on the active file: lint for doc-quality
// issues, check local links, render a standalone (CSP-light, image-inlined) HTML
// export for Copy/Export-as-HTML + Open-in-Browser. All read through the public
// `activeFileText` / `themedExtraStylesheet` seams (no write-through), so this is a
// zero-widening behavior-preserving move out of DocumentModel.swift.
extension DocumentModel {

    /// Result of "Check Links": how many links were examined + the broken ones.
    public struct LinkCheckReport: Sendable { public let total: Int; public let broken: [MarkdownLink] }

    /// True when "Check Links" / "Lint Markdown" can act — an active Markdown file.
    public var canCheckLinks: Bool { canExportActiveAsHTML }

    /// Lint the active Markdown for common doc-quality issues (missing image alt,
    /// heading-level skips, duplicate anchors). nil when no Markdown is active.
    public func lintActiveMarkdown() -> [MarkdownLintIssue]? {
        guard canExportActiveAsHTML, let text = activeFileText else { return nil }
        return MarkdownLint.lint(text)
    }

    /// TSK-675 — find broken LOCAL links/images in the active Markdown file
    /// (relative paths resolved against the file's directory; external links and
    /// in-page anchors are not checked). nil when no Markdown file is active.
    public func checkLinksInActiveMarkdown() -> LinkCheckReport? {
        guard let tab = tabs.selected, let url = tab.url,
              ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased()),
              let text = activeFileText else { return nil }
        let baseDir = url.deletingLastPathComponent()
        let broken = MarkdownLinks.brokenLocalLinks(in: text) { path in
            let decoded = path.removingPercentEncoding ?? path
            let resolved = baseDir.appendingPathComponent(decoded).standardizedFileURL
            return FileManager.default.fileExists(atPath: resolved.path)
        }
        return LinkCheckReport(total: MarkdownLinks.extract(text).count, broken: broken)
    }

    /// True when "Copy/Export as HTML" can act — an active Markdown text file.
    public var canExportActiveAsHTML: Bool {
        guard let tab = tabs.selected, let url = tab.url else { return false }
        guard ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
        else { return false }
        return activeFileText != nil
    }

    /// Render the active Markdown file to a STANDALONE HTML document (TSK-675) for
    /// Copy/Export as HTML — CSP-free (renders in a browser), embedding the
    /// markdown stylesheet + theme overrides. nil when no Markdown file is active.
    public func htmlExportForActiveMarkdown(inlineImages: Bool = false) -> String? {
        guard let tab = tabs.selected, let url = tab.url,
              ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased()),
              let text = activeFileText else { return nil }
        // TSK-966: the standalone export / Open-in-Browser document is CSP-light
        // (so external images render) and runs with file:// privileges in a
        // browser, where the regex sanitizer (confirmed bypasses) would be the
        // sole defense. Render author-embedded HTML as ESCAPED TEXT so no live
        // author markup ever reaches it; the document's own <meta> CSP backstops.
        let body = HTMLRenderer().render(text, authorHTML: .escape)
        let css = MarkdownStylesheet.load() + "\n" + themedExtraStylesheet
        var html = HtmlExport.standaloneDocument(
            body: body, stylesheet: css, title: url.deletingPathExtension().lastPathComponent)
        if inlineImages {
            // Make a saved file portable: inline local images as data: URIs.
            let baseDir = url.deletingLastPathComponent()
            html = HtmlExport.inlineLocalImages(html) { src in
                let decoded = src.removingPercentEncoding ?? src
                let imgURL = baseDir.appendingPathComponent(decoded).standardizedFileURL
                // L-sec1 (TSK-997): containment fence — refuse to read (and
                // therefore base64-inline) any path that escapes the document's
                // own directory tree. `standardizedFileURL` collapses `..`, so
                // without this an `![](../../../../etc/passwd)` — or any
                // readable file given an image extension — would be embedded
                // verbatim into the export. Mirrors the in-app `.html`
                // subresource fence (`HTMLDocumentPolicy.decideSubresource`).
                // On escape we return nil so `inlineLocalImages` leaves the
                // `src` as its original (relative) reference instead.
                guard HTMLDocumentPolicy.isWithinDocumentTree(imgURL, documentURL: url) else {
                    return nil
                }
                return try? Data(contentsOf: imgURL)
            }
        }
        return html
    }

    /// Default filename for "Export as HTML" (active file's stem + `.html`).
    public var htmlExportFilename: String {
        guard let url = tabs.selected?.url else { return "export.html" }
        return HtmlExport.htmlFilename(for: url)
    }

    /// Render the active Markdown to a portable (self-contained) temp `.html` and
    /// return its URL, for "Open in Browser". nil when no Markdown is active or
    /// the write fails.
    public func writeActiveMarkdownPreviewHTML() -> URL? {
        guard let url = tabs.selected?.url,
              let html = htmlExportForActiveMarkdown(inlineImages: true) else { return nil }
        let name = BrowserPreview.tempFileName(stem: url.deletingPathExtension().lastPathComponent)
        // TSK-752: disk-mandatory here — the consumer is `NSWorkspace.open`, i.e.
        // the user's browser in a SEPARATE process, which can only read a real
        // `file://` URL. Centralized scratch dir + prune so previews don't pile
        // up one-per-document forever.
        let dir = ScratchStore.cacheSubdir("preview")
        ScratchStore.prune(directory: dir)
        let dest = dir.appendingPathComponent(name)
        do { try Data(html.utf8).write(to: dest, options: .atomic) } catch { return nil }
        return dest
    }
}
