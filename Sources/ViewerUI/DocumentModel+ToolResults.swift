import Foundation
import ViewerCore

// TSK-1434 — the shared tool-results panel: Check Links / Lint / Document
// Statistics / CSV Summary present into ONE non-modal panel (click-to-line,
// copy, dismiss) instead of NSAlert.runModal(). The menu handlers AND the
// script verbs route through these, so palette/menu/automation share one path.
extension DocumentModel {

    /// Present `results` in the shared panel (replaces any current set).
    public func presentToolResults(_ results: ToolResults) {
        toolResults = results
    }

    public func dismissToolResults() {
        toolResults = nil
    }

    /// Row click: navigate the active document to the row's line (same
    /// primitive as the `goto-line` verb); the panel stays open so the user
    /// can walk the list.
    public func activateToolResultRow(_ row: ToolResultRow) {
        guard let line = row.line, line >= 1 else { return }
        sourceView.scrollSource(toLine: line)
    }

    // MARK: - The four tools (menu + verb entry points)

    /// Tools ▸ Check Links → panel. False when no Markdown file is active.
    @discardableResult
    public func runCheckLinksToPanel() -> Bool {
        guard let report = checkLinksInActiveMarkdown() else { return false }
        if report.broken.isEmpty {
            presentToolResults(.note(
                title: "Check Links — all \(report.total) OK",
                message: "No broken local links or images."))
        } else {
            let rows = report.broken.enumerated().map { i, link in
                ToolResultRow(id: i, severity: .error, line: link.line,
                              message: link.target,
                              tag: link.isImage ? "image" : "link")
            }
            presentToolResults(ToolResults(
                title: "Check Links — \(report.broken.count) of \(report.total) broken",
                rows: rows))
        }
        return true
    }

    /// Tools ▸ Lint Markdown → panel. False when no Markdown file is active.
    @discardableResult
    public func runLintToPanel() -> Bool {
        guard let issues = lintActiveMarkdown() else { return false }
        presentToolResults(.lint(issues))
        return true
    }

    /// Tools ▸ Document Statistics → panel. False when no text file is active.
    @discardableResult
    public func runDocStatsToPanel() -> Bool {
        guard let stats = activeDocumentStats else { return false }
        presentToolResults(.stats(stats))
        return true
    }

    /// Tools ▸ CSV Summary → panel. False when no CSV is active.
    @discardableResult
    public func runCSVSummaryToPanel() -> Bool {
        guard let report = activeCSVSummary() else { return false }
        presentToolResults(.csvSummary(report))
        return true
    }
}
