import SwiftUI
import ViewerCore

/// TSK-374 — a scrollable list of in-document find matches (line number + the
/// line's text), the richer companion to the tick minimap. Click a row to jump
/// to that match. The cross-file search already has a grouped match-list panel;
/// this brings the same affordance to in-document find.
///
/// The row MODEL (`FindMatchList.rows`) is pure + host-tested; the list view +
/// its popover placement are the render tail (VM/owner).

/// One displayable match row: a stable list id, the 1-based document line, and
/// that line's (trimmed, truncated) text.
public struct FindMatchRow: Identifiable, Equatable, Sendable {
    public let id: Int
    public let line: Int
    public let text: String
}

public enum FindMatchList {
    /// Build display rows from the find's match line numbers + the document
    /// text: each row carries the match's 1-based line and that line's text
    /// (whitespace-trimmed, truncated to `maxTextLength`). Out-of-range lines
    /// are skipped; a blank match line keeps a clickable row (a single space).
    /// Pure + host-testable. `id` is the stable position in the match list, so
    /// multiple matches on the same line stay distinct.
    public static func rows(matchLines: [Int], docText: String,
                            maxTextLength: Int = 200) -> [FindMatchRow] {
        let lines = docText.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        return matchLines.enumerated().compactMap { (i, ln) -> FindMatchRow? in
            guard ln >= 1, ln <= lines.count else { return nil }
            var t = lines[ln - 1].trimmingCharacters(in: .whitespaces)
            if t.count > maxTextLength { t = String(t.prefix(maxTextLength)) + "…" }
            return FindMatchRow(id: i, line: ln, text: t.isEmpty ? " " : t)
        }
    }
}

struct FindMatchListView: View {
    let rows: [FindMatchRow]
    /// Index into the match list of the active match (highlighted).
    let currentMatchIndex: Int?
    /// Jump callback — the 1-based document line of the clicked row.
    let onClickLine: (Int) -> Void
    var uiSize: (CGFloat) -> CGFloat = { $0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(rows.count) match\(rows.count == 1 ? "" : "es")")
                    .font(.system(size: uiSize(11), weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                        Button {
                            onClickLine(row.line)
                        } label: {
                            HStack(spacing: 8) {
                                Text("\(row.line)")
                                    .font(.system(size: uiSize(10), design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: uiSize(40), alignment: .trailing)
                                Text(row.text)
                                    .font(.system(size: uiSize(11), design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(idx == currentMatchIndex
                                        ? Color.accentColor.opacity(0.18)
                                        : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(width: uiSize(420), height: uiSize(280))
        .accessibilityIdentifier("mdv.findMatchList")
    }
}
