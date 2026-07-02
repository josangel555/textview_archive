import Foundation

/// One row in the tool-results panel (TSK-1434). `line` non-nil ⇒ the row is
/// clickable and navigates the active document to that 1-based line.
public struct ToolResultRow: Equatable, Sendable, Identifiable {
    public enum Severity: Equatable, Sendable {
        case info, warning, error
    }
    public let id: Int
    public let severity: Severity
    public let line: Int?
    public let message: String
    /// Optional trailing tag (e.g. the lint rule id) rendered as a badge.
    public let tag: String?

    public init(id: Int, severity: Severity, line: Int? = nil, message: String, tag: String? = nil) {
        self.id = id
        self.severity = severity
        self.line = line
        self.message = message
        self.tag = tag
    }
}

/// A tool's result set for the shared results panel (TSK-1434) — the
/// replacement for the modal-alert presentation of Check Links / Lint /
/// Document Statistics / CSV Summary. Pure + host-testable; the panel view and
/// the goto-line dispatch live in ViewerUI.
public struct ToolResults: Equatable, Sendable {
    public let title: String
    public let rows: [ToolResultRow]

    public init(title: String, rows: [ToolResultRow]) {
        self.title = title
        self.rows = rows
    }

    /// A single informational row (the "no issues" shape — the panel still
    /// opens so the user gets positive confirmation instead of a modal).
    public static func note(title: String, message: String) -> ToolResults {
        ToolResults(title: title, rows: [ToolResultRow(id: 0, severity: .info, message: message)])
    }

    // MARK: - Builders (pure input → rows)

    /// Markdown lint issues → rows (line-clickable, rule id as the badge).
    public static func lint(_ issues: [MarkdownLintIssue]) -> ToolResults {
        guard !issues.isEmpty else {
            return .note(title: "Lint — no issues",
                         message: "No missing image alt text, heading-level skips, or duplicate anchors.")
        }
        let rows = issues.enumerated().map { i, issue in
            ToolResultRow(id: i, severity: .warning, line: issue.line,
                          message: issue.message, tag: issue.rule)
        }
        return ToolResults(title: "Lint — \(issues.count) issue\(issues.count == 1 ? "" : "s")",
                           rows: rows)
    }

    /// Word/character/line counts → info rows (not line-clickable).
    public static func stats(_ stats: DocumentStats) -> ToolResults {
        let items: [(String, Int)] = [
            ("Lines", stats.lines),
            ("Words", stats.words),
            ("Characters", stats.characters),
            ("Characters (no whitespace)", stats.charactersNoWhitespace),
        ]
        let rows = items.enumerated().map { i, item in
            ToolResultRow(id: i, severity: .info, message: "\(item.0): \(item.1)")
        }
        return ToolResults(title: "Document Statistics", rows: rows)
    }

    /// The CSV profile report (already a formatted multi-line string) → one
    /// info row per line, so it's scannable + copyable like the others.
    public static func csvSummary(_ report: String) -> ToolResults {
        let lines = report.split(separator: "\n", omittingEmptySubsequences: true)
        guard !lines.isEmpty else {
            return .note(title: "CSV Summary", message: "No summary available.")
        }
        let rows = lines.enumerated().map { i, line in
            ToolResultRow(id: i, severity: .info, message: String(line))
        }
        return ToolResults(title: "CSV Summary", rows: rows)
    }

    /// The whole result set as plain text (the Copy button's payload).
    public var plainText: String {
        ([title] + rows.map { row in
            var parts: [String] = []
            if let line = row.line { parts.append("line \(line):") }
            parts.append(row.message)
            if let tag = row.tag { parts.append("[\(tag)]") }
            return "  " + parts.joined(separator: " ")
        }).joined(separator: "\n")
    }
}
